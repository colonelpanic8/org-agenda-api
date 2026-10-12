"""Regression tests for mutation input validation and target safety."""

OUT_OF_ORDER_ENTRY = """
* TODO Logbook reorder target
  :LOGBOOK:
  - State "TODO"       from "NEXT"       [2024-06-01 Sat 09:00]
  - State "NEXT"       from "TODO"       [2024-06-10 Mon 09:00]
  :END:
"""


def _find(api, title):
    todos = api.get_all_todos().json()["todos"]
    return next(t for t in todos if t.get("title") == title)


def _append_to_inbox(api, org_dir, text):
    inbox = org_dir / "inbox.org"
    inbox.write_text(inbox.read_text() + text)
    api.get("/reload")
    return inbox


class TestCaptureEscaping:
    def test_template_escapes_in_values_are_inserted_literally(self, api, org_dir):
        title = 'Literal %(concat "ev" "aluated") %[/etc/hostname] %U \\%(x)'
        response = api.create_todo(title)

        assert response.json()["status"] == "created"
        assert f"* TODO {title}\n" in (org_dir / "inbox.org").read_text()


class TestUpdateValidation:
    def test_newline_in_title_is_rejected_without_editing(self, api, org_dir):
        todo = _find(api, "Buy groceries")
        before = (org_dir / "sample.org").read_text()

        response = api.update_todo(todo, {"new_title": "Renamed\n* TODO Injected"})

        assert response.json()["status"] == "error"
        assert (org_dir / "sample.org").read_text() == before

    def test_newline_in_property_value_is_rejected(self, api):
        todo = _find(api, "Buy groceries")

        response = api.update_todo(
            todo, {"properties": {"NOTE": "one\n:END:\n* TODO Injected"}}
        )

        assert response.json()["status"] == "error"

    def test_invalid_field_leaves_no_partial_edit(self, api, org_dir):
        todo = _find(api, "Buy groceries")

        response = api.update_todo(todo, {"new_title": "Changed", "priority": 17})
        assert response.json()["status"] == "error"

        # A later successful update must not persist the rejected title.
        api.update_todo(todo, {"priority": "A"})
        content = (org_dir / "sample.org").read_text()
        assert "Changed" not in content
        assert "* TODO [#A] Buy groceries" in content

    def test_invalid_calendar_date_is_rejected(self, api):
        todo = _find(api, "Buy groceries")

        response = api.update_todo(todo, {"scheduled": {"date": "2024-02-31"}})

        assert response.json()["status"] == "error"

    def test_null_time_in_timestamp_object_means_date_only(self, api, org_dir):
        todo = _find(api, "Buy groceries")

        response = api.update_todo(
            todo, {"scheduled": {"date": "2024-06-20", "time": None}}
        )

        assert response.json()["status"] == "updated"
        assert "SCHEDULED: <2024-06-20 Thu>" in (org_dir / "sample.org").read_text()

    def test_unknown_state_is_rejected(self, api):
        todo = _find(api, "Buy groceries")

        response = api.complete_todo(todo, state="BOGUS")

        assert response.json()["status"] == "error"
        assert _find(api, "Buy groceries")["todo"] == "TODO"


class TestMutationTargets:
    def test_file_outside_agenda_is_not_modified(self, api, tmp_path):
        outside = tmp_path / "outside.org"
        outside.write_text("* TODO Outside\n")

        response = api.post(
            "/update",
            json={"file": str(outside), "pos": 1, "new_title": "Changed"},
        )

        assert response.json()["status"] == "error"
        assert outside.read_text() == "* TODO Outside\n"

    def test_strict_lookup_cannot_target_file_outside_agenda(self, api, tmp_path):
        outside = tmp_path / "outside.org"
        outside.write_text("* TODO Outside\n")

        response = api.post(
            "/complete",
            json={"file": str(outside), "pos": 1, "title": "Outside", "strict": True},
        )

        assert response.json()["status"] == "error"
        assert outside.read_text() == "* TODO Outside\n"

    def test_ambiguous_title_only_match_is_rejected(self, api, org_dir):
        _append_to_inbox(
            api, org_dir, "\n* TODO Duplicate title\n* TODO Duplicate title\n"
        )

        response = api.post("/complete", json={"title": "Duplicate title"})

        data = response.json()
        assert data["status"] == "error"
        assert "Multiple headings" in data["message"]

    def test_non_object_body_returns_json_error(self, api):
        response = api.post("/delete", json=["not", "an", "object"])

        assert response.status_code == 200
        assert response.json()["status"] == "error"


class TestLogbookPreservation:
    def test_reordering_keeps_clock_lines(self, api, org_dir):
        inbox = _append_to_inbox(api, org_dir, OUT_OF_ORDER_ENTRY)
        todo = _find(api, "Logbook reorder target")

        response = api.add_clock(todo, "2024-06-15T09:00:00", "2024-06-15T10:00:00")
        assert response.json()["status"] == "created"

        content = inbox.read_text()
        assert (
            "CLOCK: [2024-06-15 Sat 09:00]--[2024-06-15 Sat 10:00] =>  1:00" in content
        )
        assert content.index("2024-06-10 Mon") < content.index("2024-06-01 Sat")

    def test_zoned_clock_timestamps_keep_their_time(self, api, org_dir):
        api.create_todo("Zoned clock target")
        todo = _find(api, "Zoned clock target")

        response = api.add_clock(todo, "2024-06-15T16:00:00Z", "2024-06-15T17:30:00Z")

        assert response.json()["clock"]["durationMinutes"] == 90
        # Test server runs in America/Los_Angeles (UTC-7 in June).
        assert (
            "CLOCK: [2024-06-15 Sat 09:00]--[2024-06-15 Sat 10:30]"
            in (org_dir / "inbox.org").read_text()
        )
