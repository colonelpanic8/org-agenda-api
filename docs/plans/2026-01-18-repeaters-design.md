# Repeater Support Design

## Overview

Add support for org-mode repeaters in org-agenda-api and mova. This enables recurring task management from the mobile app.

## Data Model

New fields in Todo interface:

```typescript
interface Todo {
  // ... existing fields ...
  scheduledRepeater: Repeater | null;
  deadlineRepeater: Repeater | null;
}

interface Repeater {
  type: '+' | '++' | '.+';  // cumulative, catch-up, restart
  value: number;            // e.g., 1, 2, 3
  unit: 'd' | 'w' | 'm' | 'y';  // day, week, month, year
}
```

Separate repeaters for scheduled and deadline since org-mode allows repeaters on either or both timestamps.

Example org-mode entry:
```org
* TODO Weekly review
  SCHEDULED: <2026-01-20 Mon +1w>
```

Parses to:
```json
{
  "scheduled": "2026-01-20",
  "scheduledRepeater": {"type": "+", "value": 1, "unit": "w"}
}
```

## Repeater Types

- `+` (cumulative): Next occurrence on fixed schedule from original date
- `++` (catch-up): Shift forward from today to next valid occurrence
- `.+` (restart): Shift forward from completion date

## API Changes (org-agenda-api.el)

### Parsing

Add function to extract repeater info from org timestamps:

```elisp
(defun org-agenda-api--get-repeater (timestamp-string)
  "Extract repeater from timestamp like '<2026-01-20 Mon +1w>'.
Returns plist (:type \"+\" :value 1 :unit \"w\") or nil."
  ...)
```

Modify `org-agenda-api--get-planning-info` to call this and include repeaters in output.

### /get-all-todos Response

Each todo includes `scheduledRepeater` and `deadlineRepeater` fields (null if no repeater).

### /update Endpoint

Accept optional `scheduledRepeater` and `deadlineRepeater` in POST body:
- If repeater provided with date, format as `<2026-01-20 Mon +1w>`
- If repeater is null but date exists, strip any existing repeater
- Use `org-schedule` / `org-deadline` functions for formatting

### /complete Endpoint

No special changes needed. Org-mode's `org-todo` automatically:
1. Logs completion to LOGBOOK
2. Advances timestamp to next occurrence
3. Resets TODO state

Response should include the updated todo with new scheduled date so mova can refresh.

## Mova UI Changes

### Display

Show repeat icon next to tasks with repeaters. Tapping reveals pattern in human-readable form ("Repeats weekly", "Every 2 days").

### Editing

In todo edit screen, add "Repeat" section below each date picker:

```
Scheduled: [Jan 20, 2026]  [10:00 AM]
Repeat:    [None]

-- when expanded --

Repeat:    [Cumulative (+)]
Every:     [1] [week]
```

Type dropdown options:
- None (no repeater)
- Cumulative (+) - next occurrence on fixed schedule
- Catch-up (++) - shift forward from today
- Restart (.+) - shift forward from completion

Unit dropdown: day, week, month, year

Value: number input (1-99)

### Completion UX

When completing a repeating task, show feedback: "Rescheduled to Jan 27" rather than just "Completed".

## Implementation Scope

### org-agenda-api.el
1. Add `org-agenda-api--get-repeater` function
2. Modify `org-agenda-api--get-planning-info` to extract repeaters
3. Update todo JSON output with repeater fields
4. Modify `/update` handler to accept repeater changes
5. Ensure `/complete` response includes updated scheduled date

### mova
1. Update `Todo` TypeScript interface
2. Add `Repeater` type definition
3. Create `RepeaterPicker` component
4. Update todo edit screen with repeater pickers
5. Add repeat icon to todo list items
6. Update completion feedback for repeating tasks

### Tests
- Unit tests for repeater parsing in org-agenda-api
- Integration tests for update/complete with repeaters
- Component tests for RepeaterPicker in mova
