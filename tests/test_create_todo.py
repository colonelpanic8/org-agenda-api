"""Integration tests for POST /create-todo endpoint."""

import pytest


class TestCreateTodo:
    """Tests for POST /create-todo endpoint."""

    def test_returns_200(self, api):
        """Endpoint should return 200 OK on successful creation."""
        response = api.create_todo("Test todo from pytest")
        assert response.status_code == 200

    def test_returns_confirmation(self, api):
        """Endpoint should return confirmation with title."""
        response = api.create_todo("Confirmation test todo")
        data = response.json()

        assert data.get("status") == "created"
        assert data.get("title") == "Confirmation test todo"

    def test_created_todo_appears_in_list(self, api):
        """Created TODO should appear in get-all-todos."""
        unique_title = "Unique test todo 12345"

        # Create the todo
        create_response = api.create_todo(unique_title)
        assert create_response.status_code == 200

        # Verify it appears in the list
        list_response = api.get_all_todos()
        data = list_response.json()

        titles = [item.get("title", "") for item in data]
        matching = [t for t in titles if unique_title in t]

        assert len(matching) > 0, f"Created todo not found. Titles: {titles}"

    def test_created_todo_in_inbox_file(self, api, org_dir):
        """Created TODO should be written to the inbox file."""
        unique_title = "Inbox file test todo 67890"

        # Create the todo
        api.create_todo(unique_title)

        # Check the inbox file directly
        inbox_path = org_dir / "inbox.org"
        content = inbox_path.read_text()

        assert unique_title in content, f"Todo not found in inbox. Content:\n{content}"
