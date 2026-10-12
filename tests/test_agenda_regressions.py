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
