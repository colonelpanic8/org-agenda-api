"""Integration tests for POST /update endpoint."""



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
        assert future_date in updated_todo["scheduled"], (
            f"Expected scheduled date to contain {future_date}, "
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
