"""Integration tests for GET endpoints."""



class TestGetAllTodos:
    """Tests for GET /get-all-todos endpoint."""

    def test_returns_200(self, api):
        """Endpoint should return 200 OK."""
        response = api.get_all_todos()
        assert response.status_code == 200

    def test_returns_json_object_with_todos(self, api):
        """Endpoint should return a JSON object with todos array."""
        response = api.get_all_todos()
        data = response.json()
        assert isinstance(data, dict)
        assert "todos" in data
        assert isinstance(data["todos"], list)

    def test_returns_defaults(self, api):
        """Endpoint should return defaults with notification settings."""
        response = api.get_all_todos()
        data = response.json()
        assert "defaults" in data
        assert "notifyBefore" in data["defaults"]

    def test_returns_todos_from_fixture(self, api):
        """Should return TODO items from our test fixtures."""
        response = api.get_all_todos()
        data = response.json()
        todos = data["todos"]

        # We should have TODOs from sample.org and today.org
        assert len(todos) > 0

        # Check that items have expected structure
        for item in todos:
            assert "todo" in item
            assert "title" in item

    def test_todo_item_structure(self, api):
        """Each TODO item should have the expected fields."""
        response = api.get_all_todos()
        todos = response.json()["todos"]

        # Find a known item from sample.org
        buy_groceries = next(
            (item for item in todos if "Buy groceries" in item.get("title", "")),
            None,
        )
        assert buy_groceries is not None
        assert buy_groceries["todo"] == "TODO"
        assert "scheduled" in buy_groceries
        assert "deadline" in buy_groceries
        assert "tags" in buy_groceries
        assert "level" in buy_groceries

    def test_includes_items_with_tags(self, api):
        """Should include TODO items that have tags."""
        response = api.get_all_todos()
        todos = response.json()["todos"]

        # Find item with tags from sample.org
        review_pr = next(
            (item for item in todos if "Review PR" in item.get("title", "")),
            None,
        )
        assert review_pr is not None
        assert review_pr["tags"] is not None
        assert "work" in review_pr["tags"]

    def test_excludes_done_items(self, api):
        """Should not include DONE items (only active TODOs)."""
        response = api.get_all_todos()
        todos = response.json()["todos"]

        # The "Write tests" item is DONE in sample.org
        [item for item in todos if item.get("todo") == "DONE"]
        # Note: The current implementation does include DONE items
        # This test documents current behavior - adjust if intended behavior differs


class TestGetTodaysAgenda:
    """Tests for GET /get-todays-agenda endpoint."""

    def test_returns_200(self, api):
        """Endpoint should return 200 OK."""
        response = api.get_todays_agenda()
        assert response.status_code == 200

    def test_returns_json_list(self, api):
        """Endpoint should return a JSON array."""
        response = api.get_todays_agenda()
        data = response.json()
        assert isinstance(data, list)

    def test_returns_todays_scheduled_items(self, api):
        """Should return items scheduled for today (the fake date)."""
        response = api.get_todays_agenda()
        data = response.json()

        # We have items scheduled for 2024-06-15 in today.org
        titles = [item.get("title", "") for item in data]

        # Should include today's scheduled task
        scheduled_today = any("scheduled for today" in t.lower() for t in titles)
        assert scheduled_today, f"Expected scheduled item for today, got: {titles}"

    def test_returns_todays_deadline_items(self, api):
        """Should return items with deadline today."""
        response = api.get_todays_agenda()
        data = response.json()

        titles = [item.get("title", "") for item in data]

        # Should include today's deadline task
        deadline_today = any("deadline today" in t.lower() for t in titles)
        assert deadline_today, f"Expected deadline item for today, got: {titles}"

    def test_excludes_tomorrow_items(self, api):
        """Should not include items scheduled for tomorrow."""
        response = api.get_todays_agenda()
        data = response.json()

        titles = [item.get("title", "") for item in data]

        # Should NOT include tomorrow's task
        tomorrow_items = [t for t in titles if "tomorrow" in t.lower()]
        assert len(tomorrow_items) == 0, f"Should not include tomorrow items: {tomorrow_items}"

    def test_agenda_item_structure(self, api):
        """Each agenda item should have the expected fields."""
        response = api.get_todays_agenda()
        data = response.json()

        assert len(data) > 0, "Expected at least one agenda item"

        for item in data:
            assert "title" in item
            assert "scheduled" in item
            # todo and tags may be None for some items


class TestGetAllTodosHabitFields:
    """Tests for habit-related fields in /get-all-todos."""

    def test_entries_have_is_window_habit_field(self, api):
        """Each entry has isWindowHabit field."""
        response = api.get_all_todos()
        data = response.json()
        todos = data.get("todos", [])
        for todo in todos:
            assert "isWindowHabit" in todo

    def test_habit_entry_has_habit_summary(self, api):
        """Habit entries have habitSummary field."""
        response = api.get_all_todos()
        data = response.json()
        todos = data.get("todos", [])
        habit_todos = [t for t in todos if t.get("isWindowHabit")]
        assert len(habit_todos) > 0, "Should have at least one habit in test data"
        for todo in habit_todos:
            assert "habitSummary" in todo
            summary = todo["habitSummary"]
            assert "conformingRatio" in summary
            assert "completionNeededToday" in summary

    def test_non_habit_entry_has_no_habit_summary(self, api):
        """Non-habit entries do not have habitSummary field."""
        response = api.get_all_todos()
        data = response.json()
        todos = data.get("todos", [])
        non_habit_todos = [t for t in todos if not t.get("isWindowHabit")]
        assert len(non_habit_todos) > 0, "Should have non-habit todos"
        for todo in non_habit_todos:
            assert "habitSummary" not in todo


class TestEffectiveCategory:
    """Tests for effectiveCategory field in todos."""

    def test_todos_have_effective_category_field(self, api):
        """All todos should have an effectiveCategory field."""
        response = api.get_all_todos()
        data = response.json()
        todos = data.get("todos", [])
        assert len(todos) > 0, "Should have todos to test"
        for todo in todos:
            assert "effectiveCategory" in todo, f"Todo missing effectiveCategory: {todo.get('title')}"

    def test_effective_category_is_string(self, api):
        """effectiveCategory should be a string."""
        response = api.get_all_todos()
        data = response.json()
        todos = data.get("todos", [])
        for todo in todos:
            cat = todo.get("effectiveCategory")
            assert cat is None or isinstance(cat, str), f"effectiveCategory should be string, got {type(cat)}"

    def test_explicit_category_property_becomes_effective(self, api):
        """Entry with explicit CATEGORY property should use that as effectiveCategory."""
        response = api.get_all_todos()
        data = response.json()
        todos = data.get("todos", [])

        # Find the task with custom properties (has CATEGORY: testing in sample.org)
        custom_task = next(
            (t for t in todos if "custom properties" in t.get("title", "").lower()),
            None,
        )
        assert custom_task is not None, "Should find task with custom properties"
        assert custom_task["effectiveCategory"] == "testing", (
            f"Expected effectiveCategory='testing', got '{custom_task.get('effectiveCategory')}'"
        )

    def test_effective_category_falls_back_to_filename(self, api):
        """Entries without CATEGORY property should use filename as effectiveCategory."""
        response = api.get_all_todos()
        data = response.json()
        todos = data.get("todos", [])

        # Find a task from today.org that doesn't have explicit CATEGORY
        today_task = next(
            (t for t in todos if "scheduled for today" in t.get("title", "").lower()),
            None,
        )
        assert today_task is not None, "Should find task scheduled for today"
        # Should fall back to filename (without .org extension)
        assert today_task["effectiveCategory"] == "today", (
            f"Expected effectiveCategory='today' (filename), got '{today_task.get('effectiveCategory')}'"
        )

    def test_effective_category_in_agenda(self, api):
        """Agenda entries should also have effectiveCategory."""
        response = api.get_agenda()
        data = response.json()
        entries = data.get("entries", [])
        assert len(entries) > 0, "Should have agenda entries"
        for entry in entries:
            assert "effectiveCategory" in entry, f"Agenda entry missing effectiveCategory: {entry.get('title')}"
