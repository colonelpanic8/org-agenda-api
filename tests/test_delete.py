"""Integration tests for POST /delete endpoint."""

import pytest


class TestDeleteTodo:
    """Tests for POST /delete endpoint."""

    def test_returns_200_on_success(self, api):
        """Endpoint should return 200 OK on successful delete."""
        # Create a todo to delete
        api.create_todo("Delete me please")

        # Find it
        todos = api.get_all_todos().json()["todos"]
        todo = next((t for t in todos if "Delete me please" in t.get("title", "")), None)
        assert todo is not None, "Failed to create test todo"

        # Delete it
        response = api.post("/delete", json={
            "file": todo["file"],
            "position": todo["pos"]
        })
        assert response.status_code == 200

    def test_returns_deleted_title(self, api):
        """Response should include the deleted item's title."""
        api.create_todo("Title for deletion test")

        todos = api.get_all_todos().json()["todos"]
        todo = next((t for t in todos if "Title for deletion test" in t.get("title", "")), None)
        assert todo is not None

        response = api.post("/delete", json={
            "file": todo["file"],
            "position": todo["pos"]
        })
        data = response.json()

        assert data.get("deleted") is True
        assert "Title for deletion test" in data.get("title", "")

    def test_item_no_longer_in_list(self, api):
        """Deleted item should not appear in subsequent queries."""
        api.create_todo("Vanishing todo 12345")

        todos = api.get_all_todos().json()["todos"]
        todo = next((t for t in todos if "Vanishing todo 12345" in t.get("title", "")), None)
        assert todo is not None

        # Delete it
        api.post("/delete", json={
            "file": todo["file"],
            "position": todo["pos"]
        })

        # Verify it's gone
        todos_after = api.get_all_todos().json()["todos"]
        found = next((t for t in todos_after if "Vanishing todo 12345" in t.get("title", "")), None)
        assert found is None, "Todo should have been deleted"
