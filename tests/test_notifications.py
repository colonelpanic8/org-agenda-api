"""Integration tests for GET /notifications endpoint."""


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

    def test_no_within_param_returns_all_future(self, api):
        """Without within param, should return all future notifications."""
        response = api.get_notifications()
        data = response.json()

        # withinMinutes should not be present when not specified
        assert "withinMinutes" not in data

    def test_custom_within_parameter(self, api):
        """Should accept custom within parameter."""
        response = api.get_notifications(within=120)
        data = response.json()

        assert data["withinMinutes"] == 120

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

    def test_notification_structure_when_present(self, api):
        """Notifications should have proper structure when present."""
        # Use a large window to increase chance of finding notifications
        response = api.get_notifications(within=1440)  # 24 hours
        data = response.json()

        if data["count"] > 0:
            notif = data["notifications"][0]
            # Required fields
            assert "title" in notif
            assert "notifyAt" in notif
            assert "type" in notif
            # Type should be 'relative', 'absolute', or 'day-wide'
            assert notif["type"] in ("relative", "absolute", "day-wide")

    def test_notification_rich_fields_when_relative(self, api):
        """Relative notifications should include rich information."""
        response = api.get_notifications(within=1440)  # 24 hours
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

    def test_count_matches_notifications_length(self, api):
        """Count should match actual number of notifications."""
        response = api.get_notifications()
        data = response.json()

        assert data["count"] == len(data["notifications"])
