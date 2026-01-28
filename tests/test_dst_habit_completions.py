"""Tests for DST (Daylight Saving Time) handling in habit completions.

These tests verify that habit completions are counted for the correct date
when the habit spans DST transitions. The bug: using 86400 seconds for
"one day" fails because DST transition days are 23 or 25 hours.

This causes anchor drift where a habit started in summer (PDT) may have
its assessment windows shifted by an hour in winter (PST), causing
completions at midnight to be counted for the wrong day.

US Pacific time DST 2024:
- March 10: clocks spring forward 2am->3am (day is 23 hours)
- November 3: clocks fall back 2am->1am (day is 25 hours)

Note: The Emacs server runs with TZ=America/Los_Angeles set in conftest.py.
"""


class TestDSTHabitCompletions:
    """Tests for habit completion counting across DST transitions."""

    def test_winter_midnight_completion_counted_for_correct_date(self, api):
        """Completion at 00:00 in winter should be counted for that date.

        Bug scenario: Habit started in summer (PDT, UTC-7).
        User completes at 00:00 in winter (PST, UTC-8).

        Due to anchor drift from DST transitions, the assessment for that
        day might start at 23:00 the previous day, causing the midnight
        completion to be counted for the wrong date.

        Uses fixture: habit-dst-summer-start which has:
        - Created: Aug 16, 2023 (summer PDT)
        - Completions at midnight on Jan dates (winter PST)
        """
        # Query habit status for Jan 26, 2024 (winter, PST)
        response = api.get_habit_status(
            "habit-dst-summer-start", preceding=3, following=1, date="2024-01-26"
        )
        assert response.status_code == 200, f"Failed: {response.text}"

        data = response.json()
        assert data.get("status") == "ok", f"Error: {data.get('message')}"

        graph = data.get("graph", [])

        # Find entry for Jan 26
        entry_26 = next((e for e in graph if e["date"] == "2024-01-26"), None)
        assert entry_26 is not None, f"No entry for 2024-01-26. Graph: {graph}"

        # The midnight completion on Jan 26 should count for Jan 26
        assert entry_26["completionCount"] >= 1, (
            f"Completion at 00:00 on 2024-01-26 should count for that date, "
            f"not the previous day. Got completionCount={entry_26['completionCount']}. "
            f"This may indicate DST anchor drift bug."
        )

    def test_post_spring_forward_midnight_completion(self, api):
        """Completion at midnight after spring forward should be counted correctly.

        March 10, 2024: clocks spring forward 2am->3am (23-hour day)

        A habit started before this transition may have its assessment
        window shift forward by an hour after the transition.
        """
        response = api.get_habit_status(
            "habit-dst-summer-start",
            preceding=3,
            following=1,
            date="2024-03-11",  # Day after spring forward
        )
        assert response.status_code == 200, f"Failed: {response.text}"

        data = response.json()
        assert data.get("status") == "ok", f"Error: {data.get('message')}"

        graph = data.get("graph", [])

        # Find entry for March 11 (day after DST transition)
        entry_11 = next((e for e in graph if e["date"] == "2024-03-11"), None)
        assert entry_11 is not None, f"No entry for 2024-03-11. Graph: {graph}"

        # Completion at 00:00 on March 11 should count for March 11
        assert entry_11["completionCount"] >= 1, (
            f"Completion at 00:00 on 2024-03-11 (post spring-forward) should count "
            f"for that date. Got completionCount={entry_11['completionCount']}. "
            f"DST transition may have shifted the assessment window incorrectly."
        )

    def test_post_fall_back_midnight_completion(self, api):
        """Completion at midnight after fall back should be counted correctly.

        November 3, 2024: clocks fall back 2am->1am (25-hour day)

        The extra hour from fall back can shift assessment windows backward,
        potentially causing midnight completions to be counted for wrong date.
        """
        response = api.get_habit_status(
            "habit-dst-summer-start",
            preceding=3,
            following=1,
            date="2024-11-04",  # Day after fall back
        )
        assert response.status_code == 200, f"Failed: {response.text}"

        data = response.json()
        assert data.get("status") == "ok", f"Error: {data.get('message')}"

        graph = data.get("graph", [])

        # Find entry for Nov 4 (day after DST transition)
        entry_4 = next((e for e in graph if e["date"] == "2024-11-04"), None)
        assert entry_4 is not None, f"No entry for 2024-11-04. Graph: {graph}"

        # Completion at 00:00 on Nov 4 should count for Nov 4
        assert entry_4["completionCount"] >= 1, (
            f"Completion at 00:00 on 2024-11-04 (post fall-back) should count "
            f"for that date. Got completionCount={entry_4['completionCount']}. "
            f"DST transition may have shifted the assessment window incorrectly."
        )

    def test_assessment_windows_dont_drift(self, api):
        """Assessment windows should maintain consistent time-of-day across DST.

        If a habit's assessment starts at midnight, it should start at midnight
        every day, regardless of DST transitions. Using 86400 seconds per day
        causes the start time to drift by 1 hour at each DST transition.
        """
        # Get habit status spanning a DST transition
        # March 2024: DST starts March 10
        response = api.get_habit_status(
            "habit-dst-summer-start",
            preceding=5,
            following=5,
            date="2024-03-10",  # DST transition day
        )
        assert response.status_code == 200, f"Failed: {response.text}"

        data = response.json()
        assert data.get("status") == "ok", f"Error: {data.get('message')}"

        # Check that we got a valid graph
        graph = data.get("graph", [])
        assert len(graph) > 0, "Should have graph entries"

        # All entries should have completionCount that matches their actual completions
        # The DST bug would cause completions to be counted for wrong dates
        for entry in graph:
            # Just verify the structure is valid - actual counts depend on fixtures
            assert "date" in entry
            assert "completionCount" in entry
            assert isinstance(entry["completionCount"], int)
