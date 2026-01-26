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

import re


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
        capture_response = api.post(
            "/capture",
            json={"template": "scheduled-today", "values": {"Title": unique_title}},
        )
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

        assert captured_todo is not None, (
            f"Could not find captured todo '{unique_title}'"
        )

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
        api.post(
            "/capture",
            json={"template": "scheduled-today", "values": {"Title": unique_title}},
        )

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
