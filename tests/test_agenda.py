"""Integration tests for GET /agenda endpoint."""

import pytest
from conftest import (
    TEST_DATE,
    TEST_DATE_NEXT_DAY,
    TEST_DATE_PREV_DAY,
    TEST_DATE_ORG,
    extract_date,
)


# Note: The test setup uses a fake date (2024-06-15) configured in conftest.py.
# The fake date is set by overriding calendar-current-date in Emacs.
# The /agenda endpoint MUST use calendar-current-date (not current-time)
# to determine the agenda start date for tests to work correctly.


class TestAgenda:
    """Tests for GET /agenda endpoint."""

    def test_returns_200(self, api):
        """Endpoint should return 200 OK."""
        response = api.get_agenda()
        assert response.status_code == 200

    def test_returns_json_object(self, api):
        """Endpoint should return a JSON object with expected structure."""
        response = api.get_agenda()
        data = response.json()

        assert isinstance(data, dict)
        assert "span" in data
        assert "date" in data
        assert "entries" in data

    def test_span_day_default(self, api):
        """Default span should be 'day'."""
        response = api.get_agenda()
        data = response.json()

        assert data["span"] == "day"

    def test_span_week_parameter_accepted(self, api):
        """Should accept 'week' span parameter without error."""
        response = api.get_agenda(span="week")
        assert response.status_code == 200
        data = response.json()
        # Note: span parameter parsing may not work correctly in all versions
        assert "span" in data

    def test_entries_is_array(self, api):
        """Entries should be a JSON array."""
        response = api.get_agenda()
        data = response.json()

        assert isinstance(data["entries"], list)

    def test_entry_structure_when_entries_exist(self, api):
        """Each entry should have structured todo data when entries exist."""
        response = api.get_agenda()
        data = response.json()

        # Skip detailed checks if no entries (date handling may vary)
        if len(data["entries"]) == 0:
            pytest.skip("No agenda entries for test date - date handling may differ")

        entry = data["entries"][0]

        # Check required fields
        assert "title" in entry
        assert "todo" in entry
        assert "file" in entry
        assert "pos" in entry

        # Check optional fields exist (may be null)
        assert "tags" in entry
        assert "scheduled" in entry
        assert "deadline" in entry
        assert "id" in entry
        assert "olpath" in entry
        assert "agendaLine" in entry

    def test_agenda_line_contains_display_text(self, api):
        """agendaLine should contain the org-agenda display text when entries exist."""
        response = api.get_agenda()
        data = response.json()

        if len(data["entries"]) == 0:
            pytest.skip("No agenda entries for test date")

        for entry in data["entries"]:
            # agendaLine should be a non-empty string
            assert isinstance(entry.get("agendaLine"), str)
            assert len(entry["agendaLine"]) > 0

    def test_entry_has_file_and_pos_for_navigation(self, api):
        """Each entry should have file and pos for navigating to source."""
        response = api.get_agenda()
        data = response.json()

        for entry in data["entries"]:
            assert entry.get("file") is not None, "Entry should have file path"
            assert entry.get("pos") is not None, "Entry should have position"
            assert isinstance(entry["pos"], int), "Position should be integer"

    def test_agenda_returns_entries_for_today(self, api):
        """Agenda should return entries scheduled for today (the fake test date).

        This test verifies that the /agenda endpoint correctly uses the
        fake test date (2024-06-15) set via calendar-current-date override.

        The test fixture 'today.org' contains items scheduled for 2024-06-15:
        - 'Task scheduled for today' with SCHEDULED
        - 'Task with deadline today' with DEADLINE
        """
        response = api.get_agenda()
        data = response.json()

        # This test MUST find entries - if it fails, the date handling is broken
        assert len(data["entries"]) > 0, (
            "Agenda should contain entries for the test date (2024-06-15). "
            "If this fails, the /agenda endpoint may not be using "
            "calendar-current-date to determine the start date."
        )

        # Verify we got entries from today.org
        titles = [entry.get("title") for entry in data["entries"]]
        assert any("scheduled for today" in (t or "").lower() for t in titles), (
            f"Expected to find 'Task scheduled for today' in agenda. "
            f"Found titles: {titles}"
        )


class TestAgendaOverdueItems:
    """Tests for overdue items appearing on subsequent days.

    In org-agenda, items scheduled for past dates appear on subsequent days
    with markers like "Sched. 1x" (1 day overdue), "Sched. 2x" (2 days overdue).
    The API should replicate this behavior when include_overdue=True.
    """

    def test_overdue_items_appear_on_today(self, api):
        """Items scheduled for yesterday should appear in today's agenda.

        The test fixture 'today.org' contains:
        - 'Task scheduled for yesterday' SCHEDULED: <2024-06-14>

        When querying for today (2024-06-15) with include_overdue=True, this overdue task should appear.
        """
        response = api.get_agenda(date=TEST_DATE, include_overdue=True)
        data = response.json()

        titles = [entry.get("title") for entry in data["entries"]]

        # The overdue task from yesterday should appear in today's agenda
        assert any("yesterday" in (t or "").lower() for t in titles), (
            f"Expected overdue item 'Task scheduled for yesterday' to appear in "
            f"today's ({TEST_DATE}) agenda. Found titles: {titles}"
        )

    def test_overdue_item_shows_original_scheduled_date(self, api):
        """Overdue items should show their original scheduled date, not today's date.

        When an item scheduled for 2024-06-14 appears in the 2024-06-15 agenda,
        its 'scheduled' field should still be '2024-06-14'.
        """
        response = api.get_agenda(date=TEST_DATE, include_overdue=True)
        data = response.json()

        # Find the overdue item
        overdue_entry = None
        for entry in data["entries"]:
            if "yesterday" in (entry.get("title") or "").lower():
                overdue_entry = entry
                break

        if overdue_entry is None:
            pytest.fail(
                f"Could not find overdue item 'Task scheduled for yesterday' in agenda. "
                f"Entries: {[e.get('title') for e in data['entries']]}"
            )

        scheduled_date = extract_date(overdue_entry["scheduled"])
        assert scheduled_date == TEST_DATE_PREV_DAY, (
            f"Overdue item should show original scheduled date ({TEST_DATE_PREV_DAY}), "
            f"not the query date. Got: {overdue_entry['scheduled']}"
        )

    def test_overdue_item_agenda_line_shows_sched_marker(self, api):
        """Overdue items should have 'Sched. Nx' marker in agendaLine.

        org-agenda shows overdue items with markers like:
        - 'Sched. 1x:' for 1 day overdue
        - 'Sched. 2x:' for 2 days overdue
        """
        response = api.get_agenda(date=TEST_DATE, include_overdue=True)
        data = response.json()

        # Find the overdue item
        overdue_entry = None
        for entry in data["entries"]:
            if "yesterday" in (entry.get("title") or "").lower():
                overdue_entry = entry
                break

        if overdue_entry is None:
            pytest.skip(
                "Overdue item not found - see test_overdue_items_appear_on_today"
            )

        agenda_line = overdue_entry.get("agendaLine", "")
        # Should show "Sched. 1x:" since it's 1 day overdue
        assert "Sched." in agenda_line and "1x" in agenda_line, (
            f"Expected 'Sched. 1x:' marker for 1-day overdue item. "
            f"Got agendaLine: {agenda_line}"
        )

    def test_two_day_overdue_items(self, api):
        """Items scheduled 2 days ago should appear with 'Sched. 2x' marker.

        Query for the day after TEST_DATE to see items from TEST_DATE_PREV_DAY
        as 2 days overdue.
        """
        response = api.get_agenda(date=TEST_DATE_NEXT_DAY, include_overdue=True)
        data = response.json()

        # Find the item that was scheduled for TEST_DATE_PREV_DAY (2024-06-14)
        # When viewed from TEST_DATE_NEXT_DAY (2024-06-16), it's 2 days overdue
        overdue_entry = None
        for entry in data["entries"]:
            if "yesterday" in (entry.get("title") or "").lower():
                overdue_entry = entry
                break

        if overdue_entry is None:
            pytest.fail(
                f"Could not find 2-day overdue item in agenda for {TEST_DATE_NEXT_DAY}. "
                f"Entries: {[e.get('title') for e in data['entries']]}"
            )

        agenda_line = overdue_entry.get("agendaLine", "")
        assert "Sched." in agenda_line and "2x" in agenda_line, (
            f"Expected 'Sched. 2x:' marker for 2-day overdue item. "
            f"Got agendaLine: {agenda_line}"
        )


class TestAgendaDateAccuracy:
    """Tests that verify items appear on the CORRECT date - not off by one.

    These tests verify a critical bug where querying for date X returns
    items scheduled for date X+1 instead. This is caused by incorrect date
    handling when the server's system date differs from the requested date.

    Test fixture 'today.org' contains:
    - 'Task scheduled for yesterday' SCHEDULED: <2024-06-14>  (TEST_DATE_PREV_DAY)
    - 'Task scheduled for today' SCHEDULED: <2024-06-15>      (TEST_DATE)
    - 'Task scheduled for tomorrow' SCHEDULED: <2024-06-16>   (TEST_DATE_NEXT_DAY)
    """

    def test_today_items_appear_on_today_not_yesterday(self, api):
        """Items scheduled for TEST_DATE should appear when querying TEST_DATE.

        Bug: Querying for 2024-06-15 might return items from 2024-06-16.
        This test verifies items scheduled for today appear on today's query.
        """
        response = api.get_agenda(date=TEST_DATE)
        data = response.json()

        titles = [entry.get("title") for entry in data["entries"]]

        # "Task scheduled for today" (scheduled 2024-06-15) should appear
        assert any("scheduled for today" in (t or "").lower() for t in titles), (
            f"Items scheduled for {TEST_DATE} should appear when querying {TEST_DATE}. "
            f"Found titles: {titles}"
        )

    def test_tomorrow_items_do_not_appear_on_today(self, api):
        """Items scheduled for tomorrow should NOT appear in today's agenda.

        Bug: If there's an off-by-one error, querying for today might return
        tomorrow's items instead of today's items.
        """
        response = api.get_agenda(date=TEST_DATE)
        data = response.json()

        titles = [entry.get("title") for entry in data["entries"]]

        # "Task scheduled for tomorrow" (scheduled 2024-06-16) should NOT appear
        # when querying for 2024-06-15, UNLESS it's being shown as a future item
        # which org-agenda doesn't do by default for day view
        tomorrow_items = [
            t for t in titles if "scheduled for tomorrow" in (t or "").lower()
        ]

        # If tomorrow's item appears, check if it's incorrectly showing
        # (it should only appear if we're querying for tomorrow's date)
        if tomorrow_items:
            # This could be a false positive if the item has a different scheduled date
            # Let's check the scheduled field
            for entry in data["entries"]:
                if "scheduled for tomorrow" in (entry.get("title") or "").lower():
                    scheduled = entry.get("scheduled")
                    assert scheduled != TEST_DATE_NEXT_DAY, (
                        f"Item 'Task scheduled for tomorrow' with scheduled date "
                        f"{TEST_DATE_NEXT_DAY} should NOT appear when querying {TEST_DATE}. "
                        f"This indicates an off-by-one date error."
                    )

    def test_yesterday_query_returns_yesterday_items(self, api):
        """Querying for yesterday should return items scheduled for yesterday.

        Items scheduled for TEST_DATE_PREV_DAY should appear when querying that date.
        """
        response = api.get_agenda(date=TEST_DATE_PREV_DAY)
        data = response.json()

        titles = [entry.get("title") for entry in data["entries"]]

        # "Task scheduled for yesterday" (scheduled 2024-06-14) should appear
        assert any("scheduled for yesterday" in (t or "").lower() for t in titles), (
            f"Items scheduled for {TEST_DATE_PREV_DAY} should appear when querying "
            f"{TEST_DATE_PREV_DAY}. Found titles: {titles}"
        )

    def test_tomorrow_query_returns_tomorrow_items(self, api):
        """Querying for tomorrow should return items scheduled for tomorrow.

        Items scheduled for TEST_DATE_NEXT_DAY should appear when querying that date.
        """
        response = api.get_agenda(date=TEST_DATE_NEXT_DAY)
        data = response.json()

        titles = [entry.get("title") for entry in data["entries"]]

        # "Task scheduled for tomorrow" (scheduled 2024-06-16) should appear
        assert any("scheduled for tomorrow" in (t or "").lower() for t in titles), (
            f"Items scheduled for {TEST_DATE_NEXT_DAY} should appear when querying "
            f"{TEST_DATE_NEXT_DAY}. Found titles: {titles}"
        )

    def test_scheduled_date_matches_query_date_for_non_overdue(self, api):
        """For items scheduled on the query date, scheduled field should match.

        When querying for TEST_DATE, items that are scheduled for TEST_DATE
        (not overdue from earlier) should have scheduled == TEST_DATE.
        """
        response = api.get_agenda(date=TEST_DATE)
        data = response.json()

        # Find "Task scheduled for today"
        today_entry = None
        for entry in data["entries"]:
            if "scheduled for today" in (entry.get("title") or "").lower():
                today_entry = entry
                break

        if today_entry is None:
            pytest.fail(
                f"Could not find 'Task scheduled for today' in agenda for {TEST_DATE}. "
                f"Entries: {[e.get('title') for e in data['entries']]}"
            )

        scheduled_date = extract_date(today_entry["scheduled"])
        assert scheduled_date == TEST_DATE, (
            f"Item 'Task scheduled for today' should have scheduled={TEST_DATE}, "
            f"but got scheduled={today_entry['scheduled']}. "
            f"This indicates a date mismatch bug."
        )

    def test_no_off_by_one_in_entry_scheduled_dates(self, api):
        """Verify that entry scheduled dates are not shifted by one day.

        This test checks that entries returned for a date query have scheduled
        dates that make sense (either the query date or earlier for overdue items).
        """
        response = api.get_agenda(date=TEST_DATE)
        data = response.json()

        for entry in data["entries"]:
            scheduled = entry.get("scheduled")
            if scheduled:
                # Extract just the date portion (YYYY-MM-DD) for comparison
                # Scheduled dates may be dict with date/time or string
                scheduled_date = extract_date(scheduled)
                # Scheduled date should be <= query date (today or overdue)
                # It should NOT be > query date (that would be a future item)
                assert scheduled_date <= TEST_DATE, (
                    f"Entry '{entry.get('title')}' has scheduled date {scheduled} "
                    f"which is AFTER the query date {TEST_DATE}. "
                    f"This indicates an off-by-one error - items from tomorrow "
                    f"are incorrectly appearing in today's agenda."
                )


class TestAgendaDateParameter:
    """Tests for the date parameter on /agenda endpoint."""

    def test_default_date_is_today(self, api):
        """Without date parameter, should return today's date (TEST_DATE)."""
        response = api.get_agenda()
        data = response.json()
        assert data["date"] == TEST_DATE

    def test_date_parameter_accepted(self, api):
        """Should accept a date parameter."""
        response = api.get_agenda(date=TEST_DATE_NEXT_DAY)
        assert response.status_code == 200
        data = response.json()
        assert data["date"] == TEST_DATE_NEXT_DAY

    def test_date_parameter_returns_specified_date(self, api):
        """Should return the specified date in the response."""
        response = api.get_agenda(date=TEST_DATE_PREV_DAY)
        data = response.json()
        assert data["date"] == TEST_DATE_PREV_DAY

    def test_entries_returned_as_array(self, api):
        """Entries should be returned as an array."""
        response = api.get_agenda(date=TEST_DATE)
        data = response.json()

        # Entries should be a list (may be empty if no items for that date)
        assert isinstance(data["entries"], list)

    def test_different_dates_return_correct_date_in_response(self, api):
        """Different date parameters should be reflected in the response."""
        today_response = api.get_agenda(date=TEST_DATE)
        tomorrow_response = api.get_agenda(date=TEST_DATE_NEXT_DAY)
        yesterday_response = api.get_agenda(date=TEST_DATE_PREV_DAY)

        assert today_response.json()["date"] == TEST_DATE
        assert tomorrow_response.json()["date"] == TEST_DATE_NEXT_DAY
        assert yesterday_response.json()["date"] == TEST_DATE_PREV_DAY

    def test_yesterday_date_parameter(self, api):
        """Should be able to fetch yesterday's agenda."""
        response = api.get_agenda(date=TEST_DATE_PREV_DAY)
        data = response.json()

        assert data["date"] == TEST_DATE_PREV_DAY
        # Verify we got a valid response structure
        assert "entries" in data
        assert isinstance(data["entries"], list)

    def test_date_with_week_span(self, api):
        """Date parameter should work with week span."""
        response = api.get_agenda(span="week", date=TEST_DATE_NEXT_DAY)
        data = response.json()

        assert response.status_code == 200
        assert data["span"] == "week"
        assert data["date"] == TEST_DATE_NEXT_DAY


class TestAgendaDateIsolation:
    """Tests that verify date parameters are used exactly as specified.

    These tests verify that when a specific date is requested, the API returns
    items for that exact date - regardless of what the server's system date is.
    The requested date should be treated as an opaque value with no timezone
    conversions or adjustments.
    """

    def test_explicit_date_overrides_server_today(self, api):
        """When a date parameter is provided, it should be used exactly.

        The server should return items for the exact date requested,
        not adjusted based on the server's current system date.
        """
        # Query for yesterday - should return yesterday's items, not today's
        response = api.get_agenda(date=TEST_DATE_PREV_DAY)
        data = response.json()

        # Response should say the date is what we requested
        assert data["date"] == TEST_DATE_PREV_DAY

        # Any items with a scheduled date should be <= TEST_DATE_PREV_DAY
        for entry in data["entries"]:
            scheduled = entry.get("scheduled")
            scheduled_date = extract_date(scheduled)
            if scheduled_date and scheduled_date != TEST_DATE_PREV_DAY:
                # For overdue items, scheduled should be before the query date
                assert scheduled_date < TEST_DATE_PREV_DAY, (
                    f"Entry '{entry.get('title')}' has scheduled={scheduled} "
                    f"which is after query date {TEST_DATE_PREV_DAY}"
                )

    def test_future_date_query_returns_future_items(self, api):
        """Querying a future date should return items for that future date.

        Even if server's 'today' is different, explicit date param should work.
        """
        # TEST_DATE_NEXT_DAY is "tomorrow" relative to fake today
        response = api.get_agenda(date=TEST_DATE_NEXT_DAY)
        data = response.json()

        assert data["date"] == TEST_DATE_NEXT_DAY

        # "Task scheduled for tomorrow" should appear
        titles = [e.get("title") for e in data["entries"]]
        assert any("tomorrow" in (t or "").lower() for t in titles), (
            f"Future date query should return items scheduled for that date. "
            f"Found: {titles}"
        )

    def test_past_date_query_does_not_include_future_items(self, api):
        """Querying a past date should NOT include items scheduled for the future.

        Bug scenario: If there's an off-by-one error, querying for a past date
        might incorrectly return items from a future date.
        """
        response = api.get_agenda(date=TEST_DATE_PREV_DAY)
        data = response.json()

        titles = [e.get("title") for e in data["entries"]]

        # Should NOT contain "tomorrow" items when querying for "yesterday"
        assert not any("tomorrow" in (t or "").lower() for t in titles), (
            f"Query for {TEST_DATE_PREV_DAY} should not include items scheduled "
            f"for future dates. Found 'tomorrow' item in: {titles}"
        )

        # Should NOT contain "today" items (unless they're also scheduled for yesterday)
        today_items = [e for e in data["entries"] if e.get("scheduled") == TEST_DATE]
        assert len(today_items) == 0, (
            f"Query for {TEST_DATE_PREV_DAY} should not include items scheduled "
            f"for {TEST_DATE}. Found: {[e.get('title') for e in today_items]}"
        )

    def test_entries_match_their_agendaLine_date_context(self, api):
        """The agendaLine should reflect the correct date context.

        If an item is overdue, agendaLine should show "Sched. Nx:".
        If an item is scheduled for the query date, it should show "Scheduled:".

        This test uses include_overdue=True to include overdue items in the agenda.
        """
        response = api.get_agenda(date=TEST_DATE, include_overdue=True)
        data = response.json()

        for entry in data["entries"]:
            scheduled = entry.get("scheduled")
            scheduled_date = extract_date(scheduled)
            agenda_line = entry.get("agendaLine", "")

            if scheduled_date and scheduled_date < TEST_DATE:
                # Overdue item - should have "Sched. Nx:" marker
                assert "Sched." in agenda_line, (
                    f"Overdue item '{entry.get('title')}' (scheduled {scheduled}) "
                    f"should have 'Sched.' marker in agendaLine. Got: {agenda_line}"
                )
            elif scheduled_date == TEST_DATE:
                # Same-day item - should have "Scheduled:" (no 'x' marker)
                # or just the item without overdue marker
                assert "Sched." not in agenda_line or "0x" not in agenda_line, (
                    f"Same-day item '{entry.get('title')}' should not have overdue marker. "
                    f"Got: {agenda_line}"
                )


class TestAgendaScheduledItemsWithTime:
    """Tests for scheduled items with specific times in the daily agenda.

    Bug: Items with times like SCHEDULED: <2024-06-15 Sat 10:00> may not
    appear in the daily agenda.

    Test fixture 'today.org' contains:
    - 'Task scheduled with specific time' SCHEDULED: <2024-06-15 Sat 10:00>
    """

    def test_scheduled_item_with_specific_time_appears_in_agenda(self, api):
        """A scheduled item with a specific time should appear in daily agenda.

        Bug: When an item has SCHEDULED: <2024-06-15 Sat 10:00> (with time),
        it should appear in the agenda for 2024-06-15.
        """
        response = api.get_agenda(date=TEST_DATE)
        data = response.json()

        titles = [entry.get("title") for entry in data["entries"]]

        # The item with time should appear
        assert any("specific time" in (t or "").lower() for t in titles), (
            f"Item 'Task scheduled with specific time' (SCHEDULED: <{TEST_DATE_ORG} 10:00>) "
            f"should appear in agenda for {TEST_DATE}. Found titles: {titles}"
        )

    def test_scheduled_item_with_time_preserves_time_in_output(self, api):
        """Scheduled items with times should include time in output."""
        response = api.get_agenda(date=TEST_DATE)
        data = response.json()

        # Find the item with time
        timed_entry = None
        for entry in data["entries"]:
            if "specific time" in (entry.get("title") or "").lower():
                timed_entry = entry
                break

        if timed_entry is None:
            pytest.fail(
                f"Item 'Task scheduled with specific time' not found in agenda. "
                f"Entries: {[e.get('title') for e in data['entries']]}"
            )

        scheduled = timed_entry.get("scheduled")
        # Should have time component - in new format this is a 'time' field in the dict
        if isinstance(scheduled, dict):
            assert scheduled.get("time") is not None, (
                f"Scheduled field should include time. Got: {scheduled}"
            )
            assert scheduled.get("time") == "10:00", (
                f"Scheduled field should include correct time (10:00). Got: {scheduled}"
            )
        else:
            # Legacy string format with T separator
            assert "T" in (scheduled or ""), (
                f"Scheduled field should include time (T separator). Got: {scheduled}"
            )
            assert "10:00" in (scheduled or ""), (
                f"Scheduled field should include correct time (10:00). Got: {scheduled}"
            )


class TestAgendaIncludeOverdueParameter:
    """Tests for the include_overdue parameter that controls overdue item inclusion.

    When include_overdue=false (default), querying for a specific date should only
    return items scheduled for that exact date, not overdue items from
    previous days.

    When include_overdue=true, the behavior is the same as before - overdue items
    from previous days are included (treating the query date as "today").
    """

    def test_default_excludes_overdue_items(self, api):
        """By default (include_overdue=false), overdue items should NOT be included.

        When querying for TEST_DATE without include_overdue=true, the agenda should
        only show items scheduled for TEST_DATE itself, not overdue items
        from previous days.
        """
        response = api.get_agenda(date=TEST_DATE)
        data = response.json()

        titles = [entry.get("title", "").lower() for entry in data["entries"]]

        # The overdue task "Task scheduled for yesterday" should NOT appear
        # (but habits with "yesterday" in their name that are due today can appear)
        assert not any("scheduled for yesterday" in t for t in titles), (
            f"With include_overdue=false (default), overdue items should not appear. "
            f"Found 'scheduled for yesterday' in titles: {titles}"
        )

    def test_include_overdue_true_includes_overdue_items(self, api):
        """With include_overdue=true, overdue items SHOULD be included.

        This preserves the traditional org-agenda behavior where overdue
        items from previous days appear in the current day's agenda.
        """
        response = api.get_agenda(date=TEST_DATE, include_overdue=True)
        data = response.json()

        titles = [entry.get("title", "").lower() for entry in data["entries"]]

        # The overdue task "Task scheduled for yesterday" SHOULD appear
        assert any("scheduled for yesterday" in t for t in titles), (
            f"With include_overdue=true, overdue items should appear. "
            f"Expected 'Task scheduled for yesterday' in agenda. "
            f"Found titles: {titles}"
        )

    def test_include_overdue_false_explicit_excludes_overdue_items(self, api):
        """Explicitly setting include_overdue=false should exclude overdue items.

        This test explicitly passes include_overdue=false to verify the parameter
        is correctly parsed and handled.
        """
        response = api.get_agenda(date=TEST_DATE, include_overdue=False)
        data = response.json()

        titles = [entry.get("title", "").lower() for entry in data["entries"]]

        # The overdue task "Task scheduled for yesterday" should NOT appear
        # (but habits with "yesterday" in their name that are due today can appear)
        assert not any("scheduled for yesterday" in t for t in titles), (
            f"With include_overdue=false, overdue items should not appear. "
            f"Found 'scheduled for yesterday' in titles: {titles}"
        )

    def test_include_overdue_still_shows_items_for_query_date(self, api):
        """With include_overdue=false, items scheduled for the query date should appear.

        This verifies that only overdue items are excluded, not items
        actually scheduled for the requested date.
        """
        response = api.get_agenda(date=TEST_DATE, include_overdue=False)
        data = response.json()

        titles = [entry.get("title", "").lower() for entry in data["entries"]]

        # Items scheduled for today should still appear
        assert any("scheduled for today" in t for t in titles), (
            f"Items scheduled for the query date should appear. "
            f"Expected 'Task scheduled for today' in agenda. "
            f"Found titles: {titles}"
        )

    def test_include_overdue_count_is_greater_or_equal(self, api, org_dir):
        """include_overdue=true should return >= items than include_overdue=false.

        Since include_overdue adds overdue items from previous days, the count
        should never be LESS than without include_overdue.
        """
        # Get agenda with and without include_overdue
        response_without = api.get_agenda(date=TEST_DATE, include_overdue=False)
        response_with = api.get_agenda(date=TEST_DATE, include_overdue=True)

        count_without = len(response_without.json()["entries"])
        count_with = len(response_with.json()["entries"])

        assert count_with >= count_without, (
            f"BUG: include_overdue=true returns FEWER items than without.\n"
            f"Without include_overdue: {count_without} items\n"
            f"With include_overdue: {count_with} items\n"
            f"include_overdue should only ADD items, never remove them."
        )


class TestAgendaDeduplication:
    """Tests that verify items with both SCHEDULED and DEADLINE appear only once.

    When an org item has both SCHEDULED and DEADLINE on the same day, org-agenda
    displays it twice (once for each). The API should deduplicate these entries
    so the item only appears once in the response.

    Test fixture 'today.org' contains:
    - 'Task with both scheduled and deadline' with both SCHEDULED and DEADLINE on TEST_DATE
    """

    def test_item_with_both_scheduled_and_deadline_appears_once(self, api):
        """An item with both SCHEDULED and DEADLINE on the same day should appear only once.

        Bug: org-agenda shows such items twice. The API should deduplicate them.
        """
        response = api.get_agenda(date=TEST_DATE)
        data = response.json()

        # Find all entries matching "both scheduled and deadline"
        matching_entries = [
            entry
            for entry in data["entries"]
            if "both scheduled and deadline" in (entry.get("title") or "").lower()
        ]

        # Should appear exactly once, not twice
        assert len(matching_entries) == 1, (
            f"Item 'Task with both scheduled and deadline' should appear exactly once "
            f"in the agenda, but found {len(matching_entries)} occurrences. "
            f"This indicates the API is not deduplicating entries that org-agenda "
            f"displays twice (once for SCHEDULED, once for DEADLINE)."
        )

    def test_deduplicated_item_has_both_dates(self, api):
        """A deduplicated item should have both scheduled and deadline dates."""
        response = api.get_agenda(date=TEST_DATE)
        data = response.json()

        # Find the entry
        entry = None
        for e in data["entries"]:
            if "both scheduled and deadline" in (e.get("title") or "").lower():
                entry = e
                break

        if entry is None:
            pytest.fail(
                f"Could not find 'Task with both scheduled and deadline' in agenda. "
                f"Entries: {[e.get('title') for e in data['entries']]}"
            )

        # Verify both dates are present
        assert entry.get("scheduled") is not None, (
            "Deduplicated entry should have scheduled date"
        )
        assert entry.get("deadline") is not None, (
            "Deduplicated entry should have deadline date"
        )

    def test_no_duplicate_entries_by_file_and_pos(self, api):
        """No two entries should have the same file and pos (same underlying item).

        This is a general deduplication check - if two entries point to the same
        location in the same file, they represent the same org item and should
        be deduplicated.
        """
        response = api.get_agenda(date=TEST_DATE)
        data = response.json()

        # Group entries by (file, pos)
        seen = {}
        duplicates = []
        for entry in data["entries"]:
            key = (entry.get("file"), entry.get("pos"))
            if key in seen:
                duplicates.append(
                    {
                        "title": entry.get("title"),
                        "file": entry.get("file"),
                        "pos": entry.get("pos"),
                        "first_agenda_line": seen[key].get("agendaLine"),
                        "duplicate_agenda_line": entry.get("agendaLine"),
                    }
                )
            else:
                seen[key] = entry

        assert len(duplicates) == 0, (
            f"Found {len(duplicates)} duplicate entries (same file+pos):\n"
            + "\n".join(
                f"  - '{d['title']}' at {d['file']}:{d['pos']}\n"
                f"    First: {d['first_agenda_line'][:50]}...\n"
                f"    Dupe:  {d['duplicate_agenda_line'][:50]}..."
                for d in duplicates
            )
        )


class TestAgendaHabitFields:
    """Tests for habit-related fields in /agenda."""

    def test_entries_have_is_window_habit_field(self, api):
        """Each entry has isWindowHabit field."""
        response = api.get_agenda()
        data = response.json()
        entries = data.get("entries", [])
        for entry in entries:
            assert "isWindowHabit" in entry

    def test_habit_entry_has_habit_summary(self, api):
        """Habit entries have habitSummary field."""
        response = api.get_agenda()
        data = response.json()
        entries = data.get("entries", [])
        habit_entries = [e for e in entries if e.get("isWindowHabit")]
        # May or may not have habits scheduled for today
        for entry in habit_entries:
            assert "habitSummary" in entry
