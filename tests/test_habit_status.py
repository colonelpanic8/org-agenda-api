"""Tests for /habit-status endpoint."""

import pytest


class TestHabitStatus:
    """Tests for the /habit-status endpoint."""

    def test_returns_200_for_valid_habit(self, api):
        """Endpoint returns 200 for a valid habit ID."""
        response = api.get_habit_status("habit-exercise-daily")
        assert response.status_code == 200

    def test_returns_error_for_missing_id(self, api):
        """Endpoint returns error when id parameter is missing."""
        response = api.get("/habit-status")
        data = response.json()
        assert data.get("status") == "error"

    def test_returns_error_for_nonexistent_id(self, api):
        """Endpoint returns error for non-existent org ID."""
        response = api.get_habit_status("nonexistent-id-12345")
        data = response.json()
        assert data.get("status") == "error"

    def test_returns_error_for_non_habit(self, api):
        """Endpoint returns error for entry that is not a window-habit."""
        response = api.get_habit_status("regular-todo-no-habit")
        data = response.json()
        assert data.get("status") == "error"
        assert "not" in data.get("message", "").lower()

    def test_has_required_fields(self, api):
        """Response has all required fields for a valid habit."""
        response = api.get_habit_status("habit-exercise-daily")
        data = response.json()
        assert data.get("status") == "ok", f"Expected ok, got error: {data.get('message')}"
        assert "id" in data
        assert "title" in data
        assert "habit" in data
        assert "currentState" in data
        assert "doneTimes" in data
        assert "graph" in data

    def test_habit_contains_config(self, api):
        """Habit field contains configuration."""
        response = api.get_habit_status("habit-exercise-daily")
        data = response.json()
        habit = data.get("habit", {})
        assert "assessmentInterval" in habit
        assert "windowSpecs" in habit

    def test_current_state_has_conforming_ratio(self, api):
        """Current state has conforming ratio between 0 and 1."""
        response = api.get_habit_status("habit-exercise-daily")
        data = response.json()
        state = data.get("currentState", {})
        ratio = state.get("conformingRatio")
        assert ratio is not None
        assert 0 <= ratio <= 1

    def test_graph_is_array(self, api):
        """Graph field is an array of intervals."""
        response = api.get_habit_status("habit-exercise-daily")
        data = response.json()
        graph = data.get("graph")
        assert isinstance(graph, list)
        assert len(graph) > 0

    def test_graph_entry_has_required_fields(self, api):
        """Each graph entry has required fields."""
        response = api.get_habit_status("habit-exercise-daily")
        data = response.json()
        graph = data.get("graph", [])
        if graph:
            entry = graph[0]
            assert "date" in entry
            assert "status" in entry
            assert "conformingRatioWithout" in entry
            assert "conformingRatioWith" in entry
            assert "completionCount" in entry

    def test_preceding_parameter_affects_graph_length(self, api):
        """Preceding parameter changes graph length."""
        response_default = api.get_habit_status("habit-exercise-daily")
        response_short = api.get_habit_status("habit-exercise-daily", preceding=5)

        default_graph = response_default.json().get("graph", [])
        short_graph = response_short.json().get("graph", [])

        # Shorter preceding should result in fewer or equal entries
        assert len(short_graph) <= len(default_graph)

    def test_done_times_is_array(self, api):
        """Done times field is an array of timestamps."""
        response = api.get_habit_status("habit-exercise-daily")
        data = response.json()
        done_times = data.get("doneTimes")
        assert isinstance(done_times, list)
