"""Integration tests for logbook data in todos."""


class TestLogbookData:
    """Tests for logbook data extraction from todos."""

    def test_todo_with_logbook_has_logbook_field(self, api):
        """Todo items with logbook should have logbook field in response."""
        response = api.get_all_todos()
        data = response.json()
        todos = data["todos"]

        # Find the "Task with state changes" task which has logbook in sample.org
        task = next(
            (t for t in todos if "Task with state changes" in t.get("title", "")),
            None,
        )
        assert task is not None, "Should find 'Task with state changes' task"
        assert "logbook" in task, "Task should have logbook field"
        assert isinstance(task["logbook"], list), "Logbook should be a list"

    def test_logbook_contains_entries(self, api):
        """Logbook should contain entries."""
        response = api.get_all_todos()
        todos = response.json()["todos"]

        task = next(
            (t for t in todos if "Task with state changes" in t.get("title", "")),
            None,
        )
        assert task is not None

        logbook = task.get("logbook", [])
        assert len(logbook) >= 1, "Should have at least 1 logbook entry"

        # Each entry should have a type
        for entry in logbook:
            assert "type" in entry, "Entry should have type field"

    def test_logbook_state_change_timestamp_format(self, api):
        """State change timestamps should be in ISO format."""
        response = api.get_all_todos()
        todos = response.json()["todos"]

        task = next(
            (t for t in todos if "Task with state changes" in t.get("title", "")),
            None,
        )
        logbook = task.get("logbook", [])
        state_changes = [e for e in logbook if e.get("type") == "state-change"]

        for change in state_changes:
            ts = change.get("timestamp")
            assert ts is not None, "Should have timestamp"
            # Should be ISO format: YYYY-MM-DD or YYYY-MM-DDTHH:MM:SS
            assert ts.startswith("2024-01-"), f"Timestamp should be valid: {ts}"

    def test_logbook_contains_notes(self, api):
        """Logbook should contain note entries."""
        response = api.get_all_todos()
        todos = response.json()["todos"]

        task = next(
            (t for t in todos if "Task with logbook notes" in t.get("title", "")),
            None,
        )
        assert task is not None, "Should find task with logbook notes"

        logbook = task.get("logbook", [])
        notes = [e for e in logbook if e.get("type") == "note"]

        assert len(notes) >= 1, "Should have at least 1 note"

        note = notes[0]
        assert note.get("timestamp") is not None, "Note should have timestamp"

    def test_todo_without_logbook_has_no_logbook_field(self, api):
        """Todo items without logbook should not have logbook field."""
        response = api.get_all_todos()
        todos = response.json()["todos"]

        # "Buy groceries" has no logbook in sample.org
        task = next(
            (t for t in todos if "Buy groceries" in t.get("title", "")),
            None,
        )
        assert task is not None, "Should find task without logbook"
        # Either no logbook field or empty logbook
        logbook = task.get("logbook")
        assert logbook is None or len(logbook) == 0, "Should have no logbook entries"

    def test_logbook_entries_have_expected_fields(self, api):
        """Logbook entries should have expected fields based on type."""
        response = api.get_all_todos()
        todos = response.json()["todos"]

        task = next(
            (t for t in todos if "Task with state changes" in t.get("title", "")),
            None,
        )
        logbook = task.get("logbook", [])

        # All entries should have raw field
        for entry in logbook:
            assert "raw" in entry, "Entry should have raw field"
            entry_type = entry.get("type")
            # State changes should have to/from fields
            if entry_type == "state-change":
                assert "to" in entry, "State change should have 'to' field"
            # Notes should have timestamp
            if entry_type == "note":
                assert "timestamp" in entry, "Note should have timestamp"

    def test_logbook_entry_has_raw_field(self, api):
        """Each logbook entry should have a raw field with original text."""
        response = api.get_all_todos()
        todos = response.json()["todos"]

        task = next(
            (t for t in todos if "Task with state changes" in t.get("title", "")),
            None,
        )
        logbook = task.get("logbook", [])

        for entry in logbook:
            assert "raw" in entry, "Entry should have raw field"
            assert isinstance(entry["raw"], str), "Raw should be a string"
