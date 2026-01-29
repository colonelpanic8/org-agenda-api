# Multi-Day Agenda View Design

## Overview

Add the ability to view agenda data for multiple days (week or custom range) through the `/agenda` endpoint, supporting both planning (future) and retrospective (past) use cases.

## Requirements

1. View agenda for a date range (week, custom range)
2. Response grouped by day
3. Backwards compatible - `span=day` returns existing flat format
4. Configurable overdue item behavior
5. Habits appear only on days where completion is required
6. Completed items appear on their completion date
7. Custom "today" parameter for overdue calculations

## API Changes

### Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `start_date` | string (YYYY-MM-DD) | `date` or today | Start of range |
| `end_date` | string (YYYY-MM-DD) | computed from span | End of range (inclusive) |
| `span` | string | `day` | `day`, `week`, or `custom` (when end_date provided) |
| `today` | string (YYYY-MM-DD) | actual today | Date to treat as "today" for overdue calculations |
| `overdue_behavior` | string | `original` | `original`, `today`, or `both` |
| `include_completed` | boolean | false | Include completed items on their completion date |

### Response Format

**Single day (backwards compatible):**
```json
{
  "span": "day",
  "date": "2024-01-15",
  "entries": [...]
}
```

**Multi-day:**
```json
{
  "span": "week",
  "startDate": "2024-01-15",
  "endDate": "2024-01-21",
  "today": "2024-01-17",
  "days": {
    "2024-01-15": [...],
    "2024-01-16": [...],
    "2024-01-17": [...],
    "2024-01-18": [...],
    "2024-01-19": [...],
    "2024-01-20": [...],
    "2024-01-21": [...]
  }
}
```

### Entry Fields

Each entry includes all existing fields plus:

- `dateRelevance` (string): Why entry appears on this day
  - `scheduled` - Item scheduled for this day
  - `deadline` - Item has deadline on this day
  - `overdue` - Item is overdue (appears due to `overdue_behavior`)
  - `habit_required` - Habit requires completion on this day
  - `completed` - Item was completed on this day

For habits:
- `habitCompletedOnDate` (boolean): Whether habit was completed on this specific day (based on LOGBOOK)

## Implementation Approach

### Regular Items

1. For each day in range, determine which items are relevant:
   - Scheduled on that day
   - Deadline on that day
   - Overdue (based on `overdue_behavior` and `today` parameter)
   - Completed on that day (if `include_completed`, based on CLOSED timestamp)

2. Deduplicate within each day (item with both scheduled and deadline on same day)

### Habits (Computed Separately)

1. Get all window habits from agenda files
2. For future dates relative to `today`:
   - Use `org-window-habit-get-future-required-intervals` to compute required dates
   - Place habit on each required date within the range
3. For past dates relative to `today`:
   - Check LOGBOOK for actual completions
   - Determine which days required completion (walk backwards through assessment windows)
   - Show habit on required dates with `habitCompletedOnDate` indicating if met
4. For each habit instance, include:
   - Full habit data
   - `dateRelevance: "habit_required"`
   - `habitCompletedOnDate`: boolean

### Overdue Behavior

Given `today` parameter and `overdue_behavior`:

- `original`: Item appears only on its scheduled/deadline date
- `today`: Item appears only on `today` (if past its date and not done)
- `both`: Item appears on both original date and `today`

When `overdue_behavior` is `today` or `both`, entries appearing on `today` due to being overdue get `dateRelevance: "overdue"`.

## Edge Cases

1. **Item spans multiple days** (date range): Appears on start date only, or each day?
   - Decision: Appears on start date only (consistent with current behavior)

2. **Habit with no completions**: Use `org-window-habit-get-future-required-intervals` which handles this case

3. **Date range crosses DST**: Use calendar arithmetic, not seconds

4. **Empty days**: Include in response with empty array

## Testing

1. Single day request returns backwards-compatible format
2. Week request returns grouped format with 7 days
3. Custom range with `end_date`
4. Overdue behavior: original, today, both
5. Habits appear on required dates only
6. Habit completion status correct per day
7. Completed items on completion date
8. Custom `today` parameter affects overdue calculations
9. Empty days included in response
