# Completed Todos in Agenda View

## Overview

Add support for showing completed todos at their completion times in the `/agenda` endpoint, using org-mode's native log mode functionality.

## Motivation

In Emacs org-agenda, pressing "l" toggles log mode which shows completed items at their completion time. This feature brings that capability to the API, allowing mobile clients (like Mova) to optionally display what was completed on a given day.

## API Changes

### Request

New query parameter on `/agenda`:

```
GET /agenda?date=2024-06-15&include_completed=true
```

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `include_completed` | boolean | false | Include items completed on this date |

### Response

Completed items appear in the `entries` array alongside scheduled/deadline items:

```json
{
  "span": "day",
  "date": "2024-06-15",
  "entries": [
    {
      "todo": "TODO",
      "title": "Morning meeting",
      "scheduled": "2024-06-15T09:00:00",
      "deadline": null,
      "completedAt": null,
      ...
    },
    {
      "todo": "DONE",
      "title": "Review PR",
      "scheduled": null,
      "deadline": null,
      "completedAt": "2024-06-15T14:30:00",
      ...
    }
  ]
}
```

**New field:** `completedAt` - ISO timestamp of completion (null for non-completed items)

## Implementation

### Approach

Use org-mode's built-in log mode support rather than custom LOGBOOK parsing:

```elisp
(let ((org-agenda-show-log (when include-completed t))
      (org-agenda-log-mode-items '(closed state)))
  (org-agenda-list nil start-date span-days))
```

This leverages org-mode's existing, well-tested functionality for:
- Parsing LOGBOOK state change entries
- Parsing CLOSED timestamps
- Displaying items at their completion time in the agenda

### Changes to `org-agenda-api.el`

1. **Parse new query parameter** in `/agenda` endpoint:
   ```elisp
   (include-completed-param (cadr (assoc "include_completed" query)))
   (include-completed (member include-completed-param '("true" "1")))
   ```

2. **Let-bind log mode variables** in `org-agenda-api--run-agenda`:
   ```elisp
   (let ((org-agenda-show-log include-completed)
         (org-agenda-log-mode-items '(closed state)))
     ;; existing org-agenda-list call
     )
   ```

3. **Extract completion timestamp** from agenda entries that have one, add as `completedAt` field

### Prerequisites

The test Emacs configuration (`scripts/run-emacs-server.el`) already has:
- `org-log-into-drawer t` - enables LOGBOOK drawer
- TODO keywords with `!` markers - logs timestamps on state changes

## Testing

### Test Cases

1. **Basic completion visibility**
   - Complete a task on date X
   - Query agenda for date X with `include_completed=true`
   - Assert: completed task appears in entries

2. **Default behavior unchanged**
   - Complete a task on date X
   - Query agenda for date X WITHOUT `include_completed`
   - Assert: completed task does NOT appear

3. **Date filtering works**
   - Complete task on June 15
   - Query agenda for June 16 with `include_completed=true`
   - Assert: task does NOT appear (wrong date)

4. **Multiple completions same day**
   - Complete 3 tasks on same date
   - Query with `include_completed=true`
   - Assert: all 3 appear

5. **Completion time preserved**
   - Complete task at 14:30
   - Assert: `completedAt` field shows `T14:30:00`

6. **Re-opened tasks excluded**
   - Complete task (DONE)
   - Re-open task (back to TODO)
   - Query with `include_completed=true`
   - Assert: task does NOT appear as completed

### Test Implementation

Tests will:
1. Create tasks via `/capture` or `/create-todo`
2. Complete them via `/complete` endpoint (which creates LOGBOOK entries)
3. Query `/agenda` with `include_completed=true`
4. Verify completed items appear with correct `completedAt` timestamps

## Future Considerations

- Mova frontend will add a toggle in the agenda view to enable/disable showing completed items
- Could extend to support `org-agenda-log-mode-items` as a parameter for finer control (clock entries, etc.)
