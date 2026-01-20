"""Tests for capture template SCHEDULED: %t behavior.

These tests verify that when a template uses %t for scheduled date,
the resulting todo has a date-only scheduled field (no time component).

Bug: New todos captured via the API were showing up with times in their
scheduled field (e.g., "2026-01-19T16:43:00") even though the template
uses %t which should give date-only (e.g., "2026-01-19").

This causes issues because:
1. Items may not show up in agenda if the time is interpreted as past
2. The scheduled field doesn't match what the template specified
"""

import os
import re
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


class TestCaptureScheduledTimeLocal:
    """Tests for capture template SCHEDULED behavior locally.

    These tests verify that templates with SCHEDULED: %t produce
    date-only scheduled fields (no time component).
    """

    def test_capture_with_scheduled_t_template_gives_date_only(self, api, org_dir):
        """Template with SCHEDULED: %t should produce date-only scheduled.

        The scheduled-today template has:
            "* TODO %^{Title}\nSCHEDULED: %t\n"

        %t should expand to <YYYY-MM-DD Day> without time.
        The resulting scheduled field should be date-only (YYYY-MM-DD).
        """
        unique_title = "scheduled-t-local-test-12345"

        # Capture using scheduled-today template
        capture_response = api.post("/capture", json={
            "template": "scheduled-today",
            "values": {"Title": unique_title}
        })
        assert capture_response.status_code == 200
        capture_data = capture_response.json()
        assert capture_data.get("status") == "created"

        # Fetch the todo to check its scheduled field
        todos_response = api.get_all_todos()
        todos = todos_response.json()["todos"]

        captured_todo = None
        for todo in todos:
            if todo.get("title") == unique_title:
                captured_todo = todo
                break

        assert captured_todo is not None, f"Could not find captured todo '{unique_title}'"

        scheduled = captured_todo.get("scheduled")
        assert scheduled is not None, "Captured todo should have scheduled date from %t"

        # Check if it has time component
        has_time = "T" in scheduled or (len(scheduled) > 10 and ":" in scheduled[10:])

        assert not has_time, (
            f"BUG: Captured todo has time in scheduled field.\n"
            f"Template uses %t which should give date-only.\n"
            f"Expected: YYYY-MM-DD format (e.g., '2024-06-15')\n"
            f"Got: {scheduled}"
        )

    def test_file_content_has_date_only_timestamp(self, api, org_dir):
        """The org file should contain date-only timestamp from %t template."""
        unique_title = "file-content-check-67890"

        # Capture using scheduled-today template
        api.post("/capture", json={
            "template": "scheduled-today",
            "values": {"Title": unique_title}
        })

        # Check the actual file content
        inbox_path = org_dir / "inbox.org"
        content = inbox_path.read_text()

        # Find the entry for our todo
        assert unique_title in content, f"Todo not found in file. Content:\n{content}"

        # Extract the SCHEDULED line
        lines = content.split("\n")
        scheduled_line = None
        for i, line in enumerate(lines):
            if unique_title in line:
                # Look at the next line for SCHEDULED
                if i + 1 < len(lines) and "SCHEDULED:" in lines[i + 1]:
                    scheduled_line = lines[i + 1]
                    break

        assert scheduled_line is not None, (
            f"Could not find SCHEDULED line for todo. Content:\n{content}"
        )

        # Check if the timestamp has a time component
        # Date-only: SCHEDULED: <2024-06-15 Sat>
        # With time: SCHEDULED: <2024-06-15 Sat 10:00>
        has_time = re.search(r"<[^>]+ \d{1,2}:\d{2}>", scheduled_line) is not None

        assert not has_time, (
            f"BUG: File contains timestamp with time.\n"
            f"Template uses %t which should give date-only.\n"
            f"Got SCHEDULED line: {scheduled_line}"
        )


class TestCaptureScheduledTimeProduction:
    """Tests for capture template SCHEDULED behavior against production.

    To run these tests:
        MOVA_USERNAME=reddit MOVA_PASSWORD=tryitout PRODUCTION_URL=https://reddit-org-agenda-api.fly.dev pytest tests/test_capture_scheduled_time.py -v
    """

    def test_capture_without_scheduled_value_has_date_only(self, production_url, auth):
        """When no scheduled value is passed, template %t should give date-only.

        The production template is:
            "* TODO %^{Title}\nSCHEDULED: %t\n"

        %t should expand to <YYYY-MM-DD Day> without time.
        The resulting scheduled field should be date-only (YYYY-MM-DD).
        """
        import time
        unique_title = f"capture-date-only-test-{int(time.time())}"

        # Capture with only Title (no scheduled value)
        capture_response = requests.post(
            f"{production_url}/capture",
            json={"template": "default", "values": {"Title": unique_title}},
            auth=auth,
        )
        assert capture_response.status_code == 200
        capture_data = capture_response.json()
        assert capture_data.get("status") == "created"

        # Fetch the todo to check its scheduled field
        todos_response = requests.get(
            f"{production_url}/get-all-todos",
            auth=auth,
        )
        todos_data = todos_response.json()

        # Find the captured todo
        captured_todo = None
        for todo in todos_data["todos"]:
            if todo.get("title") == unique_title:
                captured_todo = todo
                break

        assert captured_todo is not None, f"Could not find captured todo '{unique_title}'"

        scheduled = captured_todo.get("scheduled")
        assert scheduled is not None, "Captured todo should have scheduled date from %t"

        # BUG: scheduled should be date-only (YYYY-MM-DD) but may have time
        # Check if it has time component
        has_time = "T" in scheduled or " " in scheduled.replace("-", "")

        assert not has_time, (
            f"BUG CONFIRMED: Captured todo has time in scheduled field.\n"
            f"Template uses %t which should give date-only.\n"
            f"Expected: YYYY-MM-DD format (e.g., '2026-01-19')\n"
            f"Got: {scheduled}\n"
            f"This causes items to potentially not show up in agenda."
        )

    def test_capture_with_scheduled_value_preserves_time(self, production_url, auth):
        """When scheduled value is passed with time, it should be preserved.

        This is the correct behavior - when explicitly passing a time,
        it should be preserved in the scheduled field.
        """
        import time
        unique_title = f"capture-with-time-test-{int(time.time())}"
        scheduled_with_time = "2026-01-19 14:30"

        # Capture with explicit scheduled time
        capture_response = requests.post(
            f"{production_url}/capture",
            json={
                "template": "default",
                "values": {"Title": unique_title, "scheduled": scheduled_with_time}
            },
            auth=auth,
        )
        assert capture_response.status_code == 200

        # Fetch the todo
        todos_response = requests.get(
            f"{production_url}/get-all-todos",
            auth=auth,
        )
        todos_data = todos_response.json()

        captured_todo = None
        for todo in todos_data["todos"]:
            if todo.get("title") == unique_title:
                captured_todo = todo
                break

        assert captured_todo is not None
        scheduled = captured_todo.get("scheduled")

        # Should have time component
        assert "T" in scheduled or "14:30" in scheduled, (
            f"When scheduled with time is passed, time should be preserved.\n"
            f"Expected time component in: {scheduled}"
        )

    def test_captured_todo_appears_in_todays_agenda(self, production_url, auth):
        """Newly captured todo should appear in today's agenda.

        This tests the core issue: todos created with SCHEDULED: %t
        should appear in the agenda for the current day.
        """
        import time
        unique_title = f"agenda-visibility-test-{int(time.time())}"

        # Get today's date from the server
        agenda_before = requests.get(
            f"{production_url}/agenda",
            params={"span": "day"},
            auth=auth,
        )
        server_today = agenda_before.json()["date"]

        # Capture a todo (should be scheduled for today via %t)
        capture_response = requests.post(
            f"{production_url}/capture",
            json={"template": "default", "values": {"Title": unique_title}},
            auth=auth,
        )
        assert capture_response.status_code == 200

        # Check if it appears in today's agenda
        agenda_after = requests.get(
            f"{production_url}/agenda",
            params={"span": "day", "date": server_today},
            auth=auth,
        )
        agenda_data = agenda_after.json()

        titles = [entry.get("title") for entry in agenda_data["entries"]]
        assert unique_title in titles, (
            f"BUG: Captured todo '{unique_title}' does not appear in today's agenda.\n"
            f"Server date: {server_today}\n"
            f"Titles in agenda: {titles}"
        )

    def test_captured_todo_with_past_time_appears_in_agenda(self, production_url, auth):
        """Todo scheduled for today with a past time should still appear in agenda.

        This test verifies that items scheduled for earlier today (e.g., 02:00)
        still show up in the agenda even if that time has passed.
        """
        import time
        unique_title = f"past-time-agenda-test-{int(time.time())}"

        # Get today's date from the server
        agenda_before = requests.get(
            f"{production_url}/agenda",
            params={"span": "day"},
            auth=auth,
        )
        server_today = agenda_before.json()["date"]

        # Capture a todo with a past time (02:00 is almost certainly past)
        capture_response = requests.post(
            f"{production_url}/capture",
            json={
                "template": "default",
                "values": {"Title": unique_title, "scheduled": f"{server_today} 02:00"}
            },
            auth=auth,
        )
        assert capture_response.status_code == 200

        # Check if it appears in today's agenda
        agenda_after = requests.get(
            f"{production_url}/agenda",
            params={"span": "day", "date": server_today},
            auth=auth,
        )
        agenda_data = agenda_after.json()

        titles = [entry.get("title") for entry in agenda_data["entries"]]
        assert unique_title in titles, (
            f"BUG: Todo with past time '{unique_title}' does not appear in today's agenda.\n"
            f"Server date: {server_today}\n"
            f"Scheduled time: 02:00 (past)\n"
            f"Titles in agenda: {titles}\n"
            f"Items scheduled for past times should still show in agenda."
        )

    def test_captured_todo_with_future_time_appears_in_agenda(self, production_url, auth):
        """Todo scheduled for today with a future time should appear in agenda.

        This test verifies that items scheduled for later today show up.
        """
        import time
        unique_title = f"future-time-agenda-test-{int(time.time())}"

        # Get today's date from the server
        agenda_before = requests.get(
            f"{production_url}/agenda",
            params={"span": "day"},
            auth=auth,
        )
        server_today = agenda_before.json()["date"]

        # Capture a todo with a future time (23:59 is almost certainly future)
        capture_response = requests.post(
            f"{production_url}/capture",
            json={
                "template": "default",
                "values": {"Title": unique_title, "scheduled": f"{server_today} 23:59"}
            },
            auth=auth,
        )
        assert capture_response.status_code == 200

        # Check if it appears in today's agenda
        agenda_after = requests.get(
            f"{production_url}/agenda",
            params={"span": "day", "date": server_today},
            auth=auth,
        )
        agenda_data = agenda_after.json()

        titles = [entry.get("title") for entry in agenda_data["entries"]]
        assert unique_title in titles, (
            f"Todo with future time '{unique_title}' does not appear in today's agenda.\n"
            f"Server date: {server_today}\n"
            f"Scheduled time: 23:59 (future)\n"
            f"Titles in agenda: {titles}"
        )
