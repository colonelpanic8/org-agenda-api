# org-window-habit Integration Design

**Date:** 2026-01-20
**Status:** Draft

## Overview

Integrate org-window-habit with org-agenda-api to expose habit status, graph data, and completion tracking via HTTP endpoints.

## Goals

1. **Habit status endpoint** - Query current status of window-habits (conforming ratio, next due date, completion history)
2. **Habit graph data** - Expose semantic graph data as JSON for frontend visualization
3. **Habit completion tracking** - Existing `/complete` endpoint triggers org-window-habit rescheduling

## Data Model

When an entry is identified as an org-window-habit, structured habit data is included:

```json
{
  "isWindowHabit": true,
  "habit": {
    "assessmentInterval": {"days": 1},
    "rescheduleInterval": {"days": 1},
    "rescheduleThreshold": 1.0,
    "maxRepetitionsPerInterval": 1,
    "startTime": "2025-01-01T00:00:00",
    "windowSpecs": [
      {
        "duration": {"days": 7},
        "targetRepetitions": 5,
        "conformingValue": 1.0
      }
    ]
  }
}
```

Duration/interval plists from Emacs (`:days 7`) become JSON objects (`{"days": 7}`), preserving structure for months, years, hours, etc.

**Detection logic:** An entry is a window-habit if:
- `org-window-habit-mode` is enabled, AND
- The entry has the `OWH_ASSESSMENT_INTERVAL` property OR `OWH_WINDOW_SPECS` property

## New Endpoint: `/habit-status`

### Request

```
GET /habit-status?id=<org-id>&preceding=14&following=7
```

**Query parameters:**
| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `id` | Yes | - | org-id of the habit entry |
| `preceding` | No | 21 | Number of intervals to show before today |
| `following` | No | 4 | Number of intervals to show after today |

### Response

```json
{
  "status": "ok",
  "id": "abc-123",
  "title": "Exercise",
  "habit": {
    "assessmentInterval": {"days": 1},
    "rescheduleInterval": {"days": 1},
    "rescheduleThreshold": 1.0,
    "maxRepetitionsPerInterval": 1,
    "startTime": "2025-01-01T00:00:00",
    "windowSpecs": [
      {
        "duration": {"days": 7},
        "targetRepetitions": 5,
        "conformingValue": 1.0
      }
    ]
  },
  "currentState": {
    "conformingRatio": 0.8,
    "completionsInWindow": 4,
    "targetRepetitions": 5,
    "windowStart": "2025-01-14",
    "windowEnd": "2025-01-21",
    "nextRequiredInterval": "2025-01-19",
    "completionNeededToday": true
  },
  "doneTimes": ["2025-01-20T10:30:00", "2025-01-18T09:00:00"],
  "graph": [
    {
      "date": "2025-01-06",
      "assessmentStart": "2025-01-06T00:00:00",
      "assessmentEnd": "2025-01-07T00:00:00",
      "conformingRatioWithout": 0.6,
      "conformingRatioWith": 0.8,
      "completionCount": 1,
      "status": "past",
      "completionExpectedToday": false
    }
  ]
}
```

The `conformingRatioWithout` and `conformingRatioWith` fields show the impact of completing on a given day - useful for visualizing "what if I complete today" vs "if I don't".

## Modifications to Existing Endpoints

### `/get-all-todos` and `/agenda`

Each entry gains two new fields when `org-window-habit-mode` is enabled:

```json
{
  "todo": "TODO",
  "title": "Exercise",
  "scheduled": "2025-01-20",

  "isWindowHabit": true,
  "habitSummary": {
    "conformingRatio": 0.8,
    "completionNeededToday": true,
    "nextRequiredInterval": "2025-01-20",
    "completionsInWindow": 4,
    "targetRepetitions": 5
  }
}
```

When `isWindowHabit` is false or the entry isn't a habit, `habitSummary` is omitted.

**Rationale:** These endpoints return many entries. Including full graph data for each habit would bloat the response. Clients call `/habit-status?id=...` for detailed data on specific habits.

### `/complete`

Response includes `habitSummary` when completing a window-habit:

```json
{
  "status": "completed",
  "title": "Exercise",
  "oldState": "TODO",
  "newState": "DONE",
  "habitSummary": {
    "conformingRatio": 1.0,
    "completionNeededToday": false,
    "nextRequiredInterval": "2025-01-22",
    "completionsInWindow": 5,
    "targetRepetitions": 5
  }
}
```

This avoids requiring a follow-up `/habit-status` call after completion.

## Completion Flow

The existing `/complete` endpoint triggers org-window-habit's rescheduling:

```
POST /complete  (with id or file+pos)
    |
    v
org-agenda-api--complete-todo-at
    |
    v
(org-todo "DONE")
    |
    v
org-auto-repeat-maybe  [if entry has repeater]
    |
    v
org-window-habit-auto-repeat-maybe-advice  [if org-window-habit-mode]
    |
    v
org-window-habit-auto-repeat
    |
    v
- Calculates next required interval
- Updates DEADLINE (if org-window-habit-repeat-to-deadline)
- Updates SCHEDULED (if org-window-habit-repeat-to-scheduled)
```

## Implementation Approach

### Detection Function

```elisp
(defun org-agenda-api--is-window-habit-p ()
  "Return non-nil if entry at point is an org-window-habit."
  (and (bound-and-true-p org-window-habit-mode)
       (or (org-entry-get nil (org-window-habit-property "ASSESSMENT_INTERVAL") t)
           (org-entry-get nil (org-window-habit-property "WINDOW_SPECS") t))))
```

### Data Extraction

Reuse org-window-habit's existing functions:
- `org-window-habit-create-instance-from-heading-at-point` - creates the habit instance
- `org-window-habit-get-next-required-interval` - next due date
- `org-window-habit-iterator-from-time` / `org-window-habit-conforming-ratio` - current status
- `org-window-habit-build-graph` - adapt to return semantic data

### New Helper

Create `org-agenda-api--build-habit-graph-data` that uses the same iterator logic as `org-window-habit-build-graph` but collects structured data instead of glyph/face pairs.

### Dependency

org-agenda-api will have org-window-habit as an optional dependency. Habit features only activate when `org-window-habit-mode` is enabled.

## Error Handling

### `/habit-status` Errors

| Condition | Response |
|-----------|----------|
| Entry not found | `{"status": "error", "message": "Entry not found"}` |
| Entry exists but isn't a window-habit | `{"status": "error", "message": "Entry is not an org-window-habit"}` |
| `org-window-habit-mode` not enabled | `{"status": "error", "message": "org-window-habit-mode is not enabled"}` |

### Edge Cases

- **No completions yet:** Return `conformingRatio: 0`, empty `doneTimes`, graph shows expected intervals
- **Habit created today:** `startTime` is today, graph shows limited history
- **Multiple window specs:** `conformingRatio` in summary uses aggregation function result (typically minimum), `/habit-status` exposes all window specs

### Graceful Degradation

- If org-window-habit is not loaded/available, `isWindowHabit` is always `false`
- If parsing a specific habit fails, log error and omit `habitSummary` for that entry (don't fail whole request)

## Files to Modify

- `org-agenda-api.el` - Add new endpoint and modify existing ones

## Files to Add

None - all changes contained in org-agenda-api.el
