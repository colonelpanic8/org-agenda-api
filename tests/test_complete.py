"""Integration tests for POST /complete endpoint."""

import re

import pytest


class TestCompleteTodo:
    """Tests for POST /complete endpoint."""

    def test_returns_200(self, api):
        """Endpoint should return 200 OK on successful completion."""
        # Get a todo to complete
        todos_response = api.get_all_todos()
        todos = todos_response.json()

        # Find an active todo
        active_todo = next(
            (t for t in todos["todos"] if t.get("todo") == "TODO"),
            None,
        )
        assert active_todo is not None, "Need an active TODO to test completion"

        response = api.complete_todo(active_todo)
        assert response.status_code == 200

    def test_returns_confirmation(self, api):
        """Endpoint should return confirmation with old and new state."""
        todos_response = api.get_all_todos()
        todos = todos_response.json()

        active_todo = next(
            (t for t in todos["todos"] if t.get("todo") == "TODO"),
            None,
        )
        assert active_todo is not None

        response = api.complete_todo(active_todo)
        data = response.json()

        assert data.get("status") == "completed"
        assert "oldState" in data
        assert "newState" in data
        assert data["newState"] == "DONE"

    def test_todo_state_changes(self, api):
        """Completed todo should have DONE state in subsequent queries."""
        # Create a unique todo to complete
        unique_title = "Complete test todo 98765"
        create_resp = api.create_todo(unique_title)
        assert create_resp.status_code == 200, f"create_todo failed: {create_resp.status_code} - {create_resp.text}"
        create_data = create_resp.json()
        assert create_data.get("status") == "created", f"capture didn't succeed: {create_data}"

        # Find it in the list
        todos_response = api.get_all_todos()
        todos = todos_response.json()
        all_titles = [t.get("title", "NO TITLE") for t in todos.get("todos", [])]

        todo_to_complete = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )
        assert todo_to_complete is not None, f"Created todo not found: {unique_title}. All todos: {all_titles}"

        # Complete it
        complete_response = api.complete_todo(todo_to_complete)
        assert complete_response.status_code == 200
        complete_data = complete_response.json()
        assert complete_data.get("status") == "completed", f"Complete failed: {complete_data}"

        # Verify state changed - note: position may change after state change
        todos_response = api.get_all_todos()
        todos = todos_response.json()

        # Search for the completed todo
        completed_todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )
        assert completed_todo is not None, f"Completed todo not found: {unique_title}"
        assert completed_todo["todo"] == "DONE", f"Expected DONE, got {completed_todo['todo']}"

    def test_complete_with_custom_state(self, api):
        """Should support completing with a custom state like CANCELLED."""
        # Create a unique todo
        unique_title = "Cancel test todo 11111"
        api.create_todo(unique_title)

        todos_response = api.get_all_todos()
        todos = todos_response.json()

        todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )
        assert todo is not None

        # Complete with CANCELLED state
        response = api.complete_todo(todo, state="CANCELLED")
        response.json()

        # Note: This will only work if CANCELLED is a valid done state
        # in the org-todo-keywords configuration
        assert response.status_code == 200

    def test_complete_by_id(self, api):
        """Should be able to complete a todo by org ID if available."""
        todos_response = api.get_all_todos()
        todos = todos_response.json()

        # Find a todo with an ID
        todo_with_id = next(
            (t for t in todos["todos"] if t.get("id") is not None),
            None,
        )

        if todo_with_id is None:
            pytest.skip("No todos with org IDs in test fixtures")

        response = api.complete_todo({"id": todo_with_id["id"], "title": todo_with_id["title"]})
        assert response.status_code == 200

    def test_error_on_not_found(self, api):
        """Should return error when todo is not found."""
        fake_todo = {
            "id": None,
            "file": "/nonexistent/file.org",
            "pos": 999999,
            "title": "Nonexistent todo",
        }

        response = api.complete_todo(fake_todo)
        data = response.json()

        assert data.get("status") == "error"
        assert "message" in data

    def test_creates_logbook_entry(self, api, org_dir):
        """Completing a todo should create a LOGBOOK entry with state change timestamp.

        This tests that the post-command-hook fix works correctly - org-mode logs
        state changes via a hook that needs to be explicitly run in non-interactive
        contexts.
        """
        # Create a unique todo
        unique_title = "Logbook test todo 77777"
        api.create_todo(unique_title)

        # Find it in the list
        todos_response = api.get_all_todos()
        todos = todos_response.json()

        todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )
        assert todo is not None, f"Created todo not found: {unique_title}"

        # Complete it
        response = api.complete_todo(todo)
        assert response.status_code == 200

        # Read the file and verify LOGBOOK entry was created
        from pathlib import Path
        file_path = Path(todo["file"])
        content = file_path.read_text()

        # Find the section for our todo
        # The LOGBOOK should contain a state change entry like:
        # :LOGBOOK:
        # - State "DONE"       from "TODO"       [2024-06-15 Sat 12:34]
        # :END:
        logbook_pattern = re.compile(
            r':LOGBOOK:\s*\n'
            r'- State "DONE"\s+from "TODO"\s+\[\d{4}-\d{2}-\d{2} \w{3} \d{2}:\d{2}\]\s*\n'
            r':END:',
            re.MULTILINE
        )

        assert logbook_pattern.search(content), (
            f"Expected LOGBOOK entry with state change not found in file.\n"
            f"File content:\n{content}"
        )


class TestCompleteWithOverrideDate:
    """Tests for completing todos with an override_date."""

    def test_complete_with_override_date_changes_logbook_timestamp(self, api, org_dir):
        """Completing with override_date should use that date in LOGBOOK entry."""
        # Create a unique todo
        unique_title = "Override date test todo 55555"
        api.create_todo(unique_title)

        # Find it
        todos_response = api.get_all_todos()
        todos = todos_response.json()

        todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )
        assert todo is not None, f"Created todo not found: {unique_title}"

        # Complete it with an override date in the past
        override_date = "2024-01-15"  # A past date
        response = api.complete_todo(todo, override_date=override_date)
        assert response.status_code == 200
        data = response.json()
        assert data.get("status") == "completed"

        # Read the file and verify LOGBOOK entry uses the override date
        from pathlib import Path
        file_path = Path(todo["file"])
        content = file_path.read_text()

        # The LOGBOOK should contain the override date
        assert "2024-01-15" in content, (
            f"Expected override date 2024-01-15 in LOGBOOK entry.\n"
            f"File content:\n{content}"
        )

    def test_complete_with_override_datetime_preserves_time(self, api, org_dir):
        """Completing with override_date including time should preserve the time."""
        unique_title = "Override datetime test todo 66666"
        api.create_todo(unique_title)

        todos_response = api.get_all_todos()
        todos = todos_response.json()

        todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )
        assert todo is not None

        # Complete with a specific datetime
        override_date = "2024-02-20T14:30:00"
        response = api.complete_todo(todo, override_date=override_date)
        assert response.status_code == 200

        from pathlib import Path
        file_path = Path(todo["file"])
        content = file_path.read_text()

        # Should contain the date and time
        assert "2024-02-20" in content
        assert "14:30" in content, (
            f"Expected time 14:30 in LOGBOOK entry.\n"
            f"File content:\n{content}"
        )

    def test_complete_without_override_date_creates_logbook(self, api, org_dir):
        """Completing without override_date creates a valid LOGBOOK entry."""
        unique_title = "No override date test todo 77778"
        api.create_todo(unique_title)

        todos_response = api.get_all_todos()
        todos = todos_response.json()

        todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )
        assert todo is not None

        response = api.complete_todo(todo)
        assert response.status_code == 200

        from pathlib import Path
        file_path = Path(todo["file"])
        content = file_path.read_text()

        # Should have a LOGBOOK entry with state change (actual date depends on system time)
        assert ":LOGBOOK:" in content
        assert 'State "DONE"' in content
        assert 'from "TODO"' in content

    def test_override_date_maintains_chronological_order(self, api, org_dir):
        """Logbook entries should maintain chronological order (newest first) when using override_date.

        This tests that when completing with an override_date that is earlier than
        existing entries, the new entry is inserted in the correct position rather
        than always at the top.
        """
        from pathlib import Path

        # Create a todo and complete it multiple times with different dates
        # to build up a logbook, then add one out of order
        unique_title = "Logbook order test todo 88888"
        api.create_todo(unique_title)

        # Find the todo
        todos_response = api.get_all_todos()
        todos = todos_response.json()
        todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )
        assert todo is not None

        # Complete with date Jan 20 (this will be the first entry)
        response = api.complete_todo(todo, override_date="2024-01-20")
        assert response.status_code == 200

        # The todo should now be DONE, get it again
        todos_response = api.get_all_todos()
        todos = todos_response.json()
        todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )
        assert todo is not None

        # Set back to TODO to allow another completion
        api.set_state(todo, "TODO")

        # Get updated todo
        todos_response = api.get_all_todos()
        todos = todos_response.json()
        todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )
        assert todo is not None

        # Complete with date Jan 10 (earlier than Jan 20 - should be inserted after)
        response = api.complete_todo(todo, override_date="2024-01-10")
        assert response.status_code == 200

        # Read the file and check the order
        file_path = Path(todo["file"])
        content = file_path.read_text()

        # Find the section for our specific todo (by title), then find its logbook
        # The todo heading is followed by its logbook
        todo_section_pattern = re.compile(
            r'\*+ (?:TODO|DONE) ' + re.escape(unique_title) + r'.*?\n'
            r'(.*?)'
            r'(?=^\*|\Z)',  # Until next heading or end of file
            re.MULTILINE | re.DOTALL
        )
        todo_section_match = todo_section_pattern.search(content)
        assert todo_section_match, f"Todo section not found in content:\n{content}"

        todo_section = todo_section_match.group(1)

        # Find the logbook within this todo's section
        logbook_match = re.search(
            r':LOGBOOK:\s*\n(.*?):END:',
            todo_section,
            re.DOTALL
        )
        assert logbook_match, f"LOGBOOK not found in todo section:\n{todo_section}"

        logbook_content = logbook_match.group(1)

        # Extract dates from logbook entries
        date_pattern = re.compile(r'\[(\d{4}-\d{2}-\d{2})')
        dates = date_pattern.findall(logbook_content)

        assert len(dates) >= 2, f"Expected at least 2 logbook entries, found {len(dates)}: {logbook_content}"

        # Dates should be in reverse chronological order (newest first)
        # Jan 20 should come before Jan 10
        assert dates == sorted(dates, reverse=True), (
            f"Logbook entries are not in chronological order (newest first).\n"
            f"Found dates: {dates}\n"
            f"Expected: {sorted(dates, reverse=True)}\n"
            f"Logbook content:\n{logbook_content}"
        )


class TestSetStateEndpoint:
    """Tests for POST /set-state endpoint."""

    def test_set_state_returns_200(self, api):
        """Endpoint should return 200 OK on successful state change."""
        unique_title = "Set state test todo 11111"
        api.create_todo(unique_title)

        todos_response = api.get_all_todos()
        todos = todos_response.json()

        todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )
        assert todo is not None

        response = api.set_state(todo, "DONE")
        assert response.status_code == 200
        data = response.json()
        assert data.get("status") == "completed"
        assert data.get("newState") == "DONE"

    def test_set_state_requires_state_parameter(self, api):
        """Endpoint should return error if state parameter is missing."""
        # Manually post without state parameter
        response = api.post("/set-state", json={
            "title": "Some todo",
        })
        data = response.json()
        assert data.get("status") == "error"
        assert "state" in data.get("message", "").lower()

    def test_set_state_with_override_date(self, api, org_dir):
        """set_state should support override_date parameter."""
        unique_title = "Set state override date test 22222"
        api.create_todo(unique_title)

        todos_response = api.get_all_todos()
        todos = todos_response.json()

        todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )
        assert todo is not None

        override_date = "2024-03-10"
        response = api.set_state(todo, "DONE", override_date=override_date)
        assert response.status_code == 200

        from pathlib import Path
        file_path = Path(todo["file"])
        content = file_path.read_text()

        assert "2024-03-10" in content, (
            f"Expected override date 2024-03-10 in LOGBOOK entry.\n"
            f"File content:\n{content}"
        )

    def test_set_state_to_non_done_state(self, api):
        """set_state should work with non-DONE states like CANCELLED."""
        unique_title = "Set state cancelled test 33333"
        api.create_todo(unique_title)

        todos_response = api.get_all_todos()
        todos = todos_response.json()

        todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )
        assert todo is not None

        response = api.set_state(todo, "CANCELLED")
        # This may fail if CANCELLED is not a configured state
        # but it should at least not error on the endpoint itself
        assert response.status_code == 200


class TestCompleteHabitResponse:
    """Tests for habit-related fields in /complete response."""

    def test_completing_habit_returns_habit_summary(self, api):
        """Completing a window-habit returns habitSummary in response."""
        import pytest

        # First get a habit todo
        todos_response = api.get_all_todos()
        todos = todos_response.json().get("todos", [])
        habit_todos = [t for t in todos if t.get("isWindowHabit") and t.get("todo") == "TODO"]

        if not habit_todos:
            pytest.skip("No uncompleted habits in test data")

        habit = habit_todos[0]
        response = api.complete_todo(habit)
        data = response.json()

        assert data.get("status") == "completed"
        assert "habitSummary" in data
        summary = data["habitSummary"]
        assert "conformingRatio" in summary
        assert "nextRequiredInterval" in summary
