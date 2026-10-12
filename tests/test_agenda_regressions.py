"""Regression tests for occurrences, completion logs, and overdue placement."""

import shutil
import subprocess
from pathlib import Path

import pytest
from conftest import TEST_DATE


@pytest.fixture(scope="module")
def org_test_dir(org_test_dir):
    fixture = Path(__file__).parent / "fixtures" / "agenda_regressions" / "agenda.org"
    shutil.copy(fixture, org_test_dir / "agenda_regressions.org")
    subprocess.run(
        ["git", "add", "agenda_regressions.org"], cwd=org_test_dir, check=True
    )
    subprocess.run(
        ["git", "commit", "-m", "Add agenda regression fixture"],
        cwd=org_test_dir,
        check=True,
        capture_output=True,
    )
    return org_test_dir


@pytest.mark.parametrize(
    ("date", "occurs"),
    [
        ("2024-06-09", False),
        ("2024-06-10", True),
        (TEST_DATE, True),
        ("2024-06-20", True),
        ("2024-06-21", False),
    ],
)
def test_schedule_range_includes_each_day_without_overdue(api, date, occurs):
    entries = api.get_agenda(date=date, include_overdue=False).json()["entries"]
    assert ("regression-agenda-range" in {entry["id"] for entry in entries}) == occurs


@pytest.mark.parametrize(
    ("org_id", "date", "occurs"),
    [
        ("repeater-daily-plus", "2024-06-15", True),
        ("repeater-weekly-plus", "2024-06-15", False),
        ("repeater-weekly-plus", "2024-06-17", True),
        ("repeater-monthly-plus", "2024-07-10", True),
        ("repeater-yearly-plus", "2025-06-10", True),
        ("repeater-catchup", "2024-06-15", True),
        ("repeater-restart", "2024-06-15", True),
    ],
)
def test_repeater_occurrences_without_overdue(api, org_id, date, occurs):
    entries = api.get_agenda(date=date, include_overdue=False).json()["entries"]
    assert (org_id in {entry["id"] for entry in entries}) == occurs


@pytest.mark.parametrize("include_completed", [False, True])
def test_plain_appointments_remain_when_completion_logs_are_enabled(
    api, include_completed
):
    entries = api.get_agenda(
        date=TEST_DATE, include_completed=include_completed
    ).json()["entries"]
    ids = {entry["id"] for entry in entries}
    assert {"regression-agenda-plain", "regression-agenda-planned-appointment"} <= ids
    assert "regression-agenda-next-log" not in ids


@pytest.mark.parametrize("date", ["2024-06-14", TEST_DATE])
def test_completed_habits_survive_multi_day_projection_merge(api, date):
    org_id = "regression-agenda-completed-habit"
    day_entries = api.get_agenda(date=date, include_completed=True).json()["entries"]
    day_habit = next(entry for entry in day_entries if entry["id"] == org_id)
    assert day_habit["habitCompletedOnQueryDate"] is True

    days = api.get_agenda(
        start_date="2024-06-14",
        end_date="2024-06-21",
        today=TEST_DATE,
        include_completed=True,
    ).json()["days"]
    habits = [entry for entry in days[date] if entry["id"] == org_id]
    assert len(habits) == 1
    assert habits[0]["habitCompletedOnQueryDate"] is True
    assert habits[0]["completedAt"] == day_habit["completedAt"]
    assert habits[0]["scheduled"] == day_habit["scheduled"]
    assert any(entry["id"] == org_id for entry in days["2024-06-16"])


@pytest.mark.parametrize(
    ("behavior", "expected_dates"),
    [
        ("original", {"2024-06-14"}),
        ("today", {"2024-06-15"}),
        ("both", {"2024-06-14", "2024-06-15"}),
    ],
)
def test_overdue_behavior_places_task_only_on_requested_dates(
    api, behavior, expected_dates
):
    days = api.get_agenda(
        start_date="2024-06-14",
        end_date="2024-06-21",
        today=TEST_DATE,
        include_overdue=True,
        overdue_behavior=behavior,
    ).json()["days"]
    actual_dates = {
        date
        for date, entries in days.items()
        if any(entry["title"] == "Task scheduled for yesterday" for entry in entries)
    }
    assert actual_dates == expected_dates
    assert {
        date
        for date, entries in days.items()
        if any(entry["id"] == "regression-agenda-overdue-deadline" for entry in entries)
    } == expected_dates
    assert any(
        entry["title"] == "Task scheduled for tomorrow" for entry in days["2024-06-16"]
    )
    assert "repeater-daily-plus" in {entry["id"] for entry in days["2024-06-17"]}


@pytest.mark.parametrize("behavior", ["original", "today", "both"])
def test_overdue_behavior_preserves_timestamp_and_range_occurrences(api, behavior):
    days = api.get_agenda(
        start_date="2024-06-14",
        end_date="2024-06-21",
        today=TEST_DATE,
        include_overdue=True,
        overdue_behavior=behavior,
    ).json()["days"]
    assert "regression-agenda-plain" in {entry["id"] for entry in days[TEST_DATE]}
    assert "regression-agenda-overdue-appointment" in {
        entry["id"] for entry in days["2024-06-17"]
    }
    for date in ("2024-06-14", "2024-06-16", "2024-06-20"):
        assert "regression-agenda-range" in {entry["id"] for entry in days[date]}
