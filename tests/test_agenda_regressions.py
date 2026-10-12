"""Regression tests for occurrences, completion logs, and overdue placement."""

import pytest
from conftest import TEST_DATE


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


def test_deadline_warning_is_not_treated_as_overdue(api):
    entries = api.get_agenda(date=TEST_DATE, include_overdue=False).json()["entries"]
    assert "regression-agenda-warning" in {entry["id"] for entry in entries}


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
