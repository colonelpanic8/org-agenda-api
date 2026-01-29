# Habit Integration for Multi-Day Agenda - WIP

## Current State

The basic multi-day agenda is implemented and working (tests pass). Now integrating habits to appear only on their required dates using `org-window-habit-get-future-required-intervals`.

## What's Done

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

## What Needs to Be Done

1. **Fix and test the implementation**:
   - Run `nix develop -c pytest tests/test_agenda.py::TestMultiDayAgenda tests/test_agenda.py::TestMultiDayAgendaHabits -v`
   - Debug any remaining errors
   - The last error was `void-function org-agenda-api--priority-to-letter` - FIXED (changed to use `org-entry-get`)

2. **Handle past dates**:
   - Current implementation uses `org-window-habit-get-future-required-intervals` which is for future dates
   - For past dates relative to `today`, we need different logic:
     - Walk backwards through assessment windows
     - Determine which days required completion based on done-times
   - May need a new function in org-window-habit or custom logic here

3. **Test edge cases**:
   - Habits with no completions
   - Habits with `only-days` restrictions
   - Multiple window specs
   - Date ranges spanning past and future relative to `today`

4. **Run full test suite** to ensure no regressions

## To Continue

```bash
cd /home/imalison/dotfiles/dotfiles/emacs.d/straight/repos/org-agenda-api
git checkout wip/habit-multiday-integration

# Run tests
nix develop -c pytest tests/test_agenda.py::TestMultiDayAgenda tests/test_agenda.py::TestMultiDayAgendaHabits -v

# Debug errors, iterate until tests pass
# Then run full suite:
nix develop -c pytest tests/ -v
```

## Key Files

- `org-agenda-api-data.el` - Multi-day response builder
- `org-agenda-api-window-habit.el` - Habit integration functions
- `tests/test_agenda.py` - Tests (TestMultiDayAgenda, TestMultiDayAgendaHabits classes)
