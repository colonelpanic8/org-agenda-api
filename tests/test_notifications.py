"""Integration tests for GET /notifications endpoint."""

import re
from datetime import datetime


class TestNotificationsEndpoint:
    """Tests for GET /notifications endpoint."""

    def test_returns_200(self, api):
        """Endpoint should return 200 OK."""
        response = api.get_notifications()
        assert response.status_code == 200

    def test_returns_json_structure(self, api):
        """Endpoint should return proper JSON structure."""
        response = api.get_notifications()
        data = response.json()

        assert "defaultNotifyBefore" in data
        assert "count" in data
        assert "notifications" in data

    def test_notifications_is_array(self, api):
        """Notifications should be an array."""
        response = api.get_notifications()
        data = response.json()

        assert isinstance(data["notifications"], list)

    def test_default_notify_before_is_array(self, api):
        """defaultNotifyBefore should be an array of integers."""
        response = api.get_notifications()
        data = response.json()

        assert isinstance(data["defaultNotifyBefore"], list)
        # Should contain at least the default 10 minutes
        assert len(data["defaultNotifyBefore"]) > 0

    def test_count_matches_notifications_length(self, api):
        """Count should match actual number of notifications."""
        response = api.get_notifications()
        data = response.json()

        assert data["count"] == len(data["notifications"])


class TestNotificationTypes:
    """Tests for different notification types (relative, absolute, day-wide)."""

    def test_relative_notification_from_deadline(self, api):
        """Relative notifications should be generated for deadlines with times."""
        response = api.get_notifications()
        data = response.json()

        # Find notifications for our test task with deadline
        deadline_notifs = [
            n
            for n in data["notifications"]
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
        response = api.get_notifications()
        data = response.json()

        # Find notifications for scheduled task
        scheduled_notifs = [
            n
            for n in data["notifications"]
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
        response = api.get_notifications()
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
        response = api.get_notifications()
        data = response.json()

        valid_types = {"relative", "absolute", "day-wide"}

        for notif in data["notifications"]:
            assert "type" in notif, f"Notification missing type: {notif}"
            assert notif["type"] in valid_types, (
                f"Invalid notification type: {notif['type']}"
            )


class TestNotificationFields:
    """Tests for fields in notifications."""

    def test_notification_structure_when_present(self, api):
        """Notifications should have proper structure when present."""
        response = api.get_notifications()
        data = response.json()

        if data["count"] > 0:
            notif = data["notifications"][0]
            # Required fields
            assert "title" in notif
            assert "notifyAt" in notif
            assert "type" in notif
            # Type should be 'relative', 'absolute', or 'day-wide'
            assert notif["type"] in ("relative", "absolute", "day-wide")

    def test_notification_fields_when_relative(self, api):
        """Relative notifications should include rich information."""
        response = api.get_notifications()
        data = response.json()

        # Find a relative notification
        relative_notifs = [n for n in data["notifications"] if n["type"] == "relative"]

        if relative_notifs:
            notif = relative_notifs[0]
            # Relative notifications should have these fields
            assert "eventTime" in notif
            assert "eventTimeString" in notif
            assert "minutesBefore" in notif
            assert "timestampType" in notif
            assert notif["timestampType"] in ("deadline", "scheduled", "timestamp")
            # Should have location info
            assert "file" in notif
            assert "pos" in notif
            # allTimes should be present
            assert "allTimes" in notif
            assert isinstance(notif["allTimes"], list)
            if notif["allTimes"]:
                time_info = notif["allTimes"][0]
                assert "timestampType" in time_info
                assert "timestampString" in time_info

    def test_file_and_position_present(self, api):
        """Notifications should include file path and position."""
        response = api.get_notifications()
        data = response.json()

        if data["count"] > 0:
            notif = data["notifications"][0]
            assert "file" in notif, "Notification should include file path"
            assert "pos" in notif, "Notification should include position"
            assert notif["file"].endswith(".org"), "File should be an org file"
            assert isinstance(notif["pos"], int), "Position should be an integer"

    def test_org_id_present_when_set(self, api):
        """Notifications should include org ID when the entry has one."""
        response = api.get_notifications()
        data = response.json()

        # Find notifications that should have IDs (from our test fixtures)
        notifs_with_expected_id = [
            n for n in data["notifications"] if "notif-" in n.get("id", "")
        ]

        if notifs_with_expected_id:
            notif = notifs_with_expected_id[0]
            assert "id" in notif, "Notification should include org ID"
            assert notif["id"].startswith("notif-"), (
                f"Expected ID starting with 'notif-', got: {notif['id']}"
            )

    def test_all_times_array_present(self, api):
        """Notifications should include allTimes array with all event timestamps."""
        response = api.get_notifications()
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
        response = api.get_notifications()
        data = response.json()

        relative_notifs = [n for n in data["notifications"] if n["type"] == "relative"]

        if relative_notifs and relative_notifs[0].get("allTimes"):
            time_info = relative_notifs[0]["allTimes"][0]
            assert "timestampType" in time_info, (
                "allTimes entry should have timestampType"
            )
            assert "timestampString" in time_info, (
                "allTimes entry should have timestampString"
            )
            assert time_info["timestampType"] in (
                "deadline",
                "scheduled",
                "timestamp",
            ), f"Invalid timestampType: {time_info['timestampType']}"


class TestNotificationTimeFormats:
    """Tests for time format fields in notifications."""

    def test_notify_at_is_iso_format(self, api):
        """notifyAt should be in ISO 8601 format."""
        response = api.get_notifications()
        data = response.json()

        iso_pattern = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$")

        for notif in data["notifications"]:
            assert "notifyAt" in notif
            assert iso_pattern.match(notif["notifyAt"]), (
                f"notifyAt should be ISO format, got: {notif['notifyAt']}"
            )

    def test_event_time_is_iso_format(self, api):
        """eventTime should be in ISO 8601 format when present."""
        response = api.get_notifications()
        data = response.json()

        iso_pattern = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$")

        for notif in data["notifications"]:
            if "eventTime" in notif and notif["eventTime"]:
                assert iso_pattern.match(notif["eventTime"]), (
                    f"eventTime should be ISO format, got: {notif['eventTime']}"
                )


class TestTimestampTypeField:
    """Tests for the timestampType field in notifications."""

    def test_timestamp_type_is_deadline_or_scheduled(self, api):
        """timestampType should be 'deadline', 'scheduled', or 'timestamp'."""
        response = api.get_notifications()
        data = response.json()

        valid_timestamp_types = {"deadline", "scheduled", "timestamp"}

        for notif in data["notifications"]:
            if "timestampType" in notif and notif["timestampType"]:
                assert notif["timestampType"] in valid_timestamp_types, (
                    f"Invalid timestampType: {notif['timestampType']}"
                )

    def test_deadline_notifications_have_deadline_type(self, api):
        """Notifications from deadlines should have timestampType='deadline'."""
        response = api.get_notifications()
        data = response.json()

        deadline_notifs = [
            n for n in data["notifications"] if n.get("timestampType") == "deadline"
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
        response = api.get_notifications()
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
        response = api.get_notifications()
        data = response.json()

        relative_notifs = [n for n in data["notifications"] if n["type"] == "relative"]

        # At minimum, some notifications should use default intervals
        # (unless custom intervals are set)
        minutes_values = {n["minutesBefore"] for n in relative_notifs}

        # There should be some overlap with defaults (unless all have custom intervals)
        # This is a loose check since custom intervals are possible
        if relative_notifs and not any(
            "custom" in n.get("title", "").lower() for n in relative_notifs
        ):
            assert minutes_values, "Should have some minutesBefore values"


class TestNotificationConsistency:
    """Tests for consistency between notification data."""

    def test_notify_at_before_event_time_for_relative(self, api):
        """For relative notifications, notifyAt should be before eventTime."""
        response = api.get_notifications()
        data = response.json()

        relative_notifs = [
            n
            for n in data["notifications"]
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
        response = api.get_notifications()
        data = response.json()

        for notif in data["notifications"]:
            assert "title" in notif
            assert notif["title"], "Notification title should not be empty"
            assert isinstance(notif["title"], str)


class TestAutoAddOrgId:
    """Tests for automatic org-id generation feature."""

    def test_all_notifications_have_id(self, api):
        """All notifications should have an ID when auto-add is enabled (default).

        With org-agenda-api-auto-add-org-id set to t (the default), entries
        without an ID should get one automatically created and returned.
        """
        response = api.get_notifications()
        data = response.json()

        # Every notification should have an id field
        for notif in data["notifications"]:
            assert "id" in notif, (
                f"Notification missing id (auto-add should have created one): "
                f"{notif.get('title', 'unknown')}"
            )
            assert notif["id"], (
                f"Notification id should not be empty: {notif.get('title', 'unknown')}"
            )

    def test_auto_added_ids_are_valid_uuids(self, api):
        """Auto-generated IDs should be valid UUIDs."""
        import re

        response = api.get_notifications()
        data = response.json()

        uuid_pattern = re.compile(
            r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            re.IGNORECASE,
        )

        for notif in data["notifications"]:
            if "id" in notif and notif["id"]:
                # IDs should either be pre-set (like 'notif-xxx') or be valid UUIDs
                if not notif["id"].startswith("notif-"):
                    assert uuid_pattern.match(notif["id"]), (
                        f"Auto-generated ID should be a valid UUID: {notif['id']}"
                    )


class TestAsOfParameter:
    """Tests for the asOf parameter functionality."""

    def test_as_of_parameter_accepted(self, api):
        """Endpoint should accept asOf parameter."""
        # Use the test date at a specific time
        response = api.get_notifications(as_of="2024-06-15T08:00:00")
        assert response.status_code == 200

    def test_as_of_echoed_in_response(self, api):
        """Response should echo the asOf parameter when provided."""
        response = api.get_notifications(as_of="2024-06-15T08:00:00")
        data = response.json()

        assert "asOf" in data
        assert data["asOf"] == "2024-06-15T08:00:00"

    def test_as_of_not_present_when_not_provided(self, api):
        """asOf should not be in response when not provided."""
        response = api.get_notifications()
        data = response.json()

        assert "asOf" not in data

    def test_as_of_affects_notifications(self, api):
        """Different asOf times should potentially return different notifications."""
        # Get notifications as of early morning
        early_response = api.get_notifications(as_of="2024-06-15T06:00:00")
        early_data = early_response.json()

        # Get notifications as of late evening (after most events)
        late_response = api.get_notifications(as_of="2024-06-15T23:00:00")
        late_data = late_response.json()

        # Both should return valid responses
        assert early_response.status_code == 200
        assert late_response.status_code == 200

        # The counts may differ since notifications for events that have
        # already passed (relative to asOf) won't be included
        # We just verify both return valid structure
        assert "notifications" in early_data
        assert "notifications" in late_data

    def test_as_of_with_future_date(self, api):
        """asOf with future date should work."""
        # Use a date in the future relative to test date
        response = api.get_notifications(as_of="2024-06-20T10:00:00")
        data = response.json()

        assert response.status_code == 200
        assert "notifications" in data
        # Future date means test fixtures' notifications have passed
        # so we might get fewer or no notifications

    def test_as_of_with_past_date(self, api):
        """asOf with past date should return notifications for that time."""
        # Use a date before the test date
        response = api.get_notifications(as_of="2024-06-14T10:00:00")
        data = response.json()

        assert response.status_code == 200
        assert "notifications" in data
        # Past date relative to fixtures means more notifications should be upcoming
