"""Integration tests for POST /update endpoint - tags functionality."""

import uuid


class TestUpdateTags:
    """Tests for updating todo tags."""

    def test_set_tags_on_item_without_tags(self, api):
        """Should be able to set tags on an item that has no tags."""
        # Create a new todo (no tags by default)
        unique_title = f"Tags test no initial tags {uuid.uuid4().hex[:8]}"
        api.create_todo(unique_title)

        todos_response = api.get_all_todos()
        todos = todos_response.json()

        todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )
        assert todo is not None
        assert todo.get("tags") is None or todo.get("tags") == []

        # Set tags
        response = api.update_todo(todo, {"tags": ["work", "urgent"]})
        assert response.status_code == 200
        data = response.json()
        assert data.get("status") == "updated"

        # Verify tags are in the update response
        updates = data.get("updates", {})
        if isinstance(updates, dict):
            assert "tags" in updates, f"Expected tags in updates dict: {updates}"
        else:
            tags_update = next((u for u in updates if u[0] == "tags"), None)
            assert tags_update is not None, f"Expected tags update in {updates}"

        # Verify tags persist when re-fetching
        todos_response = api.get_all_todos()
        todos = todos_response.json()
        updated_todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )
        assert updated_todo is not None
        assert "work" in updated_todo.get("tags", [])
        assert "urgent" in updated_todo.get("tags", [])

    def test_replace_existing_tags(self, api):
        """Should replace all existing tags with new ones."""
        todos_response = api.get_all_todos()
        todos = todos_response.json()

        # Find an item that has existing tags
        todo = next(
            (t for t in todos["todos"] if t.get("tags") and "work" in t.get("tags", [])),
            None,
        )
        assert todo is not None, "Need a todo with 'work' tag for this test"

        # Replace tags with completely new ones
        response = api.update_todo(todo, {"tags": ["personal", "home"]})
        assert response.status_code == 200

        # Verify old tags are gone and new tags are present
        todos_response = api.get_all_todos()
        todos = todos_response.json()
        updated_todo = next(
            (t for t in todos["todos"] if t.get("title") == todo.get("title")),
            None,
        )
        assert updated_todo is not None
        tags = updated_todo.get("tags", [])
        assert "work" not in tags, f"Old tag 'work' should be removed, got: {tags}"
        assert "personal" in tags, f"New tag 'personal' should be present, got: {tags}"
        assert "home" in tags, f"New tag 'home' should be present, got: {tags}"

    def test_clear_all_tags(self, api):
        """Should clear all tags when empty array is sent."""
        # Create a todo and add tags
        unique_title = f"Clear tags test todo {uuid.uuid4().hex[:8]}"
        api.create_todo(unique_title)

        todos_response = api.get_all_todos()
        todos = todos_response.json()
        todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )
        assert todo is not None

        # First add some tags
        api.update_todo(todo, {"tags": ["temp", "toremove"]})

        # Verify tags were added
        todos_response = api.get_all_todos()
        todos = todos_response.json()
        todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )
        assert todo.get("tags") is not None and len(todo.get("tags", [])) > 0

        # Clear all tags
        response = api.update_todo(todo, {"tags": []})
        assert response.status_code == 200

        # Verify tags are cleared
        todos_response = api.get_all_todos()
        todos = todos_response.json()
        updated_todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )
        assert updated_todo is not None
        tags = updated_todo.get("tags")
        assert tags is None or tags == [], f"Tags should be cleared, got: {tags}"

    def test_null_tags_no_change(self, api):
        """Should not change tags when tags field is null."""
        todos_response = api.get_all_todos()
        todos = todos_response.json()

        # Find an item with tags
        todo = next(
            (t for t in todos["todos"] if t.get("tags") and len(t.get("tags", [])) > 0),
            None,
        )
        assert todo is not None, "Need a todo with tags for this test"
        original_tags = todo.get("tags", [])

        # Update with null tags (should not change)
        response = api.update_todo(todo, {"tags": None, "priority": "B"})
        assert response.status_code == 200

        # Verify tags unchanged
        todos_response = api.get_all_todos()
        todos = todos_response.json()
        updated_todo = next(
            (t for t in todos["todos"] if t.get("title") == todo.get("title")),
            None,
        )
        assert updated_todo is not None
        assert updated_todo.get("tags") == original_tags

    def test_omitted_tags_no_change(self, api):
        """Should not change tags when tags field is omitted."""
        todos_response = api.get_all_todos()
        todos = todos_response.json()

        # Find an item with tags
        todo = next(
            (t for t in todos["todos"] if t.get("tags") and len(t.get("tags", [])) > 0),
            None,
        )
        assert todo is not None, "Need a todo with tags for this test"
        original_tags = todo.get("tags", [])

        # Update without tags field
        response = api.update_todo(todo, {"priority": "C"})
        assert response.status_code == 200

        # Verify tags unchanged
        todos_response = api.get_all_todos()
        todos = todos_response.json()
        updated_todo = next(
            (t for t in todos["todos"] if t.get("title") == todo.get("title")),
            None,
        )
        assert updated_todo is not None
        assert updated_todo.get("tags") == original_tags

    def test_combined_update_with_tags(self, api):
        """Should be able to update tags along with other fields."""
        unique_title = f"Combined update with tags test {uuid.uuid4().hex[:8]}"
        api.create_todo(unique_title)

        todos_response = api.get_all_todos()
        todos = todos_response.json()
        todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )
        assert todo is not None

        # Update multiple fields including tags
        response = api.update_todo(todo, {
            "tags": ["project", "important"],
            "priority": "A",
            "scheduled": "2024-07-01",
        })
        assert response.status_code == 200
        data = response.json()
        assert data.get("status") == "updated"

        # Verify all fields updated
        todos_response = api.get_all_todos()
        todos = todos_response.json()
        updated_todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )
        assert updated_todo is not None
        assert "project" in updated_todo.get("tags", [])
        assert "important" in updated_todo.get("tags", [])
        assert updated_todo.get("priority") == "A"
        # scheduled is now an object with "date" key
        scheduled = updated_todo.get("scheduled")
        assert scheduled is not None
        assert scheduled.get("date") == "2024-07-01"


class TestTagsInAgendaOutput:
    """Tests that tags appear correctly in agenda endpoint outputs."""

    def test_tags_in_agenda_entries(self, api):
        """Tags should appear in /agenda endpoint entries."""
        # Create a todo with tags scheduled for test date
        unique_title = f"Agenda tags test {uuid.uuid4().hex[:8]}"
        api.create_todo(unique_title)

        todos_response = api.get_all_todos()
        todos = todos_response.json()
        todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )
        assert todo is not None

        # Add tags and schedule for test date
        api.update_todo(todo, {
            "tags": ["agenda", "visible"],
            "scheduled": "2024-06-15",  # TEST_DATE
        })

        # Check agenda output
        agenda_response = api.get_agenda(date="2024-06-15")
        entries = agenda_response.json().get("entries", [])

        agenda_entry = next(
            (e for e in entries if unique_title in e.get("title", "")),
            None,
        )
        assert agenda_entry is not None, f"Todo should appear in agenda. Entries: {entries}"
        assert "agenda" in agenda_entry.get("tags", []), f"Tags missing from agenda entry: {agenda_entry}"
        assert "visible" in agenda_entry.get("tags", [])

    def test_tags_in_todays_agenda(self, api):
        """Tags should appear in /get-todays-agenda endpoint."""
        # Create a todo with tags scheduled for test date
        unique_title = f"Todays agenda tags test {uuid.uuid4().hex[:8]}"
        api.create_todo(unique_title)

        todos_response = api.get_all_todos()
        todos = todos_response.json()
        todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )
        assert todo is not None

        # Add tags and schedule for test date
        api.update_todo(todo, {
            "tags": ["today", "tagged"],
            "scheduled": "2024-06-15",  # TEST_DATE
        })

        # Check today's agenda output
        agenda_response = api.get_todays_agenda()
        entries = agenda_response.json()

        # Find our entry (response is a list)
        if isinstance(entries, list):
            agenda_entry = next(
                (e for e in entries if unique_title in e.get("title", "")),
                None,
            )
        else:
            # Response might be wrapped
            entry_list = entries.get("entries", entries.get("todos", []))
            agenda_entry = next(
                (e for e in entry_list if unique_title in e.get("title", "")),
                None,
            )

        assert agenda_entry is not None, f"Todo should appear in today's agenda. Response: {entries}"
        assert "today" in agenda_entry.get("tags", []), f"Tags missing: {agenda_entry}"
