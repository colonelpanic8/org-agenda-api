"""Timezone robustness tests for include_completed behavior."""

from datetime import datetime
from zoneinfo import ZoneInfo

import pytest

from conftest import APIClient, EmacsServer, TEST_DATE, find_free_port

TEST_TIMEZONES = ["America/Los_Angeles", "UTC", "Asia/Tokyo"]


def _find_active_non_habit_todo(todos: list[dict]) -> dict | None:
    return next(
        (
            t
            for t in todos
            if t.get("todo") == "TODO"
            and not t.get("isWindowHabit", False)
            and "habit" not in t.get("title", "").lower()
            and "Exercise" not in t.get("title", "")
            and "Meditate" not in t.get("title", "")
        ),
        None,
    )


@pytest.fixture(params=TEST_TIMEZONES, ids=TEST_TIMEZONES)
def timezone_api(request, org_test_dir, inbox_file):
    """Run API server with a specific timezone for this test."""
    timezone = request.param

    # Reset fixtures before starting a dedicated timezone-scoped server.
    import subprocess

    subprocess.run(
        ["git", "reset", "--hard", "HEAD"],
        cwd=org_test_dir,
        capture_output=True,
        check=True,
    )
    subprocess.run(
        ["git", "clean", "-fd"],
        cwd=org_test_dir,
        capture_output=True,
        check=True,
    )

    server = EmacsServer(
        port=find_free_port(),
        org_dir=org_test_dir,
        inbox_file=inbox_file,
        fake_date=TEST_DATE,
        timezone=timezone,
    )
    server.start()

    client = APIClient(server.base_url)
    reload_response = client.reload(timeout=5.0)
    assert reload_response.status_code == 200

    yield timezone, client

    server.stop()


def test_include_completed_matches_server_timezone(timezone_api):
    """Completed entries should appear for the completion date in each timezone."""
    timezone, api = timezone_api

    todos_response = api.get_all_todos()
    assert todos_response.status_code == 200
    todos = todos_response.json().get("todos", [])

    active_todo = _find_active_non_habit_todo(todos)
    assert active_todo is not None, "Need an active non-habit TODO to test"

    complete_response = api.complete_todo(active_todo)
    assert complete_response.status_code == 200

    today = datetime.now(ZoneInfo(timezone)).date().strftime("%Y-%m-%d")
    agenda_response = api.get(f"/agenda?date={today}&include_completed=true")
    assert agenda_response.status_code == 200

    entries = agenda_response.json().get("entries", [])
    completed_entry = next(
        (e for e in entries if active_todo["title"] in e.get("title", "")),
        None,
    )
    assert completed_entry is not None, (
        f"Completed todo '{active_todo['title']}' not found in agenda for {today} "
        f"with timezone {timezone}"
    )
    assert completed_entry.get("todo") == "DONE"
