"""Integration tests for the read-only /notes and /note endpoints."""


def list_notes(api, **params):
    response = api.get("/notes", params=params)
    assert response.status_code == 200
    return response.json()["notes"]


def get_note(api, ref):
    response = api.get("/note", params={"ref": ref})
    assert response.status_code == 200, response.text
    return response.json()


def text_of(inlines):
    return "".join(
        inline["v"] if "v" in inline else text_of(inline["c"]) for inline in inlines
    )


class TestNotes:
    def test_listing_covers_files_and_id_headings_but_not_todos(self, api):
        notes = {note["ref"]: note for note in list_notes(api)}
        assert notes["id:hub-0001"]["title"] == "Hub"
        assert notes["id:hub-0001"]["tags"] == ["index"]
        assert notes["id:sub-0003"]["olp"] == ["Section"]
        assert notes["id:sub-0003"]["fileRef"] == "id:hub-0001"
        assert notes["file:notes/plain.org"]["title"] == "Plain note"
        assert "id:todo-0004" not in notes
        assert notes["id:topic-0002"]["backlinkCount"] == 2

    def test_search_ranks_title_matches_first_with_snippets(self, api):
        notes = list_notes(api, q="hub")
        assert notes[0]["ref"] == "id:hub-0001"
        assert "snippet" not in notes[0]
        assert "See the hub and a site" in notes[1]["snippet"]

        [zebra] = list_notes(api, q="zebra lives")
        assert zebra["ref"] == "id:sub-0003"
        assert "A zebra lives here; see Topic." in zebra["snippet"]

        assert [n["ref"] for n in list_notes(api, q="quokka")] == [
            "file:notes/plain.org"
        ]

    def test_note_content_is_structured(self, api):
        blocks = get_note(api, "id:topic-0002")["content"]["blocks"]
        types = [block["type"] for block in blocks]
        assert types == ["paragraph", "list", "table", "src"]

        paragraph = blocks[0]["content"]
        assert {"t": "bold", "c": [{"t": "text", "v": "bold"}]} in paragraph
        assert {"t": "code", "v": "code"} in paragraph
        assert "code, wrapped onto" in text_of(paragraph)
        hub_link = next(i for i in paragraph if i.get("href") == "id:hub-0001")
        assert hub_link["ref"] == "id:hub-0001"
        site_link = next(i for i in paragraph if i.get("href") == "https://example.com")
        assert site_link["ref"] is None

        items = blocks[1]["items"]
        assert [item["checkbox"] for item in items] == ["on", "off"]
        assert items[1]["blocks"][1]["ordered"] is True
        assert blocks[2]["header"] is True
        assert blocks[2]["rows"][1] == [
            [{"t": "text", "v": "a"}],
            [{"t": "text", "v": "1"}],
        ]
        assert blocks[3] == {
            "type": "src",
            "language": "python",
            "value": 'print("hi")',
        }

    def test_links_and_backlinks_resolve_ids_and_files(self, api):
        hub = get_note(api, "id:hub-0001")
        assert [link["ref"] for link in hub["links"]] == [
            "id:topic-0002",
            "file:notes/plain.org",
        ]
        backlinks = {link["ref"]: link for link in hub["backlinks"]}
        assert set(backlinks) == {"id:topic-0002", "id:todo-0004"}
        assert backlinks["id:todo-0004"]["context"] == "Mentions Hub."

        section = hub["content"]["children"][0]
        assert text_of(section["title"]) == "Section"
        assert section["children"][0]["ref"] == "id:sub-0003"

    def test_backlinks_preview_each_occurrence_in_context(self, api):
        hub = get_note(api, "id:hub-0001")
        backlinks = {link["ref"]: link for link in hub["backlinks"]}
        [occurrence] = backlinks["id:topic-0002"]["occurrences"]
        assert occurrence["olp"] == []
        [paragraph] = occurrence["preview"]
        assert text_of(paragraph["content"]).startswith("Some bold and italic text")
        [todo] = backlinks["id:todo-0004"]["occurrences"]
        assert todo["olp"] == ["Fix thing"]

        [item] = get_note(api, "id:topic-0002")["backlinks"][0]["occurrences"]
        assert text_of(item["preview"][0]["content"]).startswith("Start at Topic")

    def test_unlinked_references_skip_linking_notes(self, api):
        unlinked = get_note(api, "id:topic-0002")["unlinked"]
        assert [(u["ref"], u["context"]) for u in unlinked] == [
            ("file:notes/plain.org", "It mentions Topic without linking.")
        ]

    def test_graph_has_link_and_parent_edges(self, api):
        response = api.get("/notes/graph")
        assert response.status_code == 200
        graph = response.json()
        ids = {node["id"] for node in graph["nodes"]}
        assert {"id:hub-0001", "id:sub-0003", "file:notes/plain.org"} <= ids
        assert "id:todo-0004" not in ids
        edges = {(e["source"], e["target"], e["type"]) for e in graph["links"]}
        assert {
            ("id:hub-0001", "id:topic-0002", "link"),
            ("id:hub-0001", "file:notes/plain.org", "link"),
            ("id:topic-0002", "id:hub-0001", "link"),
            ("id:sub-0003", "id:topic-0002", "link"),
            ("id:sub-0003", "id:hub-0001", "parent"),
        } <= edges
        assert not any("todo-0004" in e[0] + e[1] for e in edges)
        assert api.get("/notes/nope").status_code == 404

    def test_heading_note_renders_only_its_subtree(self, api):
        body = get_note(api, "id:sub-0003")
        assert body["note"]["olp"] == ["Section"]
        content = body["content"]
        assert text_of(content["blocks"][0]["content"]).startswith("A zebra lives")
        assert [text_of(child["title"]) for child in content["children"]] == ["Detail"]
        assert [link["ref"] for link in body["links"]] == ["id:topic-0002"]

    def test_file_ref_resolves_to_file_with_id(self, api):
        assert get_note(api, "file:notes/hub.org")["note"]["ref"] == "id:hub-0001"

    def test_new_files_are_indexed(self, api, org_test_dir):
        (org_test_dir / "notes" / "fresh.org").write_text(
            "#+title: Fresh\n\nLinks to [[id:hub-0001][Hub]].\n"
        )
        assert [n["ref"] for n in list_notes(api, q="fresh")] == [
            "file:notes/fresh.org"
        ]
        backlinks = get_note(api, "id:hub-0001")["backlinks"]
        assert "file:notes/fresh.org" in [link["ref"] for link in backlinks]

    def test_errors(self, api):
        assert api.get("/note").status_code == 400
        missing = api.get("/note", params={"ref": "id:nope"})
        assert missing.status_code == 404
        assert missing.json()["code"] == "not_found"
        outside = api.get("/note", params={"ref": "file:../etc/passwd"})
        assert outside.status_code == 404
