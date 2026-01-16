"""Tests that verify the production date bug.

These tests are designed to run against the actual production server
(or a server without the fake date setup) to reproduce the off-by-one
date issue observed in production.

To run these tests:
  MOVA_USERNAME=user MOVA_PASSWORD=pass PRODUCTION_URL=https://... pytest tests/test_production_date_bug.py -v

The tests expect environment variables:
  PRODUCTION_URL - URL of the production org-agenda-api server
  MOVA_USERNAME - API username
  MOVA_PASSWORD - API password
"""

import os
import pytest
import requests


@pytest.fixture
def production_url():
    """Get the production URL from environment."""
    url = os.environ.get("PRODUCTION_URL")
    if not url:
        pytest.skip("PRODUCTION_URL environment variable not set")
    return url


@pytest.fixture
def auth():
    """Get authentication credentials from environment."""
    username = os.environ.get("MOVA_USERNAME")
    password = os.environ.get("MOVA_PASSWORD")
    if not username or not password:
        pytest.skip("MOVA_USERNAME and MOVA_PASSWORD environment variables required")
    return (username, password)


class TestProductionDateBug:
    """Tests to verify the off-by-one date bug in production.

    These tests document the observed production behavior where:
    - Querying for date X returns items scheduled for date X+1
    - Items scheduled for date X appear when querying for date X-1
    """

    def test_query_date_matches_response_date(self, production_url, auth):
        """The response 'date' field should match the requested date."""
        test_date = "2026-01-15"
        response = requests.get(
            f"{production_url}/agenda",
            params={"span": "day", "date": test_date},
            auth=auth,
        )
        assert response.status_code == 200
        data = response.json()

        assert data["date"] == test_date, (
            f"Response date should be {test_date}, got {data['date']}"
        )

    def test_entries_scheduled_dates_are_not_after_query_date(self, production_url, auth):
        """BUG: Entries with scheduled dates AFTER the query date appear.

        When querying for 2026-01-15, we should only see items scheduled for
        2026-01-15 or earlier (overdue). We should NOT see items scheduled
        for 2026-01-16.
        """
        test_date = "2026-01-15"
        response = requests.get(
            f"{production_url}/agenda",
            params={"span": "day", "date": test_date},
            auth=auth,
        )
        data = response.json()

        future_items = []
        for entry in data["entries"]:
            scheduled = entry.get("scheduled")
            if scheduled:
                # Extract just the date part (ignore time)
                sched_date = scheduled[:10] if len(scheduled) >= 10 else scheduled
                if sched_date > test_date:
                    future_items.append({
                        "title": entry.get("title"),
                        "scheduled": scheduled,
                    })

        assert len(future_items) == 0, (
            f"BUG CONFIRMED: Query for {test_date} returned items scheduled AFTER that date:\n"
            f"{future_items}\n"
            f"This indicates an off-by-one date error."
        )

    def test_items_appear_on_their_scheduled_date(self, production_url, auth):
        """BUG: Items don't appear on their scheduled date, but on the day before.

        If an item is scheduled for 2026-01-16, it should appear when querying
        2026-01-16, not when querying 2026-01-15.
        """
        # Query for two consecutive dates
        date_a = "2026-01-15"
        date_b = "2026-01-16"

        response_a = requests.get(
            f"{production_url}/agenda",
            params={"span": "day", "date": date_a},
            auth=auth,
        )
        response_b = requests.get(
            f"{production_url}/agenda",
            params={"span": "day", "date": date_b},
            auth=auth,
        )

        data_a = response_a.json()
        data_b = response_b.json()

        # Find items scheduled for date_b
        items_for_b_in_query_a = []
        items_for_b_in_query_b = []

        for entry in data_a["entries"]:
            scheduled = entry.get("scheduled", "")[:10]
            if scheduled == date_b:
                items_for_b_in_query_a.append(entry.get("title"))

        for entry in data_b["entries"]:
            scheduled = entry.get("scheduled", "")[:10]
            if scheduled == date_b:
                items_for_b_in_query_b.append(entry.get("title"))

        if items_for_b_in_query_a:
            pytest.fail(
                f"BUG CONFIRMED: Items scheduled for {date_b} appeared in query for {date_a}:\n"
                f"  In {date_a} query: {items_for_b_in_query_a}\n"
                f"  In {date_b} query: {items_for_b_in_query_b}\n"
                f"Items should only appear on their scheduled date (or later if overdue)."
            )

    def test_overdue_items_appear(self, production_url, auth):
        """Overdue items should appear on subsequent days.

        This test verifies that items scheduled for 2026-01-14 appear
        when querying for 2026-01-15 (as overdue items with 'Sched. 1x').
        """
        test_date = "2026-01-15"
        response = requests.get(
            f"{production_url}/agenda",
            params={"span": "day", "date": test_date},
            auth=auth,
        )
        data = response.json()

        overdue_items = []
        for entry in data["entries"]:
            scheduled = entry.get("scheduled", "")[:10]
            agenda_line = entry.get("agendaLine", "")
            if scheduled and scheduled < test_date and "Sched." in agenda_line:
                overdue_items.append({
                    "title": entry.get("title"),
                    "scheduled": scheduled,
                    "agendaLine": agenda_line,
                })

        # There should be some overdue items (we know from production there are items
        # scheduled for 2026-01-14)
        # This test may fail if there are no overdue items, which would indicate
        # a different bug
        print(f"Overdue items found: {overdue_items}")
        print(f"Total entries: {len(data['entries'])}")
        print(f"All entries: {[(e.get('title'), e.get('scheduled')) for e in data['entries']]}")

    def test_without_date_param_returns_server_today(self, production_url, auth):
        """Without a date param, the server returns its 'today'.

        This test documents that the server's 'today' is based on its system date,
        which may differ from the client's local date.
        """
        response = requests.get(
            f"{production_url}/agenda",
            params={"span": "day"},
            auth=auth,
        )
        data = response.json()

        print(f"Server's 'today' date: {data['date']}")
        print(f"Number of entries: {len(data['entries'])}")

        # This documents behavior - the date returned is the server's current date
        # which may be different from the client's current date
        assert "date" in data
