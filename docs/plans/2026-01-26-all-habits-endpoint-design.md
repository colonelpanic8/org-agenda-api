# All-Habits Endpoint Design

## Overview

Add an endpoint that returns detailed status for all habits at once, using the same data format as the existing single-habit `/habit-status` endpoint.

## Endpoint

**Route:** `GET /all-habit-statuses`

**Query Parameters (all optional):**
- `preceding` - intervals before reference date (default: 21)
- `following` - intervals after reference date (default: 4)
- `date` - reference date as YYYY-MM-DD (default: today)

## Response Structure

```json
{
  "status": "ok",
  "habits": [
    {
      "id": "habit-exercise-daily",
      "title": "Exercise daily",
      "habit": { /* habit configuration */ },
      "currentState": { /* current state */ },
      "doneTimes": [ /* completion timestamps */ ],
      "graph": [ /* graph data points */ ]
    },
    {
      "id": "habit-with-error",
      "error": "Failed to parse habit properties: ..."
    }
  ]
}
```

## Error Handling

Habits that fail to parse return an entry with `id` and `error` fields instead of full data. The endpoint does not fail entirely if individual habits have issues.

## Implementation

- Location: `org-agenda-api-window-habit.el`
- Reuse existing `org-agenda-api--get-habit-status-data` function
- Scan agenda files for entries where `org-window-habit-entry-p` returns true
- Wrap each habit status call in error handling

## Tests

- Verify endpoint returns all habits from fixtures
- Confirm error handling for malformed habits
- Check query parameters apply to all habits
