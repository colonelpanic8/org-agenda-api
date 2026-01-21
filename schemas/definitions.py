"""
Shared JSON Schema definitions for org-agenda-api.

These definitions are referenced by endpoint schemas using $ref.
"""

DEFINITIONS = {
    "Timestamp": {
        "description": "An org-mode timestamp",
        "type": "object",
        "properties": {
            "start": {
                "description": "Start time in ISO format (YYYY-MM-DD or YYYY-MM-DDTHH:MM:SS)",
                "oneOf": [{"type": "string"}, {"type": "null"}],
            },
            "end": {
                "description": "End time for ranges",
                "oneOf": [{"type": "string"}, {"type": "null"}],
            },
            "hasTime": {
                "description": "Whether the timestamp includes a time component",
                "type": "boolean",
            },
            "type": {
                "description": "Timestamp type",
                "type": "string",
                "enum": ["active", "active-range", "inactive", "inactive-range", "unknown"],
            },
            "raw": {
                "description": "Raw org-mode timestamp string",
                "type": "string",
            },
        },
        "required": ["start", "hasTime", "type", "raw"],
    },
    "TodoItem": {
        "description": "A TODO item from org-agenda",
        "type": "object",
        "properties": {
            "todo": {
                "description": "TODO state (e.g., TODO, DONE, WAITING)",
                "oneOf": [{"type": "string"}, {"type": "null"}],
            },
            "title": {
                "description": "Heading title without TODO keyword or tags",
                "type": "string",
            },
            "tags": {
                "description": "List of tags on the heading",
                "oneOf": [
                    {"type": "array", "items": {"type": "string"}},
                    {"type": "null"},
                ],
            },
            "level": {
                "description": "Heading level (1 = top-level)",
                "type": "integer",
                "minimum": 1,
            },
            "scheduled": {
                "description": "SCHEDULED timestamp (ISO format or null)",
                "oneOf": [{"type": "string"}, {"type": "null"}],
            },
            "scheduledEnd": {
                "description": "End of SCHEDULED range (for ranged timestamps)",
                "type": "string",
            },
            "deadline": {
                "description": "DEADLINE timestamp (ISO format or null)",
                "oneOf": [{"type": "string"}, {"type": "null"}],
            },
            "deadlineEnd": {
                "description": "End of DEADLINE range (for ranged timestamps)",
                "type": "string",
            },
            "timestamps": {
                "description": "Plain timestamps found in entry body",
                "type": "array",
                "items": {"$ref": "#/definitions/Timestamp"},
            },
            "file": {
                "description": "Absolute path to the org file",
                "type": "string",
            },
            "pos": {
                "description": "Character position in the file",
                "type": "integer",
                "minimum": 1,
            },
            "id": {
                "description": "org-id (if set)",
                "oneOf": [{"type": "string"}, {"type": "null"}],
            },
            "olpath": {
                "description": "Outline path (parent headings)",
                "oneOf": [
                    {"type": "array", "items": {"type": "string"}},
                    {"type": "null"},
                ],
            },
            "priority": {
                "description": "Priority letter (A, B, C, etc.)",
                "oneOf": [{"type": "string", "pattern": "^[A-Z]$"}, {"type": "null"}],
            },
            "notifyBefore": {
                "description": "Minutes before to notify (from WILD_NOTIFIER_NOTIFY_BEFORE)",
                "oneOf": [
                    {"type": "array", "items": {"type": "integer", "minimum": 1}},
                    {"type": "null"},
                ],
            },
            "category": {
                "description": "Category (from CATEGORY property or filename)",
                "oneOf": [{"type": "string"}, {"type": "null"}],
            },
            "agendaLine": {
                "description": "Raw agenda display line",
                "type": "string",
            },
            "properties": {
                "description": "All entry properties as key-value pairs",
                "oneOf": [
                    {"type": "object", "additionalProperties": {"type": "string"}},
                    {"type": "null"},
                ],
            },
            "completedAt": {
                "description": "CLOSED timestamp (ISO format)",
                "oneOf": [{"type": "string"}, {"type": "null"}],
            },
            "isWindowHabit": {
                "description": "Whether this is a window-based habit",
                "type": "boolean",
            },
            "habitSummary": {
                "description": "Habit tracking summary (only for habits)",
                "$ref": "#/definitions/HabitSummary",
            },
        },
        "required": ["title", "isWindowHabit"],
    },
    "HabitSummary": {
        "description": "Summary of habit tracking status",
        "type": "object",
        "properties": {
            "conformingRatio": {
                "description": "Ratio of conforming days (0.0 to 1.0)",
                "type": "number",
                "minimum": 0,
                "maximum": 1,
            },
            "completionNeededToday": {
                "description": "Whether completion is needed today",
                "type": "boolean",
            },
            "streakDays": {
                "description": "Current streak length in days",
                "type": "integer",
                "minimum": 0,
            },
            "completionsInWindow": {
                "description": "Number of completions in current window",
                "type": "integer",
                "minimum": 0,
            },
            "windowSize": {
                "description": "Size of the habit window in days",
                "type": "integer",
                "minimum": 1,
            },
            "minRequired": {
                "description": "Minimum completions required in window",
                "type": "integer",
                "minimum": 0,
            },
            "maxAllowed": {
                "description": "Maximum completions allowed in window",
                "type": "integer",
                "minimum": 0,
            },
        },
        "required": ["conformingRatio", "completionNeededToday"],
    },
    "CaptureTemplate": {
        "description": "A capture template definition",
        "type": "object",
        "properties": {
            "key": {
                "description": "Template key for API use",
                "type": "string",
            },
            "name": {
                "description": "Human-readable template name",
                "type": "string",
            },
            "prompts": {
                "description": "List of prompts for template values",
                "type": "array",
                "items": {"$ref": "#/definitions/CapturePrompt"},
            },
        },
        "required": ["key", "name", "prompts"],
    },
    "CapturePrompt": {
        "description": "A prompt for capture template input",
        "type": "object",
        "properties": {
            "name": {
                "description": "Prompt name (used as key in values)",
                "type": "string",
            },
            "type": {
                "description": "Input type",
                "type": "string",
                "enum": ["string", "date", "tags", "priority"],
            },
            "required": {
                "description": "Whether this prompt is required",
                "type": "boolean",
            },
        },
        "required": ["name", "type", "required"],
    },
    "GitRefreshResult": {
        "description": "Result of git pull on a repository",
        "type": "object",
        "properties": {
            "repo": {
                "description": "Repository path",
                "type": "string",
            },
            "status": {
                "description": "Operation status",
                "type": "string",
                "enum": ["success", "error"],
            },
            "output": {
                "description": "Git command output (on success)",
                "type": "string",
            },
            "message": {
                "description": "Error message (on error)",
                "type": "string",
            },
        },
        "required": ["repo", "status"],
    },
    "ErrorResponse": {
        "description": "Standard error response",
        "type": "object",
        "properties": {
            "status": {
                "const": "error",
            },
            "message": {
                "description": "Error message",
                "type": "string",
            },
            "code": {
                "description": "Error code (for structured error handling)",
                "type": "string",
            },
        },
        "required": ["status", "message"],
    },
    "CustomView": {
        "description": "A custom agenda view definition",
        "type": "object",
        "properties": {
            "key": {
                "description": "View key",
                "type": "string",
            },
            "name": {
                "description": "View name/description",
                "type": "string",
            },
            "type": {
                "description": "View type",
                "type": "string",
            },
        },
        "required": ["key"],
    },
}
