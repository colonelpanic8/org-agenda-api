"""
Integration tests that validate API responses against JSON schemas.

These tests ensure that:
1. The API returns data matching the documented schema
2. The schema accurately describes the API responses
"""

import pytest
from schemas.validation import (
    validate_get_all_todos,
    validate_agenda,
    validate_capture_templates,
    validate_capture_response,
    validate_health,
    validate_todo_states,
    validate_custom_views,
    validate_update_response,
    validate_complete_response,
    validate_delete_response,
)
from jsonschema import ValidationError


class TestGetAllTodosSchema:
    """Schema validation for GET /get-all-todos."""

    def test_response_matches_schema(self, api):
        """Response should match the JSON schema."""
        response = api.get_all_todos()
        data = response.json()
        validate_get_all_todos(data)

    def test_todos_have_required_fields(self, api):
        """Each todo should have the required fields."""
        response = api.get_all_todos()
        data = response.json()
        for todo in data["todos"]:
            assert "title" in todo
            assert "isWindowHabit" in todo

    def test_defaults_have_notify_before(self, api):
        """Defaults should include notifyBefore array."""
        response = api.get_all_todos()
        data = response.json()
        assert "defaults" in data
        assert "notifyBefore" in data["defaults"]
        assert isinstance(data["defaults"]["notifyBefore"], list)


class TestAgendaSchema:
    """Schema validation for GET /agenda."""

    def test_response_matches_schema(self, api):
        """Response should match the JSON schema."""
        response = api.get_agenda()
        data = response.json()
        validate_agenda(data)

    def test_has_span_and_date(self, api):
        """Response should have span and date fields."""
        response = api.get_agenda()
        data = response.json()
        assert data["span"] in ["day", "week"]
        assert "date" in data

    def test_week_span_response(self, api):
        """Week span response should match schema."""
        response = api.get_agenda(span="week")
        data = response.json()
        validate_agenda(data)
        assert data["span"] == "week"


class TestCaptureTemplatesSchema:
    """Schema validation for GET /capture-templates."""

    def test_response_matches_schema(self, api):
        """Response should match the JSON schema."""
        response = api.get_templates()
        data = response.json()
        validate_capture_templates(data)

    def test_templates_have_required_fields(self, api):
        """Each template should have name and prompts."""
        response = api.get_templates()
        data = response.json()
        for key, template in data.items():
            assert isinstance(key, str)
            assert "name" in template
            assert "prompts" in template


class TestCaptureSchema:
    """Schema validation for POST /capture."""

    def test_success_response_matches_schema(self, api):
        """Successful capture response should match schema."""
        response = api.capture("todo", {"Title": "Test task from schema validation"})
        data = response.json()
        validate_capture_response(data)
        assert data["status"] == "created"

    def test_error_response_matches_schema(self, api):
        """Error capture response should match schema."""
        response = api.capture("nonexistent_template", {"Title": "Test"})
        data = response.json()
        validate_capture_response(data)
        assert data["status"] == "error"


class TestHealthSchema:
    """Schema validation for GET /health."""

    def test_response_matches_schema(self, api):
        """Response should match the JSON schema."""
        response = api.get("/health")
        data = response.json()
        validate_health(data)

    def test_has_status_and_requests(self, api):
        """Response should have status and requests fields."""
        response = api.get("/health")
        data = response.json()
        assert data["status"] in ["ok", "unhealthy"]
        assert isinstance(data["requests"], int)


class TestTodoStatesSchema:
    """Schema validation for GET /todo-states."""

    def test_response_matches_schema(self, api):
        """Response should match the JSON schema."""
        response = api.get("/todo-states")
        data = response.json()
        validate_todo_states(data)

    def test_has_active_and_done(self, api):
        """Response should have active and done arrays."""
        response = api.get("/todo-states")
        data = response.json()
        assert isinstance(data["active"], list)
        assert isinstance(data["done"], list)


class TestCustomViewsSchema:
    """Schema validation for GET /custom-views."""

    def test_response_matches_schema(self, api):
        """Response should match the JSON schema."""
        response = api.get_custom_views()
        data = response.json()
        validate_custom_views(data)


class TestUpdateSchema:
    """Schema validation for POST /update."""

    def test_success_response_matches_schema(self, api):
        """Successful update response should match schema."""
        # First create a todo to update
        capture_resp = api.capture("todo", {"Title": "Task to update for schema test"})
        created = capture_resp.json()

        # Update it
        response = api.update_todo(created, {"priority": "A"})
        data = response.json()
        validate_update_response(data)
        assert data["status"] == "updated"

    def test_error_response_matches_schema(self, api):
        """Error update response should match schema."""
        response = api.update_todo(
            {"file": "/nonexistent.org", "pos": 1, "title": "Nonexistent"},
            {"priority": "A"}
        )
        data = response.json()
        validate_update_response(data)
        assert data["status"] == "error"


class TestCompleteSchema:
    """Schema validation for POST /complete."""

    def test_success_response_matches_schema(self, api):
        """Successful complete response should match schema."""
        # First create a todo to complete
        capture_resp = api.capture("todo", {"Title": "Task to complete for schema test"})
        created = capture_resp.json()

        # Complete it
        response = api.complete_todo(created)
        data = response.json()
        validate_complete_response(data)
        assert data["status"] == "completed"

    def test_error_response_matches_schema(self, api):
        """Error complete response should match schema."""
        response = api.complete_todo(
            {"file": "/nonexistent.org", "pos": 1, "title": "Nonexistent"}
        )
        data = response.json()
        validate_complete_response(data)
        assert data["status"] == "error"


class TestDeleteSchema:
    """Schema validation for POST /delete."""

    def test_success_response_matches_schema(self, api):
        """Successful delete response should match schema."""
        # First create a todo to delete
        capture_resp = api.capture("todo", {"Title": "Task to delete for schema test"})
        created = capture_resp.json()

        # Delete it
        response = api.delete_todo(created)
        data = response.json()
        validate_delete_response(data)
        assert data["deleted"] is True

    def test_error_response_matches_schema(self, api):
        """Error delete response should match schema."""
        response = api.delete_todo(
            {"file": "/nonexistent.org", "pos": 999999}
        )
        data = response.json()
        validate_delete_response(data)
        assert data["status"] == "error"


class TestTodoItemFields:
    """Validate that TodoItem fields match expected types."""

    def test_scheduled_is_string_or_null(self, api):
        """scheduled field should be string or null."""
        response = api.get_all_todos()
        for todo in response.json()["todos"]:
            scheduled = todo.get("scheduled")
            assert scheduled is None or isinstance(scheduled, str)

    def test_deadline_is_string_or_null(self, api):
        """deadline field should be string or null."""
        response = api.get_all_todos()
        for todo in response.json()["todos"]:
            deadline = todo.get("deadline")
            assert deadline is None or isinstance(deadline, str)

    def test_tags_is_array_or_null(self, api):
        """tags field should be array or null."""
        response = api.get_all_todos()
        for todo in response.json()["todos"]:
            tags = todo.get("tags")
            assert tags is None or isinstance(tags, list)

    def test_level_is_positive_integer(self, api):
        """level field should be positive integer."""
        response = api.get_all_todos()
        for todo in response.json()["todos"]:
            level = todo.get("level")
            if level is not None:
                assert isinstance(level, int)
                assert level >= 1

    def test_pos_is_positive_integer(self, api):
        """pos field should be positive integer."""
        response = api.get_all_todos()
        for todo in response.json()["todos"]:
            pos = todo.get("pos")
            if pos is not None:
                assert isinstance(pos, int)
                assert pos >= 1

    def test_is_window_habit_is_boolean(self, api):
        """isWindowHabit field should be boolean."""
        response = api.get_all_todos()
        for todo in response.json()["todos"]:
            assert isinstance(todo["isWindowHabit"], bool)


class TestTimestampFormat:
    """Validate timestamp formats in responses."""

    def test_scheduled_date_format(self, api):
        """scheduled dates should be ISO format."""
        response = api.get_all_todos()
        import re
        date_pattern = re.compile(r"^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2}:\d{2})?$")
        for todo in response.json()["todos"]:
            scheduled = todo.get("scheduled")
            if scheduled:
                assert date_pattern.match(scheduled), f"Invalid scheduled format: {scheduled}"

    def test_deadline_date_format(self, api):
        """deadline dates should be ISO format."""
        response = api.get_all_todos()
        import re
        date_pattern = re.compile(r"^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2}:\d{2})?$")
        for todo in response.json()["todos"]:
            deadline = todo.get("deadline")
            if deadline:
                assert date_pattern.match(deadline), f"Invalid deadline format: {deadline}"

    def test_agenda_date_format(self, api):
        """agenda date field should be YYYY-MM-DD."""
        response = api.get_agenda()
        data = response.json()
        import re
        assert re.match(r"^\d{4}-\d{2}-\d{2}$", data["date"])
