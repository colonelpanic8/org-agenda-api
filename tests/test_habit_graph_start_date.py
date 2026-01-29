"""Tests for habit graph start date boundary condition.

This tests the off-by-one bug where habits that started recently
(e.g., yesterday) don't have their start date included in the graph,
even when there was a completion on that date.

Test date is 2024-06-15 (configured in conftest.py).
"""

# Test date from conftest.py
TEST_DATE = "2024-06-15"


class TestHabitGraphStartDate:
    """Tests that habit graph correctly includes the start date."""

    def test_graph_includes_start_date_with_completion(self, api):
        """Graph should include the habit start date when requesting preceding intervals.

        The habit 'habit-newly-started' started on 2024-06-14 and has a completion
        on that day. When we request the graph on 2024-06-15 (test date) with
        preceding=14, the graph should include 2024-06-14 as the first entry.

        This tests the boundary condition: when start_time equals the first
        requested interval date, that date should be included.
        """
        response = api.get_habit_status(
            "habit-newly-started", preceding=14, date=TEST_DATE
        )
        data = response.json()

        assert data.get("status") == "ok", f"Expected ok, got error: {data.get('message')}"

        graph = data.get("graph", [])
        assert len(graph) > 0, "Graph should not be empty"

        # Get all dates in the graph
        graph_dates = [entry["date"] for entry in graph]

        # The start date (2024-06-14) should be in the graph
        assert "2024-06-14" in graph_dates, (
            f"Start date 2024-06-14 should be in graph. "
            f"Graph dates: {graph_dates}"
        )

        # The first date in the graph should be the start date
        # (since we're requesting 14 preceding days but habit only started yesterday)
        assert graph_dates[0] == "2024-06-14", (
            f"First graph date should be start date 2024-06-14, "
            f"but got {graph_dates[0]}. Full graph dates: {graph_dates}"
        )

    def test_graph_shows_completion_on_start_date(self, api):
        """Graph entry for start date should show the completion.

        The habit has a completion on 2024-06-14 at 12:00. The graph entry
        for that date should have completionCount > 0.
        """
        response = api.get_habit_status(
            "habit-newly-started", preceding=14, date=TEST_DATE
        )
        data = response.json()

        assert data.get("status") == "ok", f"Expected ok, got error: {data.get('message')}"

        graph = data.get("graph", [])

        # Find the entry for the start date
        start_date_entry = None
        for entry in graph:
            if entry["date"] == "2024-06-14":
                start_date_entry = entry
                break

        assert start_date_entry is not None, (
            "Should find entry for start date 2024-06-14 in graph"
        )

        assert start_date_entry["completionCount"] > 0, (
            f"Start date entry should show completion, "
            f"but completionCount is {start_date_entry['completionCount']}"
        )

    def test_done_times_includes_start_date_completion(self, api):
        """Verify the doneTimes array includes the completion on start date.

        This confirms the completion data exists in the backend, even if
        the graph doesn't show it (helping isolate the bug).
        """
        response = api.get_habit_status("habit-newly-started", date=TEST_DATE)
        data = response.json()

        assert data.get("status") == "ok", f"Expected ok, got error: {data.get('message')}"

        done_times = data.get("doneTimes", [])
        assert len(done_times) > 0, "Should have at least one done time"

        # Check that there's a completion on 2024-06-14
        june_14_completions = [
            dt for dt in done_times if dt.startswith("2024-06-14")
        ]
        assert len(june_14_completions) > 0, (
            f"Should have completion on 2024-06-14. Done times: {done_times}"
        )


class TestAllHabitStatusesStartDate:
    """Tests that all-habit-statuses also includes start date correctly."""

    def test_newly_started_habit_graph_includes_start_date(self, api):
        """All habit statuses should include start date for newly started habits."""
        response = api.get_all_habit_statuses(preceding=14, date=TEST_DATE)
        data = response.json()

        assert data.get("status") == "ok"

        habits = data.get("habits", [])
        newly_started = None
        for habit in habits:
            if habit.get("id") == "habit-newly-started":
                newly_started = habit
                break

        assert newly_started is not None, (
            "Should find habit-newly-started in all-habit-statuses response"
        )

        graph = newly_started.get("graph", [])
        assert len(graph) > 0, "Graph should not be empty"

        graph_dates = [entry["date"] for entry in graph]

        assert "2024-06-14" in graph_dates, (
            f"Start date 2024-06-14 should be in graph. "
            f"Graph dates: {graph_dates}"
        )
