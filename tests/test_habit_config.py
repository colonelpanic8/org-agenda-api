"""Tests for /habit-config endpoint."""

import pytest


class TestHabitConfig:
    """Tests for the /habit-config endpoint."""

    def test_returns_200(self, api):
        """Endpoint returns 200 status."""
        response = api.get("/habit-config")
        assert response.status_code == 200

    def test_returns_json_object(self, api):
        """Endpoint returns valid JSON."""
        response = api.get("/habit-config")
        data = response.json()
        assert isinstance(data, dict)

    def test_has_status_field(self, api):
        """Response has status field."""
        response = api.get("/habit-config")
        data = response.json()
        assert "status" in data
        assert data["status"] == "ok"

    def test_has_enabled_field(self, api):
        """Response has enabled field indicating if org-window-habit-mode is on."""
        response = api.get("/habit-config")
        data = response.json()
        assert "enabled" in data
        assert isinstance(data["enabled"], bool)

    def test_has_colors_when_enabled(self, api):
        """Response has colors object when org-window-habit-mode is enabled."""
        response = api.get("/habit-config")
        data = response.json()
        if data.get("enabled"):
            assert "colors" in data
            colors = data["colors"]
            assert "conforming" in colors
            assert "notConforming" in colors

    def test_colors_are_hex_strings(self, api):
        """Color values are hex color strings."""
        response = api.get("/habit-config")
        data = response.json()
        if data.get("enabled") and "colors" in data:
            for key, value in data["colors"].items():
                assert isinstance(value, str), f"Color {key} should be string"
                assert value.startswith("#"), f"Color {key} should start with #"

    def test_has_display_settings_when_enabled(self, api):
        """Response has display settings when enabled."""
        response = api.get("/habit-config")
        data = response.json()
        if data.get("enabled"):
            assert "display" in data
            display = data["display"]
            assert "precedingIntervals" in display
            assert "followingDays" in display

    def test_has_behavior_settings_when_enabled(self, api):
        """Response has behavior settings when enabled."""
        response = api.get("/habit-config")
        data = response.json()
        if data.get("enabled"):
            assert "behavior" in data
            behavior = data["behavior"]
            assert "repeatToDeadline" in behavior
            assert "repeatToScheduled" in behavior
