# Habit Integration for Multi-Day Agenda - COMPLETED

## Summary

The habit integration for multi-day agenda is now complete. Habits appear only on
dates where completion is required, using `org-window-habit-get-future-required-intervals`
for prospective scheduling.

## What Was Implemented

1. **Multi-day response builder** (`org-agenda-api-data.el`):
   - `org-agenda-api--build-multi-day-response` updated to:
     - Collect habits separately via `org-agenda-api--collect-habits-for-date-range`
     - Filter habits out of regular agenda entries
     - Merge habit entries on their required dates only
   - Helper functions added:
     - `org-agenda-api--entry-is-window-habit-p`
     - `org-agenda-api--merge-habit-entries`

2. **Window habit integration** (`org-agenda-api-window-habit.el`):
   - Added `require 'org-agenda-api-data` for date utilities
   - New functions:
     - `org-agenda-api--get-habit-required-dates-in-range` - uses `org-window-habit-get-future-required-intervals`
     - `org-agenda-api--date-string-to-time` - helper for date conversion
     - `org-agenda-api--get-habit-entry-for-date` - creates entry for a habit on specific date
     - `org-agenda-api--collect-habits-for-date-range` - main function to collect all habits

3. **Test coverage** (`tests/test_agenda.py`):
   - `TestMultiDayAgendaHabits` class with tests for:
     - Habits appearing on required dates with `dateRelevance: "habit_required"`
     - `habitCompletedOnQueryDate` field for completion tracking

## Test Results

All 366 tests pass, with 7 skipped (unrelated to this feature).

## Key Files

- `org-agenda-api-data.el` - Multi-day response builder
- `org-agenda-api-window-habit.el` - Habit integration functions
- `tests/test_agenda.py` - Tests (TestMultiDayAgenda, TestMultiDayAgendaHabits classes)
