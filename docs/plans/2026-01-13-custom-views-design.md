# Custom Agenda Views API Design

## Overview

Add support for running custom agenda views (defined in `org-agenda-custom-commands`) via the HTTP API.

## Endpoints

### GET /custom-views

Lists all available custom agenda commands.

**Response:**
```json
{
  "views": [
    {"key": "r", "name": "Recently created"},
    {"key": "A", "name": "High priority"},
    {"key": "M", "name": "Main agenda view"}
  ]
}
```

### GET /custom-view?key=r

Runs a specific custom agenda command and returns the entries.

**Parameters:**
- `key` (required): The single-character key from `org-agenda-custom-commands`
- `refresh` (optional): If "true" or "1", git pull repos first

**Response:**
```json
{
  "key": "r",
  "name": "Recently created",
  "entries": [
    {
      "todo": "TODO",
      "title": "Some task",
      "tags": ["tag1"],
      "level": 1,
      "scheduled": "2024-01-15",
      "deadline": null,
      "file": "/path/to/file.org",
      "pos": 1234,
      "id": "org-id-here",
      "olpath": ["Parent"],
      "priority": "B",
      "notifyBefore": [30, 5],
      "agendaLine": "  TODO Some task :tag1:"
    }
  ]
}
```

## Implementation

### New Functions

1. **`org-agenda-api--list-custom-views`**: Parse `org-agenda-custom-commands` to extract key and name for each view.

2. **`org-agenda-api--run-custom-view (key)`**: Run `(org-agenda nil key)` and extract entries from the resulting `*Org Agenda*` buffer using the existing `org-agenda-api--extract-entry-data` function.

### Entry Extraction

Reuses existing `org-agenda-api--extract-entry-data` which extracts:
- todo state, title, tags, level
- scheduled/deadline with time detection
- file path, position, org ID
- outline path, priority
- notification settings

Composite views (like "M" which combines agenda + todo lists) will simply return all entries from all sections flattened together.
