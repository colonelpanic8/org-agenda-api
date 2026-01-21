"""Tests for ranged timestamps and plain timestamp extraction."""

import pytest

from conftest import TEST_DATE, TEST_DATE_NEXT_DAY, TEST_DATE_PREV_DAY


class TestRangedScheduledTimestamps:
    """Tests for ranged SCHEDULED timestamps like <2024-06-15>--<2024-06-16>."""

    def test_ranged_schedule_has_scheduled_end(self, api):
        """Task with ranged schedule should have scheduledEnd field."""
        todos = api.get_all_todos().json()["todos"]
        task = next(
            (t for t in todos if "ranged schedule" in t.get("title", "").lower()),
            None
        )
        assert task is not None, "Test fixture 'Task with ranged schedule' not found"
        assert task.get("scheduled") is not None
        assert task.get("scheduledEnd") is not None

    def test_ranged_schedule_dates_are_correct(self, api):
        """Ranged schedule start and end dates should be correct."""
        todos = api.get_all_todos().json()["todos"]
        task = next(
            (t for t in todos if "ranged schedule" in t.get("title", "").lower()),
            None
        )
        assert task is not None
        assert task["scheduled"] == TEST_DATE
        assert task["scheduledEnd"] == TEST_DATE_NEXT_DAY

    def test_non_ranged_schedule_has_no_scheduled_end(self, api):
        """Task with regular schedule should not have scheduledEnd field or it should be null."""
        todos = api.get_all_todos().json()["todos"]
        task = next(
            (t for t in todos if "no special timestamps" in t.get("title", "").lower()),
            None
        )
        assert task is not None, "Test fixture not found"
        assert task.get("scheduled") is not None
        # scheduledEnd should either be absent or null for non-ranged timestamps
        assert task.get("scheduledEnd") is None


class TestRangedDeadlineTimestamps:
    """Tests for ranged DEADLINE timestamps."""

    def test_ranged_deadline_has_deadline_end(self, api):
        """Task with ranged deadline should have deadlineEnd field."""
        todos = api.get_all_todos().json()["todos"]
        task = next(
            (t for t in todos if "ranged deadline" in t.get("title", "").lower()),
            None
        )
        assert task is not None, "Test fixture 'Task with ranged deadline' not found"
        assert task.get("deadline") is not None
        assert task.get("deadlineEnd") is not None

    def test_ranged_deadline_with_time(self, api):
        """Ranged deadline with time components should preserve times."""
        todos = api.get_all_todos().json()["todos"]
        task = next(
            (t for t in todos if "ranged deadline" in t.get("title", "").lower()),
            None
        )
        assert task is not None
        # Should have time component (T in ISO format)
        assert "T" in task["deadline"]
        assert "T" in task["deadlineEnd"]
        assert "10:00:00" in task["deadline"]
        assert "14:00:00" in task["deadlineEnd"]


class TestPlainTimestamps:
    """Tests for plain active timestamps in entry body."""

    def test_plain_timestamps_extracted(self, api):
        """Task with plain timestamps in body should have timestamps array."""
        todos = api.get_all_todos().json()["todos"]
        task = next(
            (t for t in todos if "plain timestamp in body" in t.get("title", "").lower()),
            None
        )
        assert task is not None, "Test fixture not found"
        assert "timestamps" in task
        assert isinstance(task["timestamps"], list)
        assert len(task["timestamps"]) >= 2

    def test_plain_timestamp_structure(self, api):
        """Each plain timestamp should have required fields."""
        todos = api.get_all_todos().json()["todos"]
        task = next(
            (t for t in todos if "plain timestamp in body" in t.get("title", "").lower()),
            None
        )
        assert task is not None
        for ts in task["timestamps"]:
            assert "start" in ts
            assert "hasTime" in ts
            assert "type" in ts
            assert "raw" in ts

    def test_plain_timestamp_with_time(self, api):
        """Plain timestamp with time should have hasTime=true."""
        todos = api.get_all_todos().json()["todos"]
        task = next(
            (t for t in todos if "plain timestamp in body" in t.get("title", "").lower()),
            None
        )
        assert task is not None
        # Find the timestamp with 09:00
        ts_with_time = next(
            (ts for ts in task["timestamps"] if "09:00" in ts.get("raw", "")),
            None
        )
        assert ts_with_time is not None, "Timestamp with 09:00 not found"
        assert ts_with_time["hasTime"] is True
        assert "T" in ts_with_time["start"]

    def test_plain_timestamp_without_time(self, api):
        """Plain timestamp without time should have hasTime=false."""
        todos = api.get_all_todos().json()["todos"]
        task = next(
            (t for t in todos if "plain timestamp in body" in t.get("title", "").lower()),
            None
        )
        assert task is not None
        # Find a date-only timestamp
        ts_without_time = next(
            (ts for ts in task["timestamps"]
             if ts.get("hasTime") is False and "T" not in ts.get("start", "T")),
            None
        )
        assert ts_without_time is not None, "Date-only timestamp not found"

    def test_multiple_plain_timestamps(self, api):
        """Task with multiple plain timestamps should capture all."""
        todos = api.get_all_todos().json()["todos"]
        task = next(
            (t for t in todos if "multiple plain timestamps" in t.get("title", "").lower()),
            None
        )
        assert task is not None, "Test fixture not found"
        assert "timestamps" in task
        assert len(task["timestamps"]) >= 3

    def test_ranged_plain_timestamp(self, api):
        """Plain ranged timestamp should have end field."""
        todos = api.get_all_todos().json()["todos"]
        task = next(
            (t for t in todos if "ranged plain timestamp" in t.get("title", "").lower()),
            None
        )
        assert task is not None, "Test fixture not found"
        assert "timestamps" in task
        # Find the ranged timestamp
        ranged_ts = next(
            (ts for ts in task["timestamps"] if ts.get("end") is not None),
            None
        )
        assert ranged_ts is not None, "Ranged timestamp not found"
        assert ranged_ts["type"] == "active-range"
        assert ranged_ts["start"] == TEST_DATE
        assert ranged_ts["end"] == TEST_DATE_NEXT_DAY

    def test_no_timestamps_field_when_none(self, api):
        """Task without plain timestamps should not have timestamps field or it should be null/empty."""
        todos = api.get_all_todos().json()["todos"]
        task = next(
            (t for t in todos if "no special timestamps" in t.get("title", "").lower()),
            None
        )
        assert task is not None, "Test fixture not found"
        # timestamps should either be absent, null, or empty for tasks without plain timestamps
        timestamps = task.get("timestamps")
        assert timestamps is None or timestamps == []


class TestTimestampsInAgenda:
    """Tests for timestamp fields in agenda endpoint."""

    def test_agenda_includes_ranged_schedule(self, api):
        """Agenda endpoint should include scheduledEnd for ranged timestamps."""
        response = api.get_agenda("day", TEST_DATE)
        entries = response.json()["entries"]

        task = next(
            (e for e in entries if "ranged schedule" in e.get("title", "").lower()),
            None
        )
        # Task may or may not appear in agenda depending on how org handles ranges
        if task:
            assert task.get("scheduledEnd") is not None

    def test_agenda_includes_timestamps_array(self, api):
        """Agenda endpoint should include timestamps array when present."""
        response = api.get_agenda("day", TEST_DATE)
        entries = response.json()["entries"]

        task = next(
            (e for e in entries if "plain timestamp in body" in e.get("title", "").lower()),
            None
        )
        if task:
            assert "timestamps" in task
            assert isinstance(task["timestamps"], list)
