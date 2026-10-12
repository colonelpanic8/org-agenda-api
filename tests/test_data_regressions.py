"""Regression tests for entry-local extraction and TODO metadata."""

from pathlib import Path

from conftest import TEST_DATE


def _todo(api, org_id):
    return next(t for t in api.get_all_todos().json()["todos"] if t["id"] == org_id)


def test_parent_does_not_inherit_child_logbook(api):
    parent = _todo(api, "review-data-parent")
    assert not parent.get("logbook")
    entries = api.get_agenda(date=TEST_DATE, include_completed=True).json()["entries"]
    assert "review-data-child" in {entry["id"] for entry in entries}
    assert "review-data-parent" not in {entry["id"] for entry in entries}


def test_body_timestamps_stop_at_child_heading(api):
    parent = _todo(api, "review-data-parent")
    child = _todo(api, "review-data-child")
    assert [ts["start"] for ts in parent["timestamps"]] == ["2024-06-18T09:00:00"]
    assert [ts["start"] for ts in child["timestamps"]] == ["2024-06-19T11:00:00"]


def test_closed_timestamp_preserves_time_without_logbook(api):
    entries = api.get_agenda(date=TEST_DATE, include_completed=True).json()["entries"]
    closed = next(entry for entry in entries if entry["id"] == "review-data-closed")
    assert closed["completedAt"] == "2024-06-15T14:45:00"


def test_implicit_done_keyword_matches_org(api):
    files = api.get("/todo-states-by-file").json()["files"]
    states = next(
        entry["todoStates"]
        for entry in files
        if Path(entry["file"]).name == "data_regressions.org"
    )
    assert states == {"active": ["TODO"], "done": ["DONE"]}
    assert _todo(api, "review-data-closed")["todo"] == "DONE"


def test_hourly_repeater_survives_timestamp_update(api, org_dir):
    todo = _todo(api, "review-data-hourly")
    repeater = todo["scheduled"]["repeater"]
    assert repeater == {"type": "+", "value": 1, "unit": "hour"}
    response = api.update_todo(
        todo,
        {"scheduled": {"date": "2024-06-16", "time": "09:00", "repeater": repeater}},
    )
    assert response.json()["status"] == "updated"
    assert "+1h>" in (org_dir / "data_regressions.org").read_text()
    assert _todo(api, "review-data-hourly")["scheduled"]["repeater"] == repeater
