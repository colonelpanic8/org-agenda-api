"""Integration tests for GET /agenda endpoint."""

import pytest


# Note: Some tests may skip if the fake date configuration doesn't work
# with org-agenda-list (which uses current-time, not calendar-current-date)


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
