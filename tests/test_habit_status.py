"""Tests for /habit-status endpoint."""


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
        assert data.get("status") == "ok", (
            f"Expected ok, got error: {data.get('message')}"
        )
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


class TestWindowSpecsStatus:
    """Tests for per-window-spec conforming data in habit status."""

    def test_current_state_has_window_specs_status(self, api):
        """Current state should contain windowSpecsStatus array."""
        response = api.get_habit_status("habit-exercise-daily")
        data = response.json()
        state = data.get("currentState", {})
        assert "windowSpecsStatus" in state
        assert isinstance(state["windowSpecsStatus"], list)

    def test_current_state_has_aggregated_ratio(self, api):
        """Current state should contain aggregatedConformingRatio."""
        response = api.get_habit_status("habit-exercise-daily")
        data = response.json()
        state = data.get("currentState", {})
        assert "aggregatedConformingRatio" in state
        ratio = state["aggregatedConformingRatio"]
        assert isinstance(ratio, (int, float))
        assert 0 <= ratio <= 1

    def test_window_spec_status_has_required_fields(self, api):
        """Each window spec status should have all required fields."""
        response = api.get_habit_status("habit-exercise-daily")
        data = response.json()
        state = data.get("currentState", {})
        specs_status = state.get("windowSpecsStatus", [])

        assert len(specs_status) > 0, "Should have at least one window spec status"

        for spec_status in specs_status:
            assert "conformingRatio" in spec_status
            assert "completionsInWindow" in spec_status
            assert "targetRepetitions" in spec_status
            assert "duration" in spec_status
            assert "windowStart" in spec_status
            assert "windowEnd" in spec_status

    def test_window_spec_conforming_ratio_is_valid(self, api):
        """Each window spec's conforming ratio should be between 0 and 1."""
        response = api.get_habit_status("habit-exercise-daily")
        data = response.json()
        state = data.get("currentState", {})
        specs_status = state.get("windowSpecsStatus", [])

        for spec_status in specs_status:
            ratio = spec_status.get("conformingRatio")
            assert ratio is not None
            assert 0 <= ratio <= 1

    def test_window_spec_completions_is_non_negative(self, api):
        """Completions in window should be non-negative integer."""
        response = api.get_habit_status("habit-exercise-daily")
        data = response.json()
        state = data.get("currentState", {})
        specs_status = state.get("windowSpecsStatus", [])

        for spec_status in specs_status:
            completions = spec_status.get("completionsInWindow")
            assert isinstance(completions, int)
            assert completions >= 0

    def test_window_spec_target_is_positive(self, api):
        """Target repetitions should be a positive integer."""
        response = api.get_habit_status("habit-exercise-daily")
        data = response.json()
        state = data.get("currentState", {})
        specs_status = state.get("windowSpecsStatus", [])

        for spec_status in specs_status:
            target = spec_status.get("targetRepetitions")
            assert isinstance(target, int)
            assert target > 0

    def test_window_spec_duration_is_dict(self, api):
        """Duration should be a dictionary with duration units."""
        response = api.get_habit_status("habit-exercise-daily")
        data = response.json()
        state = data.get("currentState", {})
        specs_status = state.get("windowSpecsStatus", [])

        for spec_status in specs_status:
            duration = spec_status.get("duration")
            assert isinstance(duration, dict)
            # Should have at least one duration key like "days", "weeks", etc.
            assert len(duration) > 0

    def test_window_times_are_iso_strings(self, api):
        """Window start and end times should be ISO format strings."""
        response = api.get_habit_status("habit-exercise-daily")
        data = response.json()
        state = data.get("currentState", {})
        specs_status = state.get("windowSpecsStatus", [])

        for spec_status in specs_status:
            window_start = spec_status.get("windowStart")
            window_end = spec_status.get("windowEnd")
            assert isinstance(window_start, str)
            assert isinstance(window_end, str)
            # Basic ISO format check (YYYY-MM-DDTHH:MM:SS)
            assert "T" in window_start
            assert "T" in window_end

    def test_conforming_ratio_matches_completions_divided_by_target(self, api):
        """Conforming ratio should approximately equal completions/target (clamped to 1)."""
        response = api.get_habit_status("habit-exercise-daily")
        data = response.json()
        state = data.get("currentState", {})
        specs_status = state.get("windowSpecsStatus", [])

        for spec_status in specs_status:
            completions = spec_status.get("completionsInWindow")
            target = spec_status.get("targetRepetitions")
            ratio = spec_status.get("conformingRatio")
            expected = min(1.0, completions / target) if target > 0 else 0
            # Allow for some floating point tolerance
            assert abs(ratio - expected) < 0.01, (
                f"Expected ratio ~{expected}, got {ratio}"
            )
