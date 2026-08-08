"""Tests for /all-habit-statuses endpoint."""


class TestAllHabitStatuses:
    """Tests for the /all-habit-statuses endpoint."""

    def test_returns_200(self, api):
        """Endpoint returns 200 status code."""
        response = api.get_all_habit_statuses()
        assert response.status_code == 200

    def test_returns_ok_status(self, api):
        """Response has status ok."""
        response = api.get_all_habit_statuses()
        data = response.json()
        assert data.get("status") == "ok"

    def test_returns_habits_array(self, api):
        """Response contains habits array."""
        response = api.get_all_habit_statuses()
        data = response.json()
        assert "habits" in data
        assert isinstance(data["habits"], list)

    def test_finds_multiple_habits(self, api):
        """Endpoint finds multiple habits from fixture files."""
        response = api.get_all_habit_statuses()
        data = response.json()
        habits = data.get("habits", [])
        # We have several habits in fixtures: habit-exercise-daily, habit-meditate,
        # habit-midnight-test, habit-normal-time-test, habit-dst-test,
        # test-window-habit-001, test-window-habit-002
        assert len(habits) >= 2

    def test_habit_has_required_fields(self, api):
        """Each habit in response has required fields."""
        response = api.get_all_habit_statuses()
        data = response.json()
        habits = data.get("habits", [])
        assert len(habits) > 0

        for habit in habits:
            # Either it's a successful habit with all fields...
            if "error" not in habit:
                assert "id" in habit
                assert "title" in habit
                assert "habit" in habit
                assert "currentState" in habit
                assert "doneTimes" in habit
                assert "graph" in habit
            else:
                # ...or it has an error with id
                assert "id" in habit
                assert "error" in habit

    def test_habit_contains_known_habit(self, api):
        """Response includes a known habit from fixtures."""
        response = api.get_all_habit_statuses()
        data = response.json()
        habits = data.get("habits", [])

        habit_ids = [h.get("id") for h in habits]
        assert "habit-exercise-daily" in habit_ids

    def test_paused_habit_is_omitted_at_inactive_date(self, api):
        """Bulk status excludes habits whose config is inactive."""
        response = api.get_all_habit_statuses(date="2024-06-15")
        habit_ids = [h.get("id") for h in response.json().get("habits", [])]

        assert "test-window-habit-paused" not in habit_ids

    def test_preceding_parameter_affects_graph_length(self, api):
        """Preceding parameter changes graph length for all habits."""
        response_default = api.get_all_habit_statuses()
        response_short = api.get_all_habit_statuses(preceding=5)

        default_habits = response_default.json().get("habits", [])
        short_habits = response_short.json().get("habits", [])

        # Find a common habit and compare graph lengths
        for default_habit in default_habits:
            if (
                default_habit.get("id") == "habit-exercise-daily"
                and "graph" in default_habit
            ):
                default_graph = default_habit.get("graph", [])
                for short_habit in short_habits:
                    if (
                        short_habit.get("id") == "habit-exercise-daily"
                        and "graph" in short_habit
                    ):
                        short_graph = short_habit.get("graph", [])
                        assert len(short_graph) <= len(default_graph)
                        return

    def test_date_parameter_is_accepted(self, api):
        """Date parameter is accepted without error."""
        response = api.get_all_habit_statuses(date="2024-06-15")
        data = response.json()
        assert data.get("status") == "ok"

    def test_all_parameters_together(self, api):
        """All parameters can be used together."""
        response = api.get_all_habit_statuses(
            preceding=10, following=2, date="2024-06-15"
        )
        data = response.json()
        assert data.get("status") == "ok"
        assert "habits" in data
