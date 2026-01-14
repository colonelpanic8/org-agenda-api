"""Tests for custom agenda views endpoints."""

import pytest


class TestCustomViews:
    """Tests for GET /custom-views endpoint."""

    def test_list_custom_views(self, api):
        """Should return list of available custom views."""
        response = api.get("/custom-views")
        assert response.status_code == 200

        data = response.json()
        assert "views" in data
        views = data["views"]

        # Should have the views we configured in run-emacs-server.el
        assert len(views) >= 5

        # Check structure
        for view in views:
            assert "key" in view
            assert "name" in view

        # Check specific views exist
        keys = [v["key"] for v in views]
        assert "n" in keys  # Next actions
        assert "s" in keys  # Started tasks
        assert "w" in keys  # Waiting tasks
        assert "h" in keys  # High priority
        assert "W" in keys  # Work tasks

    def test_custom_views_have_names(self, api):
        """Each view should have a descriptive name."""
        response = api.get("/custom-views")
        data = response.json()

        view_map = {v["key"]: v["name"] for v in data["views"]}

        assert view_map["n"] == "Next actions"
        assert view_map["s"] == "Started tasks"
        assert view_map["w"] == "Waiting tasks"
        assert view_map["h"] == "High priority"
        assert view_map["W"] == "Work tasks"


class TestCustomView:
    """Tests for GET /custom-view endpoint."""

    def test_get_next_tasks(self, api):
        """Should return all NEXT tasks."""
        response = api.get("/custom-view?key=n")
        assert response.status_code == 200

        data = response.json()
        assert data["key"] == "n"
        assert data["name"] == "Next actions"
        assert "entries" in data

        entries = data["entries"]
        # We have 3 NEXT tasks in sample.org
        assert len(entries) >= 3

        # All entries should have NEXT state
        for entry in entries:
            assert entry["todo"] == "NEXT"

    def test_get_started_tasks(self, api):
        """Should return all STARTED tasks."""
        response = api.get("/custom-view?key=s")
        assert response.status_code == 200

        data = response.json()
        assert data["key"] == "s"
        entries = data["entries"]

        # We have 1 STARTED task in sample.org
        assert len(entries) >= 1

        for entry in entries:
            assert entry["todo"] == "STARTED"

    def test_get_waiting_tasks(self, api):
        """Should return all WAITING tasks."""
        response = api.get("/custom-view?key=w")
        assert response.status_code == 200

        data = response.json()
        entries = data["entries"]

        # We have 1 WAITING task in sample.org
        assert len(entries) >= 1

        for entry in entries:
            assert entry["todo"] == "WAITING"

    def test_get_high_priority_tasks(self, api):
        """Should return all high priority tasks."""
        response = api.get("/custom-view?key=h")
        assert response.status_code == 200

        data = response.json()
        entries = data["entries"]

        # We have 2 priority A tasks in sample.org
        assert len(entries) >= 2

        for entry in entries:
            assert entry["priority"] == "A"

    def test_get_work_tasks(self, api):
        """Should return all tasks tagged with :work:."""
        response = api.get("/custom-view?key=W")
        assert response.status_code == 200

        data = response.json()
        entries = data["entries"]

        # We have several :work: tasks
        assert len(entries) >= 4

        for entry in entries:
            assert "work" in entry["tags"]

    def test_entry_structure(self, api):
        """Entries should have the standard structure."""
        response = api.get("/custom-view?key=n")
        data = response.json()
        entries = data["entries"]

        assert len(entries) > 0
        entry = entries[0]

        # Should have all standard fields
        assert "todo" in entry
        assert "title" in entry
        assert "tags" in entry
        assert "level" in entry
        assert "scheduled" in entry
        assert "deadline" in entry
        assert "file" in entry
        assert "pos" in entry
        assert "id" in entry
        assert "olpath" in entry
        assert "priority" in entry
        assert "agendaLine" in entry

    def test_missing_key_returns_error(self, api):
        """Should return error when key parameter is missing."""
        response = api.get("/custom-view")
        assert response.status_code == 200  # We return 200 with error in body

        data = response.json()
        assert data["status"] == "error"
        assert "key" in data["message"].lower()

    def test_empty_key_returns_error(self, api):
        """Should return error when key parameter is empty."""
        response = api.get("/custom-view?key=")
        assert response.status_code == 200

        data = response.json()
        assert data["status"] == "error"
