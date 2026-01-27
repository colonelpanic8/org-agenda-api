"""Tests for midnight (00:00) timestamp handling in habit completions.

This test reproduces the bug where completions logged at 00:00 are
incorrectly counted for the previous day due to timezone handling issues.
"""


class TestMidnightTimestamps:
    """Tests for habit completions at midnight (00:00)."""

    def test_completion_at_midnight_counted_for_correct_date(self, api):
        """Completion logged at 00:00 should be counted for that date, not the previous day.

        Bug: When a habit is completed and logged as [2024-06-15 Sat 00:00],
        the completion might be incorrectly counted for 2024-06-14 instead
        of 2024-06-15 due to timezone handling.

        Uses fixture: habit-midnight-test which has:
        - [2024-06-15 Sat 00:00] completion
        - [2024-06-14 Fri 00:00] completion
        - [2024-06-13 Thu 10:00] completion
        """
        # Get habit status with explicit reference date matching fixture
        response = api.get_habit_status(
            "habit-midnight-test", preceding=7, following=1, date="2024-06-15"
        )
        assert response.status_code == 200, f"Failed: {response.text}"

        data = response.json()
        assert data.get("status") == "ok", f"Error: {data.get('message')}"

        # Debug output
        print(f"\n\nDone times: {data.get('doneTimes', [])}")

        graph = data.get("graph", [])
        print(f"Graph dates: {[e.get('date') for e in graph]}")
        assert len(graph) > 0, "Graph should have entries"

        # Find the entries for 2024-06-14 and 2024-06-15 (the dates with 00:00 timestamps)
        entry_14 = next((e for e in graph if e["date"] == "2024-06-14"), None)
        entry_15 = next((e for e in graph if e["date"] == "2024-06-15"), None)

        print(f"Entry 2024-06-14: {entry_14}")
        print(f"Entry 2024-06-15: {entry_15}")

        # Both dates should have completionCount >= 1
        assert entry_14 is not None, "Should have entry for 2024-06-14"
        assert entry_15 is not None, "Should have entry for 2024-06-15"

        # The completion at [2024-06-15 Sat 00:00] should count for 2024-06-15
        assert entry_15["completionCount"] >= 1, (
            f"2024-06-15 should have completionCount >= 1 (has completion at 00:00), "
            f"but got {entry_15['completionCount']}. "
            f"Full entry: {entry_15}"
        )

        # The completion at [2024-06-14 Fri 00:00] should count for 2024-06-14
        assert entry_14["completionCount"] >= 1, (
            f"2024-06-14 should have completionCount >= 1 (has completion at 00:00), "
            f"but got {entry_14['completionCount']}. "
            f"Full entry: {entry_14}"
        )

    def test_completion_at_midnight_vs_normal_time(self, api):
        """Compare completion counting between midnight and normal timestamps.

        This test verifies that a completion at 00:00 is treated the same
        as a completion at any other time on the same date.

        Compares:
        - habit-midnight-test: completions at 00:00
        - habit-normal-time-test: completions at 10:00
        """
        # Get status for both habits with explicit reference date
        midnight_response = api.get_habit_status(
            "habit-midnight-test", preceding=7, following=1, date="2024-06-15"
        )
        normal_response = api.get_habit_status(
            "habit-normal-time-test", preceding=7, following=1, date="2024-06-15"
        )

        assert midnight_response.status_code == 200
        assert normal_response.status_code == 200

        midnight_data = midnight_response.json()
        normal_data = normal_response.json()

        assert midnight_data.get("status") == "ok", f"Error: {midnight_data.get('message')}"
        assert normal_data.get("status") == "ok", f"Error: {normal_data.get('message')}"

        midnight_graph = midnight_data.get("graph", [])
        normal_graph = normal_data.get("graph", [])

        # Find 2024-06-14 and 2024-06-15 entries in both
        midnight_14 = next(
            (e for e in midnight_graph if e["date"] == "2024-06-14"), None
        )
        normal_14 = next(
            (e for e in normal_graph if e["date"] == "2024-06-14"), None
        )
        midnight_15 = next(
            (e for e in midnight_graph if e["date"] == "2024-06-15"), None
        )
        normal_15 = next(
            (e for e in normal_graph if e["date"] == "2024-06-15"), None
        )

        print(f"\nMidnight habit 2024-06-14: {midnight_14}")
        print(f"Normal habit 2024-06-14: {normal_14}")
        print(f"Midnight habit 2024-06-15: {midnight_15}")
        print(f"Normal habit 2024-06-15: {normal_15}")

        assert midnight_14 is not None, "Midnight habit should have 2024-06-14 entry"
        assert normal_14 is not None, "Normal habit should have 2024-06-14 entry"
        assert midnight_15 is not None, "Midnight habit should have 2024-06-15 entry"
        assert normal_15 is not None, "Normal habit should have 2024-06-15 entry"

        # Both should have the same completion count for each date
        assert midnight_14["completionCount"] == normal_14["completionCount"], (
            f"Midnight completion on 2024-06-14 ({midnight_14['completionCount']}) should be "
            f"counted the same as normal time completion ({normal_14['completionCount']})"
        )

        assert midnight_15["completionCount"] == normal_15["completionCount"], (
            f"Midnight completion on 2024-06-15 ({midnight_15['completionCount']}) should be "
            f"counted the same as normal time completion ({normal_15['completionCount']})"
        )

    def test_done_times_includes_midnight_timestamps(self, api):
        """Verify that doneTimes array correctly includes midnight timestamps."""
        response = api.get_habit_status("habit-midnight-test")
        assert response.status_code == 200

        data = response.json()
        assert data.get("status") == "ok", f"Error: {data.get('message')}"

        done_times = data.get("doneTimes", [])
        print(f"\nDone times: {done_times}")

        # Should have 3 done times
        assert len(done_times) == 3, f"Expected 3 done times, got {len(done_times)}: {done_times}"

        # Extract dates from done times (could be string or dict format)
        done_dates = []
        for dt in done_times:
            if isinstance(dt, dict):
                done_dates.append(dt.get("date", "")[:10])
            else:
                done_dates.append(dt[:10] if dt else "")

        print(f"Extracted dates: {done_dates}")

        # All three dates should be present
        assert "2024-06-15" in done_dates, (
            f"2024-06-15 should be in done times. Got: {done_dates}"
        )
        assert "2024-06-14" in done_dates, (
            f"2024-06-14 should be in done times. Got: {done_dates}"
        )
        assert "2024-06-13" in done_dates, (
            f"2024-06-13 should be in done times. Got: {done_dates}"
        )
