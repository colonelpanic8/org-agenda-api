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
        todo = next(
            (t for t in todos if "Delete me please" in t.get("title", "")), None
        )
        assert todo is not None, "Failed to create test todo"

        # Delete it
        response = api.post("/delete", json={"file": todo["file"], "pos": todo["pos"]})
        assert response.status_code == 200

    def test_returns_deleted_title(self, api):
        """Response should include the deleted item's title."""
        api.create_todo("Title for deletion test")

        todos = api.get_all_todos().json()["todos"]
        todo = next(
            (t for t in todos if "Title for deletion test" in t.get("title", "")), None
        )
        assert todo is not None

        response = api.post("/delete", json={"file": todo["file"], "pos": todo["pos"]})
        data = response.json()

        assert data.get("deleted") is True
        assert "Title for deletion test" in data.get("title", "")

    def test_item_no_longer_in_list(self, api):
        """Deleted item should not appear in subsequent queries."""
        api.create_todo("Vanishing todo 12345")

        todos = api.get_all_todos().json()["todos"]
        todo = next(
            (t for t in todos if "Vanishing todo 12345" in t.get("title", "")), None
        )
        assert todo is not None

        # Delete it
        api.post("/delete", json={"file": todo["file"], "pos": todo["pos"]})

        # Verify it's gone
        todos_after = api.get_all_todos().json()["todos"]
        found = next(
            (t for t in todos_after if "Vanishing todo 12345" in t.get("title", "")),
            None,
        )
        assert found is None, "Todo should have been deleted"

    def test_delete_by_id(self, api):
        """Should be able to delete by org-id."""
        # Use todo-with-id template which includes %(org-id-new) for ID generation
        unique_title = "Delete by ID test 99999"
        response = api.capture("todo-with-id", {"Title": unique_title})
        assert response.status_code == 200

        todos = api.get_all_todos().json()["todos"]
        todo = next((t for t in todos if unique_title in t.get("title", "")), None)
        assert todo is not None, f"Todo '{unique_title}' not found in todos"

        # The todo-with-id template generates an org-id via %(org-id-new)
        assert todo.get("id") is not None, "Todo should have org-id from %(org-id-new)"

        response = api.post("/delete", json={"id": todo["id"]})
        assert response.status_code == 200
        assert response.json().get("deleted") is True


class TestDeleteErrors:
    """Tests for delete endpoint error handling."""

    def test_error_on_not_found(self, api):
        """Should return error for non-existent item."""
        response = api.post("/delete", json={"file": "/nonexistent/file.org", "pos": 1})
        data = response.json()
        assert "error" in data or data.get("status") == "error"

    def test_error_on_missing_params(self, api):
        """Should return error if neither id nor file+pos provided."""
        response = api.post("/delete", json={})
        data = response.json()
        assert "error" in data or data.get("status") == "error"


class TestDeleteWithChildren:
    """Tests for delete behavior with child items."""

    def test_refuses_delete_with_children(self, api):
        """Should refuse to delete item with children unless confirmed."""
        todos = api.get_all_todos().json()["todos"]
        parent = next((t for t in todos if "Parent task" in t.get("title", "")), None)

        if parent is None:
            pytest.skip("Parent task fixture not found")

        response = api.post(
            "/delete", json={"file": parent["file"], "pos": parent["pos"]}
        )
        data = response.json()

        # Should return error about children
        assert (
            data.get("status") == "error"
            or "children" in data.get("message", "").lower()
            or "children" in data.get("error", "").lower()
        )

    def test_deletes_with_children_when_confirmed(self, api):
        """Should delete subtree when include_children=true."""
        todos = api.get_all_todos().json()["todos"]
        parent = next((t for t in todos if "Parent task" in t.get("title", "")), None)

        if parent is None:
            pytest.skip("Parent task fixture not found")

        response = api.post(
            "/delete",
            json={
                "file": parent["file"],
                "pos": parent["pos"],
                "include_children": True,
            },
        )
        data = response.json()

        assert data.get("deleted") is True
        assert data.get("children_deleted", 0) > 0
