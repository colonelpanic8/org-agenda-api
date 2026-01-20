"""Tests for category strategy endpoints."""

import pytest


class TestCategoryTypes:
    """Tests for GET /category-types endpoint."""

    def test_returns_200(self, api):
        """Endpoint returns 200 status."""
        response = api.get("/category-types")
        assert response.status_code == 200

    def test_returns_json(self, api):
        """Endpoint returns valid JSON."""
        response = api.get("/category-types")
        data = response.json()
        assert isinstance(data, dict)

    def test_has_types_array(self, api):
        """Response has types array."""
        response = api.get("/category-types")
        data = response.json()
        assert "types" in data
        assert isinstance(data["types"], list)

    def test_empty_when_no_strategies_registered(self, api):
        """Returns empty types when no strategies are registered."""
        response = api.get("/category-types")
        data = response.json()
        # By default no strategies are registered in test environment
        assert data["types"] == []


class TestCategoriesEndpoint:
    """Tests for GET /categories endpoint."""

    def test_returns_200(self, api):
        """Endpoint returns 200 status even with missing params."""
        response = api.get("/categories")
        assert response.status_code == 200

    def test_missing_type_returns_error(self, api):
        """Missing type parameter returns error."""
        response = api.get("/categories")
        data = response.json()
        assert data.get("status") == "error"
        assert "type" in data.get("message", "").lower()

    def test_unknown_type_returns_error(self, api):
        """Unknown strategy type returns error."""
        response = api.get("/categories?type=nonexistent")
        data = response.json()
        assert data.get("status") == "error"
        assert "unknown" in data.get("message", "").lower()


class TestCategoryTasksEndpoint:
    """Tests for GET /category-tasks endpoint."""

    def test_returns_200(self, api):
        """Endpoint returns 200 status even with missing params."""
        response = api.get("/category-tasks")
        assert response.status_code == 200

    def test_missing_type_returns_error(self, api):
        """Missing type parameter returns error."""
        response = api.get("/category-tasks")
        data = response.json()
        assert data.get("status") == "error"
        assert "type" in data.get("message", "").lower()

    def test_missing_category_returns_error(self, api):
        """Missing category parameter returns error."""
        response = api.get("/category-tasks?type=sometype")
        data = response.json()
        # First it should check for type validity, then category
        # Since 'sometype' doesn't exist, we get unknown strategy error
        assert data.get("status") == "error"

    def test_unknown_type_returns_error(self, api):
        """Unknown strategy type returns error."""
        response = api.get("/category-tasks?type=nonexistent&category=test")
        data = response.json()
        assert data.get("status") == "error"
        assert "unknown" in data.get("message", "").lower()
