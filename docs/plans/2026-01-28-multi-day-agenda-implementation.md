# Multi-Day Agenda Implementation Plan

## Phase 1: Parameter Handling & Response Structure

1. Update `org-agenda-api-agenda` endpoint to parse new parameters:
   - `start_date` (alias/default from `date`)
   - `end_date`
   - `today`
   - `overdue_behavior`

2. Add date range computation logic:
   - `span=day`: single day (backwards compat)
   - `span=week`: 7 days from start_date
   - `end_date` provided: custom range

3. Modify response builder:
   - Single day: return existing `entries` format
   - Multi-day: return `days` object with date keys

## Phase 2: Multi-Day Regular Item Collection

1. Create `org-agenda-api--collect-entries-for-date-range`:
   - Loop through each date in range
   - Call existing `org-agenda-api--run-agenda` for each day
   - Collect entries with their source date

2. Add `dateRelevance` field to entries:
   - Track why entry appears on each day
   - Values: scheduled, deadline, overdue, completed

3. Implement overdue behavior:
   - Calculate overdue status relative to `today` param
   - Place entries according to `overdue_behavior`

## Phase 3: Habit Integration

1. Create `org-agenda-api--collect-habits-for-date-range`:
   - Get all window habits
   - Separate from regular agenda processing

2. For future dates (relative to `today`):
   - Call `org-window-habit-get-future-required-intervals`
   - Filter to dates within range
   - Create entry for each required date

3. For past dates (relative to `today`):
   - Parse LOGBOOK for completion dates
   - Determine required dates by walking assessment windows
   - Mark `habitCompletedOnDate` based on LOGBOOK

4. Merge habit entries into appropriate days

## Phase 4: Completed Items

1. Query items with CLOSED timestamp in date range
2. Parse CLOSED timestamp to determine completion date
3. Add to appropriate day with `dateRelevance: "completed"`
4. Include full item data

## Phase 5: Testing

1. Backwards compatibility test (span=day)
2. Week span test
3. Custom date range test
4. Overdue behavior tests (original/today/both)
5. Habit required dates test
6. Habit completion status test
7. Completed items placement test
8. Custom today parameter test
9. Empty days in response test
10. Edge case: range with no items

## File Changes

- `org-agenda-api-endpoints.el`: Parameter handling, endpoint logic
- `org-agenda-api-data.el`: Date range collection, habit processing
- `test_agenda.py`: New tests for multi-day functionality
