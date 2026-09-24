"""Integration tests for the /memory endpoints."""

import pytest


@pytest.fixture
def memory_file(org_test_dir):
    return org_test_dir / "agents" / "memory.org"


def save(api, name, text, **extra):
    return api.post("/memory/save", json={"name": name, "text": text, **extra})


def search(api, q=None, **params):
    if q is not None:
        params["q"] = q
    return api.get("/memory", params=params)


class TestMemory:
    def test_save_then_search_returns_note(self, api):
        response = save(
            api, "Coffee order", "Oat flat white, extra hot.", source="test"
        )
        assert response.status_code == 200
        body = response.json()
        assert body["status"] == "saved"
        assert body["created"] is True
        assert body["note"]["reviewed"] is True
        assert body["note"]["id"]

        notes = search(api, "flat white").json()["notes"]
        assert [n["name"] for n in notes] == ["Coffee order"]
        assert notes[0]["text"] == "Oat flat white, extra hot."
        assert notes[0]["source"] == "test"

    def test_save_replaces_same_name_keeping_id(self, api, memory_file):
        first = save(api, "Hotel", "Hilton, Sept 3-5").json()["note"]
        second = save(api, "Hotel", "Marriott, Sept 3-6").json()
        assert second["created"] is False
        assert second["note"]["id"] == first["id"]
        assert second["note"]["created"] == first["created"]
        assert memory_file.read_text().count("* Hotel") == 1
        assert "Hilton" not in memory_file.read_text()

    def test_terms_match_independently_and_name_matches_rank_first(self, api):
        save(api, "Gmail filters", "Filter creation needs the gws CLI.")
        save(api, "Inbox tooling", "Gmail filters are unreachable through MCP.")
        names = [n["name"] for n in search(api, "filters gmail").json()["notes"]]
        assert names[:2] == ["Gmail filters", "Inbox tooling"]

    def test_learn_is_unreviewed_until_saved(self, api, memory_file):
        learned = api.post(
            "/memory/learn", json={"name": "Seat", "text": "Prefers aisle"}
        )
        assert learned.status_code == 200
        assert learned.json()["note"]["reviewed"] is False
        assert ":unreviewed:" in memory_file.read_text()

        kept = save(api, "Seat", "Prefers aisle").json()["note"]
        assert kept["reviewed"] is True
        assert "* Seat\n" in memory_file.read_text()

    def test_learn_never_replaces_reviewed_note(self, api):
        save(api, "Airline", "ANA")
        response = api.post("/memory/learn", json={"name": "Airline", "text": "United"})
        assert response.status_code == 409
        assert search(api, "Airline").json()["notes"][0]["text"] == "ANA"

    def test_forget(self, api):
        save(api, "Temporary", "Delete me")
        assert api.post("/memory/forget", json={"name": "Temporary"}).status_code == 200
        assert search(api, "Delete me").json()["total"] == 0
        missing = api.post("/memory/forget", json={"name": "Temporary"})
        assert missing.status_code == 404

    def test_body_cannot_create_headings(self, api):
        save(api, "Bullets", "* one\n** two")
        notes = search(api, "Bullets").json()["notes"]
        assert len(notes) == 1
        assert "one" in notes[0]["text"] and "two" in notes[0]["text"]

    def test_hand_written_notes_are_readable(self, api, memory_file):
        memory_file.parent.mkdir(exist_ok=True)
        memory_file.write_text(
            "* Written in Emacs :tools:\nSome *org* text.\n** Detail\nMore.\n"
        )
        note = search(api, "Written in Emacs").json()["notes"][0]
        assert note["tags"] == ["tools"]
        assert note["reviewed"] is True
        assert "Detail" in note["text"]

    def test_paging(self, api):
        for i in range(3):
            save(api, f"Paging note {i}", "paging body")
        page = search(api, "paging body", limit=2).json()
        assert page["total"] == 3
        assert len(page["notes"]) == 2
        assert page["nextOffset"] == 2
        rest = search(api, "paging body", offset=2, limit=2).json()
        assert len(rest["notes"]) == 1
        assert "nextOffset" not in rest

    @pytest.mark.parametrize(
        "name,text",
        [
            ("", "x"),
            (" padded", "x"),
            ("TODO buy milk", "x"),
            ("Tagged :foo:", "x"),
            ("Ok", "  "),
        ],
    )
    def test_invalid_notes_are_rejected(self, api, name, text):
        response = save(api, name, text)
        assert response.status_code == 400
        assert response.json()["status"] == "error"
