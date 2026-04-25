"""Integration tests for logbook data in todos."""

import re


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


class TestDeleteLogbookEntry:
    """Tests for POST /delete-logbook-entry endpoint."""

    def test_delete_logbook_entry_returns_200(self, api, org_dir):
        """Endpoint should return 200 OK on successful deletion."""
        from pathlib import Path

        # Create a todo and complete it to create a logbook entry
        unique_title = "Delete logbook test todo 11111"
        api.create_todo(unique_title)

        # Find the todo
        todos_response = api.get_all_todos()
        todos = todos_response.json()
        todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )
        assert todo is not None

        # Complete it with a specific date
        override_date = "2024-02-15"
        response = api.complete_todo(todo, override_date=override_date)
        assert response.status_code == 200

        # Verify the logbook entry exists
        file_path = Path(todo["file"])
        content = file_path.read_text()
        assert override_date in content, "Logbook entry should exist"

        # Get updated todo (position may have changed)
        todos_response = api.get_all_todos()
        todos = todos_response.json()
        todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )
        assert todo is not None

        # Delete the logbook entry
        response = api.delete_logbook_entry(todo, override_date)
        assert response.status_code == 200

        data = response.json()
        assert data.get("status") == "deleted"

    def test_delete_logbook_entry_removes_entry_from_file(self, api, org_dir):
        """Deleted entry should be removed from the file."""
        from pathlib import Path

        unique_title = "Delete logbook file test 22222"
        api.create_todo(unique_title)

        todos_response = api.get_all_todos()
        todos = todos_response.json()
        todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )
        assert todo is not None

        # Complete with specific date
        override_date = "2024-03-10"
        api.complete_todo(todo, override_date=override_date)

        # Find the todo section and verify logbook entry exists
        file_path = Path(todo["file"])
        content = file_path.read_text()

        # Find this specific todo's section
        todo_section_match = re.search(
            r"\*+ (?:TODO|DONE) " + re.escape(unique_title) + r".*?\n(.*?)(?=^\*|\Z)",
            content,
            re.MULTILINE | re.DOTALL,
        )
        assert todo_section_match, "Should find todo section"
        todo_section = todo_section_match.group(1)

        # Verify the logbook entry exists
        logbook_match = re.search(r":LOGBOOK:\s*\n(.*?):END:", todo_section, re.DOTALL)
        assert logbook_match, "Should have LOGBOOK"
        assert override_date in logbook_match.group(1), "Date should be in LOGBOOK"

        # Get updated todo
        todos_response = api.get_all_todos()
        todos = todos_response.json()
        todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )

        # Delete the entry
        api.delete_logbook_entry(todo, override_date)

        # Verify entry is gone from logbook
        content = file_path.read_text()
        todo_section_match = re.search(
            r"\*+ (?:TODO|DONE) " + re.escape(unique_title) + r".*?\n(.*?)(?=^\*|\Z)",
            content,
            re.MULTILINE | re.DOTALL,
        )
        assert todo_section_match, "Should still find todo section"
        todo_section = todo_section_match.group(1)

        logbook_match = re.search(r":LOGBOOK:\s*\n(.*?):END:", todo_section, re.DOTALL)
        # Either no logbook or date not in logbook
        if logbook_match:
            assert override_date not in logbook_match.group(1), (
                "Date should be removed from LOGBOOK"
            )

    def test_delete_logbook_entry_not_found(self, api, org_dir):
        """Should return not_found status when entry doesn't exist."""
        unique_title = "Delete logbook not found test 33333"
        api.create_todo(unique_title)

        todos_response = api.get_all_todos()
        todos = todos_response.json()
        todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )
        assert todo is not None

        # Complete it first to create a logbook
        api.complete_todo(todo, override_date="2024-04-01")

        # Get updated todo
        todos_response = api.get_all_todos()
        todos = todos_response.json()
        todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )

        # Try to delete a non-existent entry
        response = api.delete_logbook_entry(todo, "2024-12-31")
        data = response.json()

        assert data.get("status") == "not_found"

    def test_delete_logbook_entry_with_type_filter(self, api, org_dir):
        """Should only delete entries matching the type filter."""
        from pathlib import Path

        unique_title = "Delete logbook type filter test 44444"
        api.create_todo(unique_title)

        todos_response = api.get_all_todos()
        todos = todos_response.json()
        todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )
        assert todo is not None

        # Complete with specific date
        override_date = "2024-05-15"
        api.complete_todo(todo, override_date=override_date)

        # Get updated todo
        todos_response = api.get_all_todos()
        todos = todos_response.json()
        todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )

        # Delete with type filter for state-change
        response = api.delete_logbook_entry(
            todo, override_date, entry_type="state-change"
        )
        data = response.json()

        assert data.get("status") == "deleted"

        # Verify entry is gone from logbook (not just file - CLOSED timestamp may still have date)
        file_path = Path(todo["file"])
        content = file_path.read_text()

        # Find this specific todo's section
        todo_section_match = re.search(
            r"\*+ (?:TODO|DONE) " + re.escape(unique_title) + r".*?\n(.*?)(?=^\*|\Z)",
            content,
            re.MULTILINE | re.DOTALL,
        )
        assert todo_section_match, "Should find todo section"
        todo_section = todo_section_match.group(1)

        logbook_match = re.search(r":LOGBOOK:\s*\n(.*?):END:", todo_section, re.DOTALL)
        # Either no logbook or date not in logbook
        if logbook_match:
            assert override_date not in logbook_match.group(1), (
                "Date should be removed from LOGBOOK"
            )

    def test_delete_logbook_entry_returns_deleted_content(self, api, org_dir):
        """Response should include the deleted entry content."""
        unique_title = "Delete logbook content test 55555"
        api.create_todo(unique_title)

        todos_response = api.get_all_todos()
        todos = todos_response.json()
        todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )
        assert todo is not None

        override_date = "2024-06-20"
        api.complete_todo(todo, override_date=override_date)

        # Get updated todo
        todos_response = api.get_all_todos()
        todos = todos_response.json()
        todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )

        response = api.delete_logbook_entry(todo, override_date)
        data = response.json()

        assert "deletedEntry" in data
        assert "DONE" in data["deletedEntry"]
        assert override_date in data["deletedEntry"]

    def test_delete_one_of_multiple_logbook_entries(self, api, org_dir):
        """Should delete only the targeted entry when multiple exist."""
        from pathlib import Path

        unique_title = "Delete logbook multiple test 66666"
        api.create_todo(unique_title)

        todos_response = api.get_all_todos()
        todos = todos_response.json()
        todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )
        assert todo is not None

        # Complete multiple times with different dates
        date1 = "2024-07-10"
        date2 = "2024-07-15"

        api.complete_todo(todo, override_date=date1)

        # Get updated todo and set back to TODO
        todos_response = api.get_all_todos()
        todos = todos_response.json()
        todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )
        api.set_state(todo, "TODO")

        # Get updated todo and complete again
        todos_response = api.get_all_todos()
        todos = todos_response.json()
        todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )
        api.complete_todo(todo, override_date=date2)

        # Get updated todo
        todos_response = api.get_all_todos()
        todos = todos_response.json()
        todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )

        # Verify both dates exist
        file_path = Path(todo["file"])
        content = file_path.read_text()
        assert date1 in content, f"Date1 should exist: {content}"
        assert date2 in content, f"Date2 should exist: {content}"

        # Delete only the first date
        response = api.delete_logbook_entry(todo, date1, entry_type="state-change")
        assert response.json().get("status") == "deleted"

        # Verify only date1 is gone, date2 still exists
        content = file_path.read_text()
        assert date1 not in content, "Date1 should be deleted"
        assert date2 in content, "Date2 should still exist"


class TestClockEntries:
    """Tests for CLOCK logbook parsing and mutations."""

    def _create_clocked_todo(self, api, title):
        api.create_todo(title)
        todos = api.get_all_todos().json()["todos"]
        todo = next(
            (t for t in todos if title in t.get("title", "")),
            None,
        )
        assert todo is not None
        return todo

    def _refetch_todo(self, api, title):
        todos = api.get_all_todos().json()["todos"]
        todo = next(
            (t for t in todos if title in t.get("title", "")),
            None,
        )
        assert todo is not None
        return todo

    def test_add_clock_creates_logbook_entry(self, api):
        title = "Clock add test todo"
        todo = self._create_clocked_todo(api, title)

        response = api.add_clock(
            todo,
            "2024-06-15T09:00:00",
            "2024-06-15T10:30:00",
        )
        assert response.status_code == 200
        data = response.json()

        assert data.get("status") == "created"
        assert data["clock"]["durationMinutes"] == 90

    def test_clock_entries_are_returned_in_logbook(self, api):
        title = "Clock parse test todo"
        todo = self._create_clocked_todo(api, title)
        api.add_clock(
            todo,
            "2024-06-15T09:00:00",
            "2024-06-15T10:30:00",
        )

        todo = self._refetch_todo(api, title)
        clocks = [
            entry for entry in todo.get("logbook", []) if entry.get("type") == "clock"
        ]

        assert len(clocks) == 1
        assert clocks[0]["start"] == "2024-06-15T09:00:00"
        assert clocks[0]["end"] == "2024-06-15T10:30:00"
        assert clocks[0]["durationMinutes"] == 90
        assert clocks[0]["raw"].startswith("CLOCK:")

    def test_update_clock_rewrites_existing_clock(self, api):
        title = "Clock update test todo"
        todo = self._create_clocked_todo(api, title)
        api.add_clock(
            todo,
            "2024-06-15T09:00:00",
            "2024-06-15T10:30:00",
        )
        todo = self._refetch_todo(api, title)

        response = api.update_clock(
            todo,
            "2024-06-15T09:00:00",
            "2024-06-15T08:30:00",
            "2024-06-15T11:00:00",
        )
        data = response.json()

        assert data.get("status") == "updated"
        assert data["clock"]["durationMinutes"] == 150

        todo = self._refetch_todo(api, title)
        clocks = [
            entry for entry in todo.get("logbook", []) if entry.get("type") == "clock"
        ]

        assert len(clocks) == 1
        assert clocks[0]["start"] == "2024-06-15T08:30:00"
        assert clocks[0]["end"] == "2024-06-15T11:00:00"
        assert clocks[0]["durationMinutes"] == 150

    def test_delete_clock_can_target_start_timestamp(self, api):
        title = "Clock delete test todo"
        todo = self._create_clocked_todo(api, title)
        api.add_clock(
            todo,
            "2024-06-15T09:00:00",
            "2024-06-15T10:00:00",
        )
        todo = self._refetch_todo(api, title)
        api.add_clock(
            todo,
            "2024-06-15T11:00:00",
            "2024-06-15T12:00:00",
        )
        todo = self._refetch_todo(api, title)

        response = api.delete_logbook_entry(
            todo,
            "2024-06-15",
            entry_type="clock",
            start="2024-06-15T09:00:00",
        )
        assert response.json().get("status") == "deleted"

        todo = self._refetch_todo(api, title)
        clocks = [
            entry for entry in todo.get("logbook", []) if entry.get("type") == "clock"
        ]

        assert len(clocks) == 1
        assert clocks[0]["start"] == "2024-06-15T11:00:00"
