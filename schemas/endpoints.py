"""
JSON Schema definitions for org-agenda-api endpoints.
"""

from .definitions import DEFINITIONS

# Helper to create schema with definitions
def _with_defs(schema: dict) -> dict:
    """Add shared definitions to a schema."""
    return {**schema, "definitions": DEFINITIONS}


# GET /get-all-todos
GET_ALL_TODOS_RESPONSE = _with_defs({
    "type": "object",
    "properties": {
        "defaults": {
            "type": "object",
            "properties": {
                "notifyBefore": {
                    "type": "array",
                    "items": {"type": "integer", "minimum": 1},
                },
            },
            "required": ["notifyBefore"],
        },
        "todos": {
            "type": "array",
            "items": {"$ref": "#/definitions/TodoItem"},
        },
        "gitRefresh": {
            "description": "Git refresh results (only present if refresh=true)",
            "type": "array",
            "items": {"$ref": "#/definitions/GitRefreshResult"},
        },
    },
    "required": ["defaults", "todos"],
})


# GET /agenda
AGENDA_RESPONSE = _with_defs({
    "type": "object",
    "properties": {
        "span": {
            "type": "string",
            "enum": ["day", "week"],
        },
        "date": {
            "type": "string",
            "pattern": r"^\d{4}-\d{2}-\d{2}$",
        },
        "entries": {
            "type": "array",
            "items": {"$ref": "#/definitions/TodoItem"},
        },
        "gitRefresh": {
            "type": "array",
            "items": {"$ref": "#/definitions/GitRefreshResult"},
        },
    },
    "required": ["span", "date", "entries"],
})


# GET /capture-templates
# Response is a dict keyed by template key
CAPTURE_TEMPLATES_RESPONSE = _with_defs({
    "type": "object",
    "additionalProperties": {
        "type": "object",
        "properties": {
            "name": {"type": "string"},
            "prompts": {
                "type": "array",
                "items": {"$ref": "#/definitions/CapturePrompt"},
            },
        },
        "required": ["name", "prompts"],
    },
})


# POST /capture request
CAPTURE_REQUEST = {
    "type": "object",
    "properties": {
        "template": {
            "description": "Template key",
            "type": "string",
        },
        "values": {
            "description": "Values for template prompts",
            "type": "object",
            "additionalProperties": True,
        },
    },
    "required": ["template", "values"],
}


# POST /capture response
CAPTURE_RESPONSE = _with_defs({
    "oneOf": [
        {
            "type": "object",
            "properties": {
                "status": {"const": "created"},
                "template": {"type": "string"},
                "file": {"type": "string"},
                "pos": {"type": "integer", "minimum": 1},
                "title": {"type": "string"},
                "id": {"oneOf": [{"type": "string"}, {"type": "null"}]},
            },
            "required": ["status", "template"],
        },
        {"$ref": "#/definitions/ErrorResponse"},
    ],
})


# GET /health
HEALTH_RESPONSE = {
    "type": "object",
    "properties": {
        "status": {
            "type": "string",
            "enum": ["ok", "unhealthy"],
        },
        "uptime": {
            "oneOf": [{"type": "number", "minimum": 0}, {"type": "null"}],
        },
        "requests": {
            "type": "integer",
            "minimum": 0,
        },
        "captureStatus": {
            "description": "Reason for unhealthy status",
            "type": "string",
        },
    },
    "required": ["status", "requests"],
}


# GET /version
VERSION_RESPONSE = {
    "type": "object",
    "properties": {
        "version": {
            "type": "string",
            "pattern": r"^\d+\.\d+\.\d+",
        },
        "gitCommit": {
            "type": "string",
        },
    },
    "required": ["version", "gitCommit"],
}


# GET /todo-states
TODO_STATES_RESPONSE = {
    "type": "object",
    "properties": {
        "active": {
            "type": "array",
            "items": {"type": "string"},
        },
        "done": {
            "type": "array",
            "items": {"type": "string"},
        },
    },
    "required": ["active", "done"],
}


# GET /filter-options
FILTER_OPTIONS_RESPONSE = {
    "type": "object",
    "properties": {
        "categories": {
            "type": "array",
            "items": {"type": "string"},
        },
        "tags": {
            "type": "array",
            "items": {"type": "string"},
        },
        "priorities": {
            "type": "array",
            "items": {"type": "string"},
        },
    },
    "required": ["categories", "tags", "priorities"],
}


# GET /agenda-files
AGENDA_FILES_RESPONSE = {
    "type": "object",
    "properties": {
        "files": {
            "type": "array",
            "items": {"type": "string"},
        },
    },
    "required": ["files"],
}


# GET /custom-views
CUSTOM_VIEWS_RESPONSE = _with_defs({
    "type": "array",
    "items": {"$ref": "#/definitions/CustomView"},
})


# GET /custom-view?key=...
CUSTOM_VIEW_RESPONSE = _with_defs({
    "oneOf": [
        {
            "type": "object",
            "properties": {
                "key": {"type": "string"},
                "entries": {
                    "type": "array",
                    "items": {"$ref": "#/definitions/TodoItem"},
                },
            },
            "required": ["key", "entries"],
        },
        {"$ref": "#/definitions/ErrorResponse"},
    ],
})


# GET /metadata
METADATA_RESPONSE = {
    "type": "object",
    "properties": {
        "version": {"type": "string"},
        "gitCommit": {"type": "string"},
        "uptime": {"oneOf": [{"type": "number"}, {"type": "null"}]},
        "agendaFilesCount": {"type": "integer", "minimum": 0},
        "todoStates": {
            "type": "object",
            "properties": {
                "active": {"type": "array", "items": {"type": "string"}},
                "done": {"type": "array", "items": {"type": "string"}},
            },
        },
        "captureTemplatesCount": {"type": "integer", "minimum": 0},
        "categoryStrategiesCount": {"type": "integer", "minimum": 0},
        "customViewsCount": {"type": "integer", "minimum": 0},
    },
    "required": ["version", "gitCommit", "agendaFilesCount"],
}


# POST /update request
UPDATE_REQUEST = {
    "type": "object",
    "properties": {
        "id": {
            "description": "org-id (preferred)",
            "oneOf": [{"type": "string"}, {"type": "null"}],
        },
        "file": {
            "description": "File path (fallback)",
            "type": "string",
        },
        "pos": {
            "description": "Position in file (fallback)",
            "type": "integer",
            "minimum": 1,
        },
        "title": {
            "description": "Heading title (for matching)",
            "type": "string",
        },
        "new_title": {
            "description": "New title to set",
            "oneOf": [{"type": "string"}, {"type": "null"}],
        },
        "scheduled": {
            "description": "SCHEDULED date/datetime (ISO format) or null to clear",
            "oneOf": [{"type": "string"}, {"type": "null"}],
        },
        "deadline": {
            "description": "DEADLINE date/datetime (ISO format) or null to clear",
            "oneOf": [{"type": "string"}, {"type": "null"}],
        },
        "priority": {
            "description": "Priority letter (A-Z) or null to clear",
            "oneOf": [{"type": "string", "pattern": "^[A-Z]$"}, {"type": "null"}],
        },
        "tags": {
            "description": "Array of tags or empty array to clear",
            "oneOf": [
                {"type": "array", "items": {"type": "string"}},
                {"type": "null"},
            ],
        },
        "properties": {
            "description": "Properties to set/update",
            "type": "object",
            "additionalProperties": {
                "oneOf": [{"type": "string"}, {"type": "null"}],
            },
        },
    },
    # At least one identifier is required, but schema doesn't enforce OR logic
}


# POST /update response
UPDATE_RESPONSE = _with_defs({
    "oneOf": [
        {
            "type": "object",
            "properties": {
                "status": {"const": "updated"},
                "title": {"type": "string"},
                "file": {"type": "string"},
                "pos": {"type": "integer", "minimum": 1},
                "updates": {
                    "type": "object",
                    "additionalProperties": True,
                },
            },
            "required": ["status", "title", "file", "pos"],
        },
        {"$ref": "#/definitions/ErrorResponse"},
    ],
})


# POST /complete request
COMPLETE_REQUEST = {
    "type": "object",
    "properties": {
        "id": {
            "oneOf": [{"type": "string"}, {"type": "null"}],
        },
        "file": {"type": "string"},
        "pos": {"type": "integer", "minimum": 1},
        "title": {"type": "string"},
        "state": {
            "description": "New state (defaults to DONE)",
            "type": "string",
        },
    },
}


# POST /complete response
COMPLETE_RESPONSE = _with_defs({
    "oneOf": [
        {
            "type": "object",
            "properties": {
                "status": {"const": "completed"},
                "title": {"type": "string"},
                "previous_state": {"oneOf": [{"type": "string"}, {"type": "null"}]},
                "new_state": {"type": "string"},
                "file": {"type": "string"},
                "pos": {"type": "integer", "minimum": 1},
                "completedAt": {"oneOf": [{"type": "string"}, {"type": "null"}]},
            },
            "required": ["status", "title", "new_state", "file", "pos"],
        },
        {"$ref": "#/definitions/ErrorResponse"},
    ],
})


# POST /delete request
DELETE_REQUEST = {
    "type": "object",
    "properties": {
        "id": {
            "description": "org-id to locate the item",
            "type": "string",
        },
        "file": {
            "description": "File path (with pos)",
            "type": "string",
        },
        "pos": {
            "description": "Position in file (with file)",
            "type": "integer",
            "minimum": 1,
        },
        "include_children": {
            "description": "Delete subtree even if item has children",
            "type": "boolean",
        },
    },
    # Need either id OR (file AND pos)
}


# POST /delete response
DELETE_RESPONSE = _with_defs({
    "oneOf": [
        {
            "type": "object",
            "properties": {
                "deleted": {"const": True},
                "title": {"type": "string"},
                "children_deleted": {"type": "integer", "minimum": 0},
            },
            "required": ["deleted", "title"],
        },
        {
            "type": "object",
            "properties": {
                "status": {"const": "error"},
                "code": {"type": "string"},
                "message": {"type": "string"},
            },
            "required": ["status", "code", "message"],
        },
    ],
})


# GET /category-types
CATEGORY_TYPES_RESPONSE = {
    "type": "array",
    "items": {
        "type": "object",
        "properties": {
            "type": {"type": "string"},
            "prompts": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "name": {"type": "string"},
                        "type": {"type": "string"},
                        "required": {"type": "boolean"},
                    },
                },
            },
        },
        "required": ["type"],
    },
}


# GET /categories?type=...
CATEGORIES_RESPONSE = _with_defs({
    "oneOf": [
        {
            "type": "object",
            "properties": {
                "type": {"type": "string"},
                "categories": {
                    "type": "array",
                    "items": {"type": "string"},
                },
            },
            "required": ["type", "categories"],
        },
        {"$ref": "#/definitions/ErrorResponse"},
    ],
})


# GET /category-tasks?type=...&category=...
CATEGORY_TASKS_RESPONSE = _with_defs({
    "oneOf": [
        {
            "type": "object",
            "properties": {
                "type": {"type": "string"},
                "category": {"type": "string"},
                "tasks": {
                    "type": "array",
                    "items": {"$ref": "#/definitions/TodoItem"},
                },
            },
            "required": ["type", "category", "tasks"],
        },
        {"$ref": "#/definitions/ErrorResponse"},
    ],
})


# POST /category-capture request
CATEGORY_CAPTURE_REQUEST = {
    "type": "object",
    "properties": {
        "type": {
            "description": "Strategy type name",
            "type": "string",
        },
        "category": {
            "description": "Category name",
            "type": "string",
        },
        "title": {
            "description": "Entry title",
            "type": "string",
        },
        "todo": {
            "description": "TODO state",
            "type": "string",
        },
        "scheduled": {
            "description": "SCHEDULED date",
            "type": "string",
        },
        "deadline": {
            "description": "DEADLINE date",
            "type": "string",
        },
        "priority": {
            "description": "Priority letter",
            "type": "string",
            "pattern": "^[A-Z]$",
        },
        "tags": {
            "description": "Tags to add",
            "type": "array",
            "items": {"type": "string"},
        },
        "properties": {
            "description": "Properties to set",
            "type": "object",
            "additionalProperties": {"type": "string"},
        },
    },
    "required": ["type", "category", "title"],
}


# GET /habit-status?id=...
HABIT_STATUS_RESPONSE = _with_defs({
    "oneOf": [
        {
            "type": "object",
            "properties": {
                "id": {"type": "string"},
                "title": {"type": "string"},
                "isWindowHabit": {"type": "boolean"},
                "summary": {"$ref": "#/definitions/HabitSummary"},
                "history": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "date": {"type": "string"},
                            "status": {"type": "string"},
                            "completions": {"type": "integer"},
                        },
                    },
                },
            },
            "required": ["id", "title", "isWindowHabit"],
        },
        {"$ref": "#/definitions/ErrorResponse"},
    ],
})
