"""Integration tests for include_completed parameter on /agenda endpoint."""

import re
from datetime import date

from conftest import TEST_DATE, TEST_DATE_NEXT_DAY, TEST_DATE_ORG


def get_today_str():
    """Return today's date as YYYY-MM-DD string.

    Note: The CLOSED timestamp uses the real date, not the fake test date.
    This is because org-mode uses current-time for CLOSED timestamps,
    which isn't overridden by our test setup.
    """
    return date.today().strftime("%Y-%m-%d")


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


class TestIncludeCompleted:
    """Tests for include_completed=true on GET /agenda."""

    def test_completed_item_appears_with_flag(self, api):
        """Completed todo should appear in agenda when include_completed=true."""
        # Get an active todo to complete
        # IMPORTANT: Exclude habits (items with repeating deadlines) because
        # org-mode removes CLOSED timestamp when repeating tasks reset to TODO
        todos_response = api.get_all_todos()
        todos = todos_response.json()

        active_todo = next(
            (t for t in todos["todos"]
             if t.get("todo") == "TODO"
             and not t.get("isWindowHabit", False)  # Exclude window habits
             and "habit" not in t.get("title", "").lower()  # Exclude other habits by name
             and "Exercise" not in t.get("title", "")  # Exclude specific habit fixtures
             and "Meditate" not in t.get("title", "")),
            None,
        )
        assert active_todo is not None, "Need an active non-habit TODO to test"

        original_title = active_todo["title"]

        # Complete it
        complete_response = api.complete_todo(active_todo)
        assert complete_response.status_code == 200, f"Complete failed: {complete_response.text}"

        # Query agenda for TODAY's date (not fake test date) with include_completed=true
        # CLOSED timestamps use real date, not the fake test date
        today = get_today_str()
        agenda_response = api.get(f"/agenda?date={today}&include_completed=true")
        assert agenda_response.status_code == 200

        entries = agenda_response.json().get("entries", [])

        # Debug: print all entries to see what we got
        entry_info = [(e.get("title"), e.get("todo"), e.get("completedAt"), e.get("agendaLine", "")[:50]) for e in entries]

        # Find the completed item by title
        completed_entry = next(
            (e for e in entries if original_title in e.get("title", "")),
            None,
        )
        assert completed_entry is not None, (
            f"Completed todo '{original_title}' not found in agenda for {today}. "
            f"Entries: {entry_info}"
        )
        assert completed_entry.get("todo") == "DONE"

    def test_completed_item_not_shown_by_default(self, api):
        """Completed todo should NOT appear in agenda without include_completed flag."""
        # Get an active todo to complete
        todos_response = api.get_all_todos()
        todos = todos_response.json()

        # Find a todo that's scheduled for TEST_DATE so we can verify it disappears
        active_todo = next(
            (t for t in todos["todos"]
             if t.get("todo") == "TODO" and extract_date(t.get("scheduled")) == TEST_DATE),
            None,
        )
        if active_todo is None:
            # Skip if no suitable todo found
            import pytest
            pytest.skip("No TODO scheduled for test date found")

        original_title = active_todo["title"]

        # Complete it
        api.complete_todo(active_todo)

        # Query agenda WITHOUT include_completed
        agenda_response = api.get(f"/agenda?date={TEST_DATE}")
        assert agenda_response.status_code == 200

        entries = agenda_response.json().get("entries", [])

        # The completed item should NOT appear (unless it has a scheduled/deadline for that day)
        # Since we completed it, if it appears it should be because of scheduled, not completion
        done_entries = [e for e in entries if e.get("todo") == "DONE" and original_title in e.get("title", "")]

        # With log mode off, completed items shouldn't appear based on completion time alone.
        # They might still appear if they have scheduled/deadline for the date.
        # The completedAt field IS populated (we read CLOSED from the entry) - that's correct.
        # The key test is that items don't appear *solely because* of completion time.
        # Since this item has a scheduled date, it might still appear - that's expected.
        # We just verify it's appearing because of scheduled, not a log entry.
        for entry in done_entries:
            # Entry should have scheduled to appear without include_completed
            assert entry.get("scheduled") is not None, (
                "DONE item without include_completed should only appear due to scheduled/deadline, not completion"
            )

    def test_completed_item_wrong_date_not_shown(self, api):
        """Completed todo should only appear on the date it was completed."""
        # Get an active todo
        todos_response = api.get_all_todos()
        todos = todos_response.json()

        active_todo = next(
            (t for t in todos["todos"] if t.get("todo") == "TODO"),
            None,
        )
        assert active_todo is not None

        # Complete it (on TEST_DATE since that's our fake "today")
        api.complete_todo(active_todo)

        # Query agenda for NEXT day with include_completed=true
        agenda_response = api.get(f"/agenda?date={TEST_DATE_NEXT_DAY}&include_completed=true")
        assert agenda_response.status_code == 200

        entries = agenda_response.json().get("entries", [])

        # Should NOT find this completed item on the next day
        completed_entry = next(
            (e for e in entries
             if active_todo["title"] in e.get("title", "") and e.get("completedAt")),
            None,
        )
        assert completed_entry is None, (
            f"Completed todo should not appear on {TEST_DATE_NEXT_DAY}, "
            f"it was completed on {TEST_DATE}"
        )

    def test_completed_at_field_populated(self, api):
        """Completed items should have completedAt timestamp."""
        # Get an active todo (exclude habits - they don't keep CLOSED after reset)
        todos_response = api.get_all_todos()
        todos = todos_response.json()

        active_todo = next(
            (t for t in todos["todos"]
             if t.get("todo") == "TODO"
             and not t.get("isWindowHabit", False)
             and "habit" not in t.get("title", "").lower()
             and "Exercise" not in t.get("title", "")
             and "Meditate" not in t.get("title", "")),
            None,
        )
        assert active_todo is not None, "Need an active non-habit TODO to test"

        # Complete it
        api.complete_todo(active_todo)

        # Query with include_completed for TODAY's date (CLOSED uses real date)
        today = get_today_str()
        agenda_response = api.get(f"/agenda?date={today}&include_completed=true")
        entries = agenda_response.json().get("entries", [])

        # Debug: print all entries
        entry_info = [(e.get("title"), e.get("todo"), e.get("completedAt")) for e in entries]

        # Find the completed item
        completed_entry = next(
            (e for e in entries if active_todo["title"] in e.get("title", "")),
            None,
        )
        assert completed_entry is not None, (
            f"Completed todo '{active_todo['title']}' not found in agenda for {today}. "
            f"Entries: {entry_info}"
        )

        # Should have completedAt field with timestamp
        completed_at = completed_entry.get("completedAt")
        assert completed_at is not None, (
            f"completedAt field should be populated. Entry: {completed_entry}"
        )
        assert today in completed_at, (
            f"completedAt should contain today's date {today}, got {completed_at}"
        )

    def test_multiple_completions_same_day(self, api):
        """Multiple items completed on same day should all appear."""
        # Get multiple active todos (exclude habits - they don't keep CLOSED after reset)
        todos_response = api.get_all_todos()
        todos = todos_response.json()

        active_todos = [
            t for t in todos["todos"]
            if t.get("todo") == "TODO"
            and not t.get("isWindowHabit", False)
            and "habit" not in t.get("title", "").lower()
            and "Exercise" not in t.get("title", "")
            and "Meditate" not in t.get("title", "")
        ][:3]
        if len(active_todos) < 2:
            import pytest
            pytest.skip("Need at least 2 active non-habit TODOs for this test")

        # Complete them all
        completed_titles = []
        for todo in active_todos:
            response = api.complete_todo(todo)
            if response.status_code == 200:
                completed_titles.append(todo["title"])

        assert len(completed_titles) >= 2, "Need at least 2 successful completions"

        # Query with include_completed for TODAY's date (CLOSED uses real date)
        today = get_today_str()
        agenda_response = api.get(f"/agenda?date={today}&include_completed=true")
        entries = agenda_response.json().get("entries", [])

        # All completed items should appear
        found_count = 0
        for title in completed_titles:
            if any(title in e.get("title", "") for e in entries):
                found_count += 1

        assert found_count == len(completed_titles), (
            f"Expected {len(completed_titles)} completed items, found {found_count}"
        )

    def test_reopened_task_not_shown_as_completed(self, api):
        """Re-opened tasks (DONE -> TODO) should NOT appear as completed items."""
        # Get an active todo
        todos_response = api.get_all_todos()
        todos = todos_response.json()

        active_todo = next(
            (t for t in todos["todos"] if t.get("todo") == "TODO"),
            None,
        )
        assert active_todo is not None, "Need an active TODO to test"

        original_title = active_todo["title"]

        # Complete it
        complete_response = api.complete_todo(active_todo)
        assert complete_response.status_code == 200

        # Re-open it by setting state back to TODO
        reopen_response = api.complete_todo(active_todo, state="TODO")
        assert reopen_response.status_code == 200

        # Verify it's back to TODO state
        todos_response = api.get_all_todos()
        todos = todos_response.json()
        reopened_todo = next(
            (t for t in todos["todos"] if original_title in t.get("title", "")),
            None,
        )
        assert reopened_todo is not None, "Re-opened todo should still exist"
        assert reopened_todo.get("todo") == "TODO", "Todo should be back to TODO state"

        # Query with include_completed for TODAY's date
        today = get_today_str()
        agenda_response = api.get(f"/agenda?date={today}&include_completed=true")
        entries = agenda_response.json().get("entries", [])

        # The re-opened item should NOT appear as a completed entry
        # (It might appear if it has scheduled/deadline for today, but not due to completion)
        completed_entries = [
            e for e in entries
            if original_title in e.get("title", "") and e.get("todo") == "DONE"
        ]
        assert len(completed_entries) == 0, (
            f"Re-opened task should not appear as DONE. Found: {completed_entries}"
        )


class TestStateChangeLogBug:
    """Tests for bug where state change log entries appear incorrectly.

    Bug: When include_completed=true, entries with state change logs but no
    CLOSED timestamp (completedAt) are incorrectly included because the filter
    allows entries with null scheduled AND null deadline to pass through.

    The filter should only include entries when:
    - scheduled date matches the query date, OR
    - deadline date matches the query date, OR
    - completedAt date matches the query date

    Entries with null scheduled/deadline/completedAt should NOT appear.
    """

    def test_done_without_closed_not_shown_as_completed(self, api):
        """DONE items without CLOSED timestamp should NOT appear with include_completed.

        This tests the bug where items that are DONE but have no CLOSED timestamp
        (completedAt is null) appear in the agenda when include_completed=true
        because the filter allows entries with null scheduled AND null deadline
        to pass through.

        The test fixture state_change_bug.org contains:
        - A DONE item with LOGBOOK state change for TEST_DATE but no CLOSED timestamp
        - A DONE item without any logging

        The key scenario: an item has a state change log entry for the query date
        (so org-agenda shows it in log mode), but has no CLOSED timestamp.
        This can happen when:
        1. org-log-done is nil but state change logging is enabled
        2. The CLOSED timestamp was manually removed
        3. The item was marked DONE via external means
        """
        # Query with include_completed for the test date
        agenda_response = api.get(f"/agenda?date={TEST_DATE}&include_completed=true")
        assert agenda_response.status_code == 200

        entries = agenda_response.json().get("entries", [])

        # Debug: print all entries
        entry_info = [(e.get("title"), e.get("todo"), e.get("completedAt"), e.get("scheduled")) for e in entries]

        # The DONE items from state_change_bug.org should NOT appear because:
        # - They have no CLOSED timestamp (completedAt is null)
        # - They have no scheduled/deadline for the test date
        # They may appear in org-agenda due to LOGBOOK state change, but should be
        # filtered out because completedAt doesn't match the query date.
        bug_entries = [
            e for e in entries
            if "Task with state change log but no CLOSED" in e.get("title", "")
               or "Task done without any logging" in e.get("title", "")
        ]
        assert len(bug_entries) == 0, (
            f"DONE items without CLOSED timestamp should not appear with include_completed. "
            f"Found entries: {bug_entries}. All entries: {entry_info}"
        )

    def test_state_change_only_with_matching_closed_appears(self, api, org_dir):
        """State change log entries should only appear if completedAt matches query date.

        When org-agenda log mode shows state changes, entries should only pass
        the filter if they have:
        1. A scheduled date matching the query date, OR
        2. A deadline date matching the query date, OR
        3. A completedAt (CLOSED) date matching the query date

        Entries that appear solely due to state change logs (no CLOSED or
        CLOSED on different date) should be filtered out.
        """
        from pathlib import Path

        # Create an item, complete it (adds CLOSED), then query
        # First get an active todo
        todos_response = api.get_all_todos()
        todos = todos_response.json()

        active_todo = next(
            (t for t in todos["todos"]
             if t.get("todo") == "TODO"
             and not t.get("scheduled")  # No scheduled
             and not t.get("deadline")),  # No deadline
            None,
        )

        if active_todo is None:
            # Create one without scheduled/deadline
            capture_response = api.capture("todo", {"Title": "Temp task for state change test"})
            assert capture_response.status_code == 200

            # Re-fetch to get the new todo
            todos_response = api.get_all_todos()
            todos = todos_response.json()
            active_todo = next(
                (t for t in todos["todos"]
                 if "Temp task for state change test" in t.get("title", "")),
                None,
            )
            assert active_todo is not None, "Could not create test todo"

        original_title = active_todo["title"]

        # Complete it - this adds CLOSED timestamp for today
        complete_response = api.complete_todo(active_todo)
        assert complete_response.status_code == 200

        # Query for TODAY's date with include_completed=true
        today = get_today_str()
        agenda_response = api.get(f"/agenda?date={today}&include_completed=true")
        entries = agenda_response.json().get("entries", [])

        # Find the completed item
        completed_entry = next(
            (e for e in entries if original_title in e.get("title", "")),
            None,
        )

        # If found, it MUST have completedAt matching today (or scheduled/deadline for today)
        if completed_entry:
            completed_at = completed_entry.get("completedAt")
            scheduled = completed_entry.get("scheduled")
            deadline = completed_entry.get("deadline")

            # At least one of these should match today for the entry to be valid
            has_valid_date = (
                (completed_at and today in completed_at) or
                (extract_date(scheduled) == today) or
                (extract_date(deadline) == today)
            )
            assert has_valid_date, (
                f"Entry appeared without matching date. "
                f"completedAt={completed_at}, scheduled={scheduled}, deadline={deadline}, "
                f"query_date={today}"
            )

    def test_entries_without_any_date_not_shown(self, api):
        """Entries with null scheduled/deadline/completedAt should NOT appear.

        This is the core of the bug: the filter condition
        (and (null scheduled-date) (null deadline-date)) allows entries
        through even when they have no completedAt.

        With include_completed=true, ONLY entries with a matching date should appear:
        - scheduled matching query date
        - deadline matching query date
        - completedAt matching query date

        An entry with all three as null should NEVER appear.
        """
        # Query with include_completed
        query_date = TEST_DATE
        agenda_response = api.get(f"/agenda?date={query_date}&include_completed=true")
        entries = agenda_response.json().get("entries", [])

        # Check all entries - none should have all nulls
        for entry in entries:
            scheduled = entry.get("scheduled")
            deadline = entry.get("deadline")
            completed_at = entry.get("completedAt")

            # Extract just the date portion for comparison
            scheduled_date = extract_date(scheduled)
            deadline_date = extract_date(deadline)
            completed_at_date = completed_at[:10] if completed_at else None

            has_matching_date = (
                scheduled_date == query_date or
                deadline_date == query_date or
                completed_at_date == query_date
            )
            assert has_matching_date, (
                f"Entry has no date matching {query_date}: "
                f"title={entry.get('title')}, "
                f"scheduled={scheduled}, deadline={deadline}, completedAt={completed_at}"
            )


class TestIncludeCompletedParameter:
    """Tests for the include_completed query parameter parsing."""

    def test_accepts_true_string(self, api):
        """Should accept include_completed=true."""
        response = api.get(f"/agenda?date={TEST_DATE}&include_completed=true")
        assert response.status_code == 200

    def test_accepts_1_value(self, api):
        """Should accept include_completed=1."""
        response = api.get(f"/agenda?date={TEST_DATE}&include_completed=1")
        assert response.status_code == 200

    def test_false_is_default(self, api):
        """include_completed=false should behave like not passing it."""
        response_false = api.get(f"/agenda?date={TEST_DATE}&include_completed=false")
        response_none = api.get(f"/agenda?date={TEST_DATE}")

        assert response_false.status_code == 200
        assert response_none.status_code == 200

        # Both should return same structure (may have different content due to state changes)
        assert "entries" in response_false.json()
        assert "entries" in response_none.json()


# Note: Tests for habit include_completed are in development.
# The core functionality is implemented:
# - org-agenda-api--get-habits-completed-on-date scans for habits completed on a date
# - org-agenda-api--run-agenda adds these habits to filtered results when include_completed=true
# - Habits will have habitCompletedOnQueryDate=true when they were completed on the query date
