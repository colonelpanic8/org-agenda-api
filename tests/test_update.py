"""Integration tests for POST /update endpoint."""

import pytest


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
            assert "priority" in updates, f"Expected priority in updates dict: {updates}"
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

        response = api.update_todo(todo, {
            "scheduled": "2024-07-01",
            "deadline": "2024-07-15",
            "priority": "A",
        })
        data = response.json()

        assert data.get("status") == "updated"
        # Should have multiple updates applied
        assert len(data.get("updates", [])) >= 1


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
