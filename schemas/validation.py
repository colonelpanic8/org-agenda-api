"""
Validation helpers for testing org-agenda-api responses.

This module provides convenient functions for validating API responses
against their JSON schemas in tests.
"""

from typing import Any

from jsonschema import validate, ValidationError

from . import (
    GET_ALL_TODOS_RESPONSE,
    AGENDA_RESPONSE,
    CAPTURE_TEMPLATES_RESPONSE,
    CAPTURE_RESPONSE,
    HEALTH_RESPONSE,
    VERSION_RESPONSE,
    TODO_STATES_RESPONSE,
    FILTER_OPTIONS_RESPONSE,
    AGENDA_FILES_RESPONSE,
    CUSTOM_VIEWS_RESPONSE,
    CUSTOM_VIEW_RESPONSE,
    METADATA_RESPONSE,
    UPDATE_RESPONSE,
    COMPLETE_RESPONSE,
    DELETE_RESPONSE,
    CATEGORY_TYPES_RESPONSE,
    CATEGORIES_RESPONSE,
    CATEGORY_TASKS_RESPONSE,
    HABIT_STATUS_RESPONSE,
)


class APIValidator:
    """
    Validator for org-agenda-api responses.

    Usage:
        validator = APIValidator()

        # In tests:
        response = api.get_all_todos()
        validator.validate_get_all_todos(response.json())
    """

    def validate_get_all_todos(self, data: Any) -> None:
        """Validate GET /get-all-todos response."""
        validate(data, GET_ALL_TODOS_RESPONSE)

    def validate_agenda(self, data: Any) -> None:
        """Validate GET /agenda response."""
        validate(data, AGENDA_RESPONSE)

    def validate_capture_templates(self, data: Any) -> None:
        """Validate GET /capture-templates response."""
        validate(data, CAPTURE_TEMPLATES_RESPONSE)

    def validate_capture_response(self, data: Any) -> None:
        """Validate POST /capture response."""
        validate(data, CAPTURE_RESPONSE)

    def validate_health(self, data: Any) -> None:
        """Validate GET /health response."""
        validate(data, HEALTH_RESPONSE)

    def validate_version(self, data: Any) -> None:
        """Validate GET /version response."""
        validate(data, VERSION_RESPONSE)

    def validate_todo_states(self, data: Any) -> None:
        """Validate GET /todo-states response."""
        validate(data, TODO_STATES_RESPONSE)

    def validate_filter_options(self, data: Any) -> None:
        """Validate GET /filter-options response."""
        validate(data, FILTER_OPTIONS_RESPONSE)

    def validate_agenda_files(self, data: Any) -> None:
        """Validate GET /agenda-files response."""
        validate(data, AGENDA_FILES_RESPONSE)

    def validate_custom_views(self, data: Any) -> None:
        """Validate GET /custom-views response."""
        validate(data, CUSTOM_VIEWS_RESPONSE)

    def validate_custom_view(self, data: Any) -> None:
        """Validate GET /custom-view response."""
        validate(data, CUSTOM_VIEW_RESPONSE)

    def validate_metadata(self, data: Any) -> None:
        """Validate GET /metadata response."""
        validate(data, METADATA_RESPONSE)

    def validate_update_response(self, data: Any) -> None:
        """Validate POST /update response."""
        validate(data, UPDATE_RESPONSE)

    def validate_complete_response(self, data: Any) -> None:
        """Validate POST /complete response."""
        validate(data, COMPLETE_RESPONSE)

    def validate_delete_response(self, data: Any) -> None:
        """Validate POST /delete response."""
        validate(data, DELETE_RESPONSE)

    def validate_category_types(self, data: Any) -> None:
        """Validate GET /category-types response."""
        validate(data, CATEGORY_TYPES_RESPONSE)

    def validate_categories(self, data: Any) -> None:
        """Validate GET /categories response."""
        validate(data, CATEGORIES_RESPONSE)

    def validate_category_tasks(self, data: Any) -> None:
        """Validate GET /category-tasks response."""
        validate(data, CATEGORY_TASKS_RESPONSE)

    def validate_habit_status(self, data: Any) -> None:
        """Validate GET /habit-status response."""
        validate(data, HABIT_STATUS_RESPONSE)


# Convenience instance
api_validator = APIValidator()


# Direct validation functions for simpler usage
def validate_get_all_todos(data: Any) -> None:
    """Validate GET /get-all-todos response."""
    api_validator.validate_get_all_todos(data)


def validate_agenda(data: Any) -> None:
    """Validate GET /agenda response."""
    api_validator.validate_agenda(data)


def validate_capture_templates(data: Any) -> None:
    """Validate GET /capture-templates response."""
    api_validator.validate_capture_templates(data)


def validate_capture_response(data: Any) -> None:
    """Validate POST /capture response."""
    api_validator.validate_capture_response(data)


def validate_health(data: Any) -> None:
    """Validate GET /health response."""
    api_validator.validate_health(data)


def validate_version(data: Any) -> None:
    """Validate GET /version response."""
    api_validator.validate_version(data)


def validate_todo_states(data: Any) -> None:
    """Validate GET /todo-states response."""
    api_validator.validate_todo_states(data)


def validate_filter_options(data: Any) -> None:
    """Validate GET /filter-options response."""
    api_validator.validate_filter_options(data)


def validate_agenda_files(data: Any) -> None:
    """Validate GET /agenda-files response."""
    api_validator.validate_agenda_files(data)


def validate_custom_views(data: Any) -> None:
    """Validate GET /custom-views response."""
    api_validator.validate_custom_views(data)


def validate_custom_view(data: Any) -> None:
    """Validate GET /custom-view response."""
    api_validator.validate_custom_view(data)


def validate_metadata(data: Any) -> None:
    """Validate GET /metadata response."""
    api_validator.validate_metadata(data)


def validate_update_response(data: Any) -> None:
    """Validate POST /update response."""
    api_validator.validate_update_response(data)


def validate_complete_response(data: Any) -> None:
    """Validate POST /complete response."""
    api_validator.validate_complete_response(data)


def validate_delete_response(data: Any) -> None:
    """Validate POST /delete response."""
    api_validator.validate_delete_response(data)


def validate_category_types(data: Any) -> None:
    """Validate GET /category-types response."""
    api_validator.validate_category_types(data)


def validate_categories(data: Any) -> None:
    """Validate GET /categories response."""
    api_validator.validate_categories(data)


def validate_category_tasks(data: Any) -> None:
    """Validate GET /category-tasks response."""
    api_validator.validate_category_tasks(data)


def validate_habit_status(data: Any) -> None:
    """Validate GET /habit-status response."""
    api_validator.validate_habit_status(data)
