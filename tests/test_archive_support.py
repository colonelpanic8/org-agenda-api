"""Integration tests for archive file support."""

from conftest import TEST_DATE


def test_agenda_includes_archives_when_requested(api):
    """Archived scheduled items should appear when include_archives=true."""
    response = api.get(f"/agenda?date={TEST_DATE}&include_archives=true")
    assert response.status_code == 200

    entries = response.json().get("entries", [])
    titles = [e.get("title", "") for e in entries]

    assert any("Archived scheduled task" in t for t in titles), (
        f"Expected archived scheduled task in agenda, got: {titles}"
    )


def test_agenda_excludes_archives_by_default(api):
    """Archived scheduled items should not appear by default."""
    response = api.get(f"/agenda?date={TEST_DATE}")
    assert response.status_code == 200

    entries = response.json().get("entries", [])
    titles = [e.get("title", "") for e in entries]

    assert all("Archived scheduled task" not in t for t in titles), (
        f"Did not expect archived scheduled task in agenda by default: {titles}"
    )
