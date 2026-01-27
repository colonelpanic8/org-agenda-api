"""Integration tests for POST /update endpoint."""


def extract_date(timestamp):
    """Extract date string from timestamp which may be object or string.

    Handles both new format {"date": "2024-06-15", "time": "10:00"}
    and legacy string format "2024-06-15" or "2024-06-15T10:00:00".
    Returns the YYYY-MM-DD date portion or None if timestamp is None.
    """
    if timestamp is None:
        return None
    if isinstance(timestamp, dict):
        return timestamp.get("date")
    if isinstance(timestamp, str):
        return timestamp[:10] if len(timestamp) >= 10 else timestamp
    return None


class TestUpdateTodo:
    """Tests for POST /update endpoint."""

    def test_returns_200(self, api):
        """Endpoint should return 200 OK on successful update."""
        todos_response = api.get_all_todos()
        todos = todos_response.json()

        active_todo = next(
            (t for t in todos["todos"] if t.get("todo") == "TODO"),
            None,
        )
        assert active_todo is not None

        response = api.update_todo(active_todo, {"priority": "A"})
        assert response.status_code == 200

    def test_returns_confirmation(self, api):
        """Endpoint should return confirmation with applied updates."""
        todos_response = api.get_all_todos()
        todos = todos_response.json()

        active_todo = next(
            (t for t in todos["todos"] if t.get("todo") == "TODO"),
            None,
        )
        assert active_todo is not None

        response = api.update_todo(active_todo, {"priority": "B"})
        data = response.json()

        assert data.get("status") == "updated"
        assert "title" in data
        assert "updates" in data


class TestUpdatePriority:
    """Tests for updating todo priority."""

    def test_set_priority_a(self, api):
        """Should be able to set priority to A."""
        unique_title = "Priority A test todo"
        api.create_todo(unique_title)

        todos_response = api.get_all_todos()
        todos = todos_response.json()

        todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )
        assert todo is not None

        response = api.update_todo(todo, {"priority": "A"})
        data = response.json()

        assert data.get("status") == "updated"
        # Updates may be returned as either a dict or array of [key, value] pairs
        updates = data.get("updates", {})
        if isinstance(updates, dict):
            assert "priority" in updates, (
                f"Expected priority in updates dict: {updates}"
            )
        else:
            priority_update = next((u for u in updates if u[0] == "priority"), None)
            assert priority_update is not None, f"Expected priority update in {updates}"

    def test_set_priority_b(self, api):
        """Should be able to set priority to B."""
        unique_title = "Priority B test todo"
        api.create_todo(unique_title)

        todos_response = api.get_all_todos()
        todos = todos_response.json()

        todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )
        assert todo is not None

        response = api.update_todo(todo, {"priority": "B"})
        assert response.status_code == 200

    def test_set_priority_c(self, api):
        """Should be able to set priority to C."""
        unique_title = "Priority C test todo"
        api.create_todo(unique_title)

        todos_response = api.get_all_todos()
        todos = todos_response.json()

        todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )
        assert todo is not None

        response = api.update_todo(todo, {"priority": "C"})
        assert response.status_code == 200

    def test_clear_priority(self, api):
        """Should be able to clear priority by setting null."""
        unique_title = "Clear priority test todo"
        api.create_todo(unique_title)

        todos_response = api.get_all_todos()
        todos = todos_response.json()

        todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )
        assert todo is not None

        # First set a priority
        api.update_todo(todo, {"priority": "A"})

        # Then clear it
        response = api.update_todo(todo, {"priority": None})
        assert response.status_code == 200

    def test_clear_priority_when_none_exists(self, api):
        """Should handle clearing priority on todo that has no priority."""
        unique_title = "Clear nonexistent priority test"
        api.create_todo(unique_title)

        todos_response = api.get_all_todos()
        todos = todos_response.json()

        todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )
        assert todo is not None
        # Newly created todo should have no priority
        assert todo.get("priority") is None

        # Try to clear priority when there is none - should not error
        response = api.update_todo(todo, {"priority": None})
        assert response.status_code == 200
        data = response.json()
        # Should succeed, not return an error
        assert data.get("status") == "updated"


class TestUpdateScheduledObjectFormat:
    """Tests for updating todo scheduled date using object format.

    The API accepts timestamps in object format: {"date": "YYYY-MM-DD", "time": "HH:MM", "repeater": {...}}
    This mirrors what mobile/web clients send.
    """

    def test_set_scheduled_with_date_object(self, api):
        """Should be able to set scheduled using object format with just date."""
        unique_title = "Scheduled object date test todo"
        api.create_todo(unique_title)

        todos_response = api.get_all_todos()
        todos = todos_response.json()

        todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )
        assert todo is not None

        # Use object format like the mobile client does
        response = api.update_todo(todo, {"scheduled": {"date": "2024-07-01"}})
        assert response.status_code == 200
        data = response.json()
        assert data.get("status") == "updated", (
            f"Expected 'updated' status, got: {data}"
        )

    def test_set_scheduled_with_date_and_time_object(self, api):
        """Should be able to set scheduled using object format with date and time."""
        unique_title = "Scheduled object datetime test todo"
        api.create_todo(unique_title)

        todos_response = api.get_all_todos()
        todos = todos_response.json()

        todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )
        assert todo is not None

        # Use object format with time
        response = api.update_todo(
            todo, {"scheduled": {"date": "2024-07-01", "time": "14:30"}}
        )
        assert response.status_code == 200
        data = response.json()
        assert data.get("status") == "updated", (
            f"Expected 'updated' status, got: {data}"
        )

    def test_set_scheduled_with_repeater_object(self, api):
        """Should be able to set scheduled using object format with repeater."""
        unique_title = "Scheduled object repeater test todo"
        api.create_todo(unique_title)

        todos_response = api.get_all_todos()
        todos = todos_response.json()

        todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )
        assert todo is not None

        # Use object format with repeater
        response = api.update_todo(
            todo,
            {
                "scheduled": {
                    "date": "2024-07-01",
                    "repeater": {"type": "+", "value": 1, "unit": "w"},
                }
            },
        )
        assert response.status_code == 200
        data = response.json()
        assert data.get("status") == "updated", (
            f"Expected 'updated' status, got: {data}"
        )

    def test_set_deadline_with_date_object(self, api):
        """Should be able to set deadline using object format with just date."""
        unique_title = "Deadline object date test todo"
        api.create_todo(unique_title)

        todos_response = api.get_all_todos()
        todos = todos_response.json()

        todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )
        assert todo is not None

        # Use object format like the mobile client does
        response = api.update_todo(todo, {"deadline": {"date": "2024-07-15"}})
        assert response.status_code == 200
        data = response.json()
        assert data.get("status") == "updated", (
            f"Expected 'updated' status, got: {data}"
        )


class TestUpdateScheduled:
    """Tests for updating todo scheduled date."""

    def test_set_scheduled_datetime(self, api):
        """Should be able to set scheduled date with time."""
        unique_title = "Scheduled datetime test todo"
        api.create_todo(unique_title)

        todos_response = api.get_all_todos()
        todos = todos_response.json()

        todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )
        assert todo is not None

        response = api.update_todo(todo, {"scheduled": "2024-07-01T14:30:00"})
        assert response.status_code == 200

    def test_clear_scheduled(self, api):
        """Should be able to clear scheduled date."""
        unique_title = "Clear scheduled test todo"
        api.create_todo(unique_title)

        todos_response = api.get_all_todos()
        todos = todos_response.json()

        todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )
        assert todo is not None

        # Set scheduled
        api.update_todo(todo, {"scheduled": "2024-07-01"})

        # Clear it
        response = api.update_todo(todo, {"scheduled": None})
        assert response.status_code == 200

    def test_future_scheduled_appears_on_correct_date(self, api):
        """Scheduling a todo in the future should make it appear on that date's agenda.

        This test verifies that:
        1. A todo scheduled 2 weeks in the future does NOT appear in today's agenda
        2. The todo DOES appear when querying the agenda for the future date
        3. The scheduled date persists on the todo when re-fetched
        """
        # Test date is 2024-06-15, schedule for 2 weeks later
        future_date = "2024-06-29"
        unique_title = "Future scheduled test todo 77777"

        # Create a new todo
        api.create_todo(unique_title)

        # Find the todo
        todos_response = api.get_all_todos()
        todos = todos_response.json()
        todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )
        assert todo is not None, f"Created todo not found: {unique_title}"

        # Schedule it for 2 weeks in the future
        update_response = api.update_todo(todo, {"scheduled": future_date})
        assert update_response.status_code == 200

        # Verify the scheduled date persists when re-fetching todos
        todos_response = api.get_all_todos()
        todos = todos_response.json()
        updated_todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )
        assert updated_todo is not None, "Todo disappeared after scheduling"
        assert updated_todo.get("scheduled") is not None, (
            f"Scheduled date not persisted on todo. Got: {updated_todo}"
        )
        assert extract_date(updated_todo["scheduled"]) == future_date, (
            f"Expected scheduled date to be {future_date}, "
            f"got: {updated_todo['scheduled']}"
        )

        # Verify it does NOT appear in today's agenda (TEST_DATE = 2024-06-15)
        today_agenda = api.get_agenda()
        today_entries = today_agenda.json().get("entries", [])
        today_titles = [e.get("title", "") for e in today_entries]
        assert not any(unique_title in t for t in today_titles), (
            f"Future-scheduled todo should NOT appear in today's agenda. "
            f"Found in: {today_titles}"
        )

        # Verify it DOES appear in the future date's agenda
        future_agenda = api.get_agenda(date=future_date)
        future_entries = future_agenda.json().get("entries", [])
        future_titles = [e.get("title", "") for e in future_entries]
        assert any(unique_title in t for t in future_titles), (
            f"Future-scheduled todo should appear in {future_date} agenda. "
            f"Found titles: {future_titles}"
        )


class TestUpdateDeadline:
    """Tests for updating todo deadline."""

    def test_set_deadline_datetime(self, api):
        """Should be able to set deadline with time."""
        unique_title = "Deadline datetime test todo"
        api.create_todo(unique_title)

        todos_response = api.get_all_todos()
        todos = todos_response.json()

        todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )
        assert todo is not None

        response = api.update_todo(todo, {"deadline": "2024-07-15T17:00:00"})
        assert response.status_code == 200

    def test_clear_deadline(self, api):
        """Should be able to clear deadline."""
        unique_title = "Clear deadline test todo"
        api.create_todo(unique_title)

        todos_response = api.get_all_todos()
        todos = todos_response.json()

        todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )
        assert todo is not None

        # Set deadline
        api.update_todo(todo, {"deadline": "2024-07-15"})

        # Clear it
        response = api.update_todo(todo, {"deadline": None})
        assert response.status_code == 200


class TestUpdateMultipleFields:
    """Tests for updating multiple fields at once."""

    def test_update_all_fields(self, api):
        """Should be able to update scheduled, deadline, and priority together."""
        unique_title = "Multi-update test todo"
        api.create_todo(unique_title)

        todos_response = api.get_all_todos()
        todos = todos_response.json()

        todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )
        assert todo is not None

        response = api.update_todo(
            todo,
            {
                "scheduled": "2024-07-01",
                "deadline": "2024-07-15",
                "priority": "A",
            },
        )
        data = response.json()

        assert data.get("status") == "updated"
        # Should have multiple updates applied
        assert len(data.get("updates", [])) >= 1


class TestUpdateTitle:
    """Tests for updating todo title."""

    def test_update_title(self, api):
        """Should be able to update the title of a todo."""
        unique_title = "Original title for update test"
        api.create_todo(unique_title)

        todos_response = api.get_all_todos()
        todos = todos_response.json()

        todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )
        assert todo is not None

        new_title = "Updated title for test"
        response = api.update_todo(todo, {"new_title": new_title})
        data = response.json()

        assert data.get("status") == "updated"
        assert data.get("title") == new_title

    def test_title_persists_after_update(self, api):
        """Updated title should persist when re-fetching todos."""
        unique_title = "Persistence title test 12345"
        api.create_todo(unique_title)

        todos_response = api.get_all_todos()
        todos = todos_response.json()

        todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )
        assert todo is not None

        new_title = "Persisted new title 67890"
        api.update_todo(todo, {"new_title": new_title})

        # Re-fetch and verify
        todos_response = api.get_all_todos()
        todos = todos_response.json()

        updated_todo = next(
            (t for t in todos["todos"] if new_title in t.get("title", "")),
            None,
        )
        assert updated_todo is not None, "Updated title not found in todos"

    def test_update_title_with_other_fields(self, api):
        """Should be able to update title along with other fields."""
        unique_title = "Multi-field title test"
        api.create_todo(unique_title)

        todos_response = api.get_all_todos()
        todos = todos_response.json()

        todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )
        assert todo is not None

        new_title = "New title with priority"
        response = api.update_todo(
            todo,
            {
                "new_title": new_title,
                "priority": "A",
            },
        )
        data = response.json()

        assert data.get("status") == "updated"
        assert data.get("title") == new_title


class TestUpdateErrors:
    """Tests for update error handling."""

    def test_error_on_not_found(self, api):
        """Should return error when todo is not found."""
        fake_todo = {
            "id": None,
            "file": "/nonexistent/file.org",
            "pos": 999999,
            "title": "Nonexistent todo",
        }

        response = api.update_todo(fake_todo, {"priority": "A"})
        data = response.json()

        assert data.get("status") == "error"
        assert "message" in data


class TestAutoAddOrgId:
    """Tests for auto-adding org-id on update operations."""

    def test_update_adds_org_id(self, api):
        """Updating a todo without an ID should auto-create one."""
        # Create a todo (capture does not add IDs)
        unique_title = "Auto-id update test todo 77777"
        api.create_todo(unique_title)

        # Find it in the list and verify it has no ID initially
        todos_response = api.get_all_todos()
        todos = todos_response.json()

        todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )
        assert todo is not None, f"Created todo not found: {unique_title}"
        assert todo.get("id") is None, "Newly created todo should not have an ID"

        # Update it (e.g., set priority)
        response = api.update_todo(todo, {"priority": "A"})
        assert response.status_code == 200
        data = response.json()
        assert data.get("status") == "updated"

        # Fetch again and verify ID was created
        todos_response = api.get_all_todos()
        todos = todos_response.json()

        updated_todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )
        assert updated_todo is not None, "Updated todo not found"
        assert updated_todo.get("id") is not None, (
            "Updated todo should have an auto-created ID"
        )
        # Verify it looks like a valid UUID format
        assert len(updated_todo["id"]) >= 32, (
            f"ID should be UUID format, got: {updated_todo['id']}"
        )

    def test_update_preserves_existing_org_id(self, api):
        """Updating a todo with an existing ID should not change it."""
        # Find a todo that already has an ID (from fixtures)
        todos_response = api.get_all_todos()
        todos = todos_response.json()

        todo_with_id = next(
            (t for t in todos["todos"] if t.get("id") is not None),
            None,
        )

        if todo_with_id is None:
            import pytest

            pytest.skip("No todos with org IDs in test fixtures")

        original_id = todo_with_id["id"]

        # Update the todo
        response = api.update_todo(todo_with_id, {"priority": "B"})
        assert response.status_code == 200

        # Verify ID was not changed
        todos_response = api.get_all_todos()
        todos = todos_response.json()

        updated_todo = next(
            (t for t in todos["todos"] if t.get("id") == original_id),
            None,
        )
        assert updated_todo is not None, "Todo with original ID not found"
        assert updated_todo["id"] == original_id, (
            f"ID changed from {original_id} to {updated_todo['id']}"
        )


class TestUpdateBody:
    """Tests for updating todo body content."""

    def test_set_body(self, api):
        """Should be able to set body content."""
        unique_title = "Body update test todo"
        api.create_todo(unique_title)

        todos_response = api.get_all_todos()
        todos = todos_response.json()

        todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )
        assert todo is not None

        body_content = "- [ ] First item\n- [X] Second item\n\nSome notes here"
        response = api.update_todo(todo, {"body": body_content})
        data = response.json()

        assert data.get("status") == "updated"
        updates = data.get("updates", {})
        if isinstance(updates, dict):
            assert "body" in updates
        else:
            body_update = next((u for u in updates if u[0] == "body"), None)
            assert body_update is not None

    def test_clear_body(self, api):
        """Should be able to clear body content with null."""
        unique_title = "Body clear test todo"
        api.create_todo(unique_title)

        todos_response = api.get_all_todos()
        todos = todos_response.json()

        todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )
        assert todo is not None

        # First set a body
        api.update_todo(todo, {"body": "Some content"})

        # Then clear it
        response = api.update_todo(todo, {"body": None})
        data = response.json()

        assert data.get("status") == "updated"

    def test_set_empty_body(self, api):
        """Should be able to set empty body content."""
        unique_title = "Body empty test todo"
        api.create_todo(unique_title)

        todos_response = api.get_all_todos()
        todos = todos_response.json()

        todo = next(
            (t for t in todos["todos"] if unique_title in t.get("title", "")),
            None,
        )
        assert todo is not None

        response = api.update_todo(todo, {"body": ""})
        data = response.json()

        assert data.get("status") == "updated"
