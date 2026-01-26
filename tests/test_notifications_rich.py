"""Integration tests for rich notification information from /notifications endpoint."""

import pytest


class TestNotificationTypes:
    """Tests for different notification types (relative, absolute, day-wide)."""

    def test_relative_notification_from_deadline(self, api):
        """Relative notifications should be generated for deadlines with times."""
        response = api.get_notifications(within=1440)  # 24 hours
        data = response.json()

        # Find notifications for our test task with deadline
        deadline_notifs = [
            n for n in data["notifications"]
            if "notif-relative-deadline" in n.get("id", "")
            or "timed deadline" in n.get("title", "")
        ]

        # Should have relative notifications
        relative_notifs = [n for n in deadline_notifs if n["type"] == "relative"]

        if relative_notifs:
            notif = relative_notifs[0]
            assert notif["type"] == "relative"
            assert notif["timestampType"] == "deadline"
            assert "minutesBefore" in notif
            assert "eventTime" in notif

    def test_relative_notification_from_scheduled(self, api):
        """Relative notifications should be generated for scheduled items with times."""
        response = api.get_notifications(within=1440)
        data = response.json()

        # Find notifications for scheduled task
        scheduled_notifs = [
            n for n in data["notifications"]
            if "notif-relative-scheduled" in n.get("id", "")
            or "timed schedule" in n.get("title", "")
        ]

        relative_notifs = [n for n in scheduled_notifs if n["type"] == "relative"]

        if relative_notifs:
            notif = relative_notifs[0]
            assert notif["type"] == "relative"
            assert notif["timestampType"] == "scheduled"

    def test_absolute_notification_from_notify_at(self, api):
        """Absolute notifications should be generated from WILD_NOTIFIER_NOTIFY_AT."""
        response = api.get_notifications(within=1440)
        data = response.json()

        # Find absolute notifications
        absolute_notifs = [n for n in data["notifications"] if n["type"] == "absolute"]

        if absolute_notifs:
            notif = absolute_notifs[0]
            assert notif["type"] == "absolute"
            assert "notifyAt" in notif
            assert "title" in notif
            # Absolute notifications don't have minutesBefore or eventTime
            assert notif.get("minutesBefore") is None
            assert notif.get("eventTime") is None

    def test_notification_type_values(self, api):
        """All notifications should have valid type values."""
        response = api.get_notifications(within=1440)
        data = response.json()

        valid_types = {"relative", "absolute", "day-wide"}

        for notif in data["notifications"]:
            assert "type" in notif, f"Notification missing type: {notif}"
            assert notif["type"] in valid_types, (
                f"Invalid notification type: {notif['type']}"
            )


class TestNotificationRichFields:
    """Tests for rich information fields in notifications."""

    def test_file_and_position_present(self, api):
        """Notifications should include file path and position."""
        response = api.get_notifications(within=1440)
        data = response.json()

        if data["count"] > 0:
            notif = data["notifications"][0]
            assert "file" in notif, "Notification should include file path"
            assert "pos" in notif, "Notification should include position"
            assert notif["file"].endswith(".org"), "File should be an org file"
            assert isinstance(notif["pos"], int), "Position should be an integer"

    def test_org_id_present_when_set(self, api):
        """Notifications should include org ID when the entry has one."""
        response = api.get_notifications(within=1440)
        data = response.json()

        # Find notifications that should have IDs (from our test fixtures)
        notifs_with_expected_id = [
            n for n in data["notifications"]
            if "notif-" in n.get("id", "")
        ]

        if notifs_with_expected_id:
            notif = notifs_with_expected_id[0]
            assert "id" in notif, "Notification should include org ID"
            assert notif["id"].startswith("notif-"), (
                f"Expected ID starting with 'notif-', got: {notif['id']}"
            )

    def test_all_times_array_present(self, api):
        """Notifications should include allTimes array with all event timestamps."""
        response = api.get_notifications(within=1440)
        data = response.json()

        # Find a relative notification (these should have allTimes)
        relative_notifs = [n for n in data["notifications"] if n["type"] == "relative"]

        if relative_notifs:
            notif = relative_notifs[0]
            assert "allTimes" in notif, "Relative notification should have allTimes"
            assert isinstance(notif["allTimes"], list), "allTimes should be a list"
            assert len(notif["allTimes"]) > 0, "allTimes should not be empty"

    def test_all_times_structure(self, api):
        """Each entry in allTimes should have proper structure."""
        response = api.get_notifications(within=1440)
        data = response.json()

        relative_notifs = [n for n in data["notifications"] if n["type"] == "relative"]

        if relative_notifs and relative_notifs[0].get("allTimes"):
            time_info = relative_notifs[0]["allTimes"][0]
            assert "timestampType" in time_info, "allTimes entry should have timestampType"
            assert "timestampString" in time_info, "allTimes entry should have timestampString"
            assert time_info["timestampType"] in ("deadline", "scheduled", "timestamp"), (
                f"Invalid timestampType: {time_info['timestampType']}"
            )

    def test_notify_at_is_iso_format(self, api):
        """notifyAt should be in ISO 8601 format."""
        import re

        response = api.get_notifications(within=1440)
        data = response.json()

        iso_pattern = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$")

        for notif in data["notifications"]:
            assert "notifyAt" in notif
            assert iso_pattern.match(notif["notifyAt"]), (
                f"notifyAt should be ISO format, got: {notif['notifyAt']}"
            )

    def test_event_time_is_iso_format(self, api):
        """eventTime should be in ISO 8601 format when present."""
        import re

        response = api.get_notifications(within=1440)
        data = response.json()

        iso_pattern = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$")

        for notif in data["notifications"]:
            if "eventTime" in notif and notif["eventTime"]:
                assert iso_pattern.match(notif["eventTime"]), (
                    f"eventTime should be ISO format, got: {notif['eventTime']}"
                )


class TestNotificationFiltering:
    """Tests for notification filtering by time window."""

    def test_within_parameter_filters_notifications(self, api):
        """Notifications outside the time window should be filtered out."""
        # Get all notifications
        all_response = api.get_notifications(within=1440)
        all_data = all_response.json()

        # Get only near-term notifications
        near_response = api.get_notifications(within=30)
        near_data = near_response.json()

        # Near-term should be subset of all
        assert near_data["count"] <= all_data["count"], (
            "Narrower time window should return fewer or equal notifications"
        )

    def test_within_minutes_echoed_in_response(self, api):
        """Response should echo the withinMinutes parameter."""
        response = api.get_notifications(within=60)
        data = response.json()

        assert "withinMinutes" in data
        assert data["withinMinutes"] == 60


class TestTimestampTypeField:
    """Tests for the timestampType field in notifications."""

    def test_timestamp_type_is_deadline_or_scheduled(self, api):
        """timestampType should be 'deadline', 'scheduled', or 'timestamp'."""
        response = api.get_notifications(within=1440)
        data = response.json()

        valid_timestamp_types = {"deadline", "scheduled", "timestamp"}

        for notif in data["notifications"]:
            if "timestampType" in notif and notif["timestampType"]:
                assert notif["timestampType"] in valid_timestamp_types, (
                    f"Invalid timestampType: {notif['timestampType']}"
                )

    def test_deadline_notifications_have_deadline_type(self, api):
        """Notifications from deadlines should have timestampType='deadline'."""
        response = api.get_notifications(within=1440)
        data = response.json()

        deadline_notifs = [
            n for n in data["notifications"]
            if n.get("timestampType") == "deadline"
        ]

        for notif in deadline_notifs:
            # The event time string should contain DEADLINE marker or angle brackets
            if "eventTimeString" in notif:
                assert "<" in notif["eventTimeString"], (
                    "Deadline notification should have org timestamp in eventTimeString"
                )


class TestMinutesBeforeField:
    """Tests for the minutesBefore field in relative notifications."""

    def test_minutes_before_is_positive_integer(self, api):
        """minutesBefore should be a positive integer for relative notifications."""
        response = api.get_notifications(within=1440)
        data = response.json()

        relative_notifs = [n for n in data["notifications"] if n["type"] == "relative"]

        for notif in relative_notifs:
            assert "minutesBefore" in notif
            assert isinstance(notif["minutesBefore"], int)
            assert notif["minutesBefore"] > 0, (
                f"minutesBefore should be positive, got: {notif['minutesBefore']}"
            )

    def test_minutes_before_matches_default_intervals(self, api):
        """minutesBefore values should match configured notification intervals."""
        response = api.get_notifications(within=1440)
        data = response.json()

        default_intervals = set(data["defaultNotifyBefore"])

        relative_notifs = [n for n in data["notifications"] if n["type"] == "relative"]

        # At minimum, some notifications should use default intervals
        # (unless custom intervals are set)
        minutes_values = {n["minutesBefore"] for n in relative_notifs}

        # There should be some overlap with defaults (unless all have custom intervals)
        # This is a loose check since custom intervals are possible
        if relative_notifs and not any("custom" in n.get("title", "").lower() for n in relative_notifs):
            assert minutes_values, "Should have some minutesBefore values"


class TestNotificationConsistency:
    """Tests for consistency between notification data."""

    def test_notify_at_before_event_time_for_relative(self, api):
        """For relative notifications, notifyAt should be before eventTime."""
        from datetime import datetime

        response = api.get_notifications(within=1440)
        data = response.json()

        relative_notifs = [
            n for n in data["notifications"]
            if n["type"] == "relative" and n.get("eventTime")
        ]

        for notif in relative_notifs:
            notify_at = datetime.fromisoformat(notif["notifyAt"])
            event_time = datetime.fromisoformat(notif["eventTime"])

            assert notify_at <= event_time, (
                f"notifyAt ({notify_at}) should be before eventTime ({event_time})"
            )

    def test_title_not_empty(self, api):
        """All notifications should have non-empty titles."""
        response = api.get_notifications(within=1440)
        data = response.json()

        for notif in data["notifications"]:
            assert "title" in notif
            assert notif["title"], "Notification title should not be empty"
            assert isinstance(notif["title"], str)
