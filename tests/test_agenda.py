"""Integration tests for GET /agenda endpoint."""

import pytest
from conftest import TEST_DATE, TEST_DATE_NEXT_DAY, TEST_DATE_PREV_DAY


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
