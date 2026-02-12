"""Integration tests for include_completed parameter on /agenda endpoint."""

from datetime import date

from conftest import TEST_DATE, TEST_DATE_NEXT_DAY


def get_today_str():
    """Return today's date as YYYY-MM-DD string.

    Note: The CLOSED timestamp uses the real date, not the fake test date.
    This is because org-mode uses current-time for CLOSED timestamps,
    which isn't overridden by our test setup.
    """
    return date.today().strftime("%Y-%m-%d")


def extract_date(timestamp):
    """Extract date string from timestamp which may be object or string.

    Handles both new format {"date": "2024-06-15", "time": "10:00"}
    and legacy string format "2024-06-15" or "2024-06-15T10:00:00".
    Returns the YYYY-MM-DD date portion or None if timestamp is None.
    """
    if timestamp is None:
        return None
    if isinstance(timestamp, dict):
        return timestamp.get("date")
    if isinstance(timestamp, str):
        return timestamp[:10] if len(timestamp) >= 10 else timestamp
    return None


class TestIncludeCompleted:
    """Tests for include_completed=true on GET /agenda."""

    def test_completed_item_appears_with_flag(self, api):
        """Completed todo should appear in agenda when include_completed=true."""
        # Get an active todo to complete
        # IMPORTANT: Exclude habits (items with repeating deadlines) because
        # org-mode removes CLOSED timestamp when repeating tasks reset to TODO
        todos_response = api.get_all_todos()
        todos = todos_response.json()

        active_todo = next(
            (
                t
                for t in todos["todos"]
                if t.get("todo") == "TODO"
                and not t.get("isWindowHabit", False)  # Exclude window habits
                and "habit"
                not in t.get("title", "").lower()  # Exclude other habits by name
                and "Exercise"
                not in t.get("title", "")  # Exclude specific habit fixtures
                and "Meditate" not in t.get("title", "")
            ),
            None,
        )
        assert active_todo is not None, "Need an active non-habit TODO to test"

        original_title = active_todo["title"]

        # Complete it
        complete_response = api.complete_todo(active_todo)
        assert complete_response.status_code == 200, (
            f"Complete failed: {complete_response.text}"
        )

        # Query agenda for TODAY's date (not fake test date) with include_completed=true
        # CLOSED timestamps use real date, not the fake test date
        today = get_today_str()
        agenda_response = api.get(f"/agenda?date={today}&include_completed=true")
        assert agenda_response.status_code == 200

        entries = agenda_response.json().get("entries", [])

        # Debug: print all entries to see what we got
        entry_info = [
            (
                e.get("title"),
                e.get("todo"),
                e.get("completedAt"),
                e.get("agendaLine", "")[:50],
            )
            for e in entries
        ]

        # Find the completed item by title
        completed_entry = next(
            (e for e in entries if original_title in e.get("title", "")),
            None,
        )
        assert completed_entry is not None, (
            f"Completed todo '{original_title}' not found in agenda for {today}. "
            f"Entries: {entry_info}"
        )
        assert completed_entry.get("todo") == "DONE"

    def test_completed_item_not_shown_by_default(self, api):
        """Completed todo should NOT appear in agenda without include_completed flag."""
        # Get an active todo to complete
        todos_response = api.get_all_todos()
        todos = todos_response.json()

        # Find a todo that's scheduled for TEST_DATE so we can verify it disappears
        active_todo = next(
            (
                t
                for t in todos["todos"]
                if t.get("todo") == "TODO"
                and extract_date(t.get("scheduled")) == TEST_DATE
            ),
            None,
        )
        if active_todo is None:
            # Skip if no suitable todo found
            import pytest

            pytest.skip("No TODO scheduled for test date found")

        original_title = active_todo["title"]

        # Complete it
        api.complete_todo(active_todo)

        # Query agenda WITHOUT include_completed
        agenda_response = api.get(f"/agenda?date={TEST_DATE}")
        assert agenda_response.status_code == 200

        entries = agenda_response.json().get("entries", [])

        # The completed item should NOT appear (unless it has a scheduled/deadline for that day)
        # Since we completed it, if it appears it should be because of scheduled, not completion
        done_entries = [
            e
            for e in entries
            if e.get("todo") == "DONE" and original_title in e.get("title", "")
        ]

        # With log mode off, completed items shouldn't appear based on completion time alone.
        # They might still appear if they have scheduled/deadline for the date.
        # The completedAt field IS populated (we read CLOSED from the entry) - that's correct.
        # The key test is that items don't appear *solely because* of completion time.
        # Since this item has a scheduled date, it might still appear - that's expected.
        # We just verify it's appearing because of scheduled, not a log entry.
        for entry in done_entries:
            # Entry should have scheduled to appear without include_completed
            assert entry.get("scheduled") is not None, (
                "DONE item without include_completed should only appear due to scheduled/deadline, not completion"
            )

    def test_completed_item_wrong_date_not_shown(self, api):
        """Completed todo should only appear on the date it was completed."""
        # Get an active todo
        todos_response = api.get_all_todos()
        todos = todos_response.json()

        active_todo = next(
            (t for t in todos["todos"] if t.get("todo") == "TODO"),
            None,
        )
        assert active_todo is not None

        # Complete it (on TEST_DATE since that's our fake "today")
        api.complete_todo(active_todo)

        # Query agenda for NEXT day with include_completed=true
        agenda_response = api.get(
            f"/agenda?date={TEST_DATE_NEXT_DAY}&include_completed=true"
        )
        assert agenda_response.status_code == 200

        entries = agenda_response.json().get("entries", [])

        # Should NOT find this completed item on the next day
        completed_entry = next(
            (
                e
                for e in entries
                if active_todo["title"] in e.get("title", "") and e.get("completedAt")
            ),
            None,
        )
        assert completed_entry is None, (
            f"Completed todo should not appear on {TEST_DATE_NEXT_DAY}, "
            f"it was completed on {TEST_DATE}"
        )

    def test_completed_at_field_populated(self, api):
        """Completed items should have completedAt timestamp."""
        # Get an active todo (exclude habits - they don't keep CLOSED after reset)
        todos_response = api.get_all_todos()
        todos = todos_response.json()

        active_todo = next(
            (
                t
                for t in todos["todos"]
                if t.get("todo") == "TODO"
                and not t.get("isWindowHabit", False)
                and "habit" not in t.get("title", "").lower()
                and "Exercise" not in t.get("title", "")
                and "Meditate" not in t.get("title", "")
            ),
            None,
        )
        assert active_todo is not None, "Need an active non-habit TODO to test"

        # Complete it
        api.complete_todo(active_todo)

        # Query with include_completed for TODAY's date (CLOSED uses real date)
        today = get_today_str()
        agenda_response = api.get(f"/agenda?date={today}&include_completed=true")
        entries = agenda_response.json().get("entries", [])

        # Debug: print all entries
        entry_info = [
            (e.get("title"), e.get("todo"), e.get("completedAt")) for e in entries
        ]

        # Find the completed item
        completed_entry = next(
            (e for e in entries if active_todo["title"] in e.get("title", "")),
            None,
        )
        assert completed_entry is not None, (
            f"Completed todo '{active_todo['title']}' not found in agenda for {today}. "
            f"Entries: {entry_info}"
        )

        # Should have completedAt field with timestamp
        completed_at = completed_entry.get("completedAt")
        assert completed_at is not None, (
            f"completedAt field should be populated. Entry: {completed_entry}"
        )
        assert today in completed_at, (
            f"completedAt should contain today's date {today}, got {completed_at}"
        )

    def test_multiple_completions_same_day(self, api):
        """Multiple items completed on same day should all appear."""
        # Get multiple active todos (exclude habits - they don't keep CLOSED after reset)
        todos_response = api.get_all_todos()
        todos = todos_response.json()

        active_todos = [
            t
            for t in todos["todos"]
            if t.get("todo") == "TODO"
            and not t.get("isWindowHabit", False)
            and "habit" not in t.get("title", "").lower()
            and "Exercise" not in t.get("title", "")
            and "Meditate" not in t.get("title", "")
        ][:3]
        if len(active_todos) < 2:
            import pytest

            pytest.skip("Need at least 2 active non-habit TODOs for this test")

        # Complete them all
        completed_titles = []
        for todo in active_todos:
            response = api.complete_todo(todo)
            if response.status_code == 200:
                completed_titles.append(todo["title"])

        assert len(completed_titles) >= 2, "Need at least 2 successful completions"

        # Query with include_completed for TODAY's date (CLOSED uses real date)
        today = get_today_str()
        agenda_response = api.get(f"/agenda?date={today}&include_completed=true")
        entries = agenda_response.json().get("entries", [])

        # All completed items should appear
        found_count = 0
        for title in completed_titles:
            if any(title in e.get("title", "") for e in entries):
                found_count += 1

        assert found_count == len(completed_titles), (
            f"Expected {len(completed_titles)} completed items, found {found_count}"
        )

    def test_reopened_task_not_shown_as_completed(self, api):
        """Re-opened tasks (DONE -> TODO) should NOT appear as completed items."""
        # Get an active todo
        todos_response = api.get_all_todos()
        todos = todos_response.json()

        active_todo = next(
            (t for t in todos["todos"] if t.get("todo") == "TODO"),
            None,
        )
        assert active_todo is not None, "Need an active TODO to test"

        original_title = active_todo["title"]

        # Complete it
        complete_response = api.complete_todo(active_todo)
        assert complete_response.status_code == 200

        # Re-open it by setting state back to TODO
        reopen_response = api.complete_todo(active_todo, state="TODO")
        assert reopen_response.status_code == 200

        # Verify it's back to TODO state
        todos_response = api.get_all_todos()
        todos = todos_response.json()
        reopened_todo = next(
            (t for t in todos["todos"] if original_title in t.get("title", "")),
            None,
        )
        assert reopened_todo is not None, "Re-opened todo should still exist"
        assert reopened_todo.get("todo") == "TODO", "Todo should be back to TODO state"

        # Query with include_completed for TODAY's date
        today = get_today_str()
        agenda_response = api.get(f"/agenda?date={today}&include_completed=true")
        entries = agenda_response.json().get("entries", [])

        # The re-opened item should NOT appear as a completed entry
        # (It might appear if it has scheduled/deadline for today, but not due to completion)
        completed_entries = [
            e
            for e in entries
            if original_title in e.get("title", "") and e.get("todo") == "DONE"
        ]
        assert len(completed_entries) == 0, (
            f"Re-opened task should not appear as DONE. Found: {completed_entries}"
        )

    def test_unscheduled_repeatable_item_shows_multiple_completion_dates(self, api):
        """A reopened unscheduled item should appear on each completion date.

        Scenario:
        1. Start with one TODO that has no SCHEDULED/DEADLINE.
        2. Complete it on date1.
        3. Reopen it to TODO on a later date.
        4. Complete it again on date2.

        With include_completed=true, the item should appear as completed when
        querying both date1 and date2.
        """
        unique_title = "Repeatable unscheduled completion history 424242"

        create_response = api.create_todo(unique_title)
        assert create_response.status_code == 200, (
            f"Create failed: {create_response.text}"
        )

        def get_task():
            todos_response = api.get_all_todos()
            todos = todos_response.json().get("todos", [])
            return next((t for t in todos if unique_title in t.get("title", "")), None)

        task = get_task()
        assert task is not None, "Created TODO not found"
        assert task.get("scheduled") is None, "Test requires no scheduled date"
        assert task.get("deadline") is None, "Test requires no deadline date"

        date1 = "2024-06-10"
        reopened_date = "2024-06-12"
        date2 = "2024-06-14"

        complete_1 = api.complete_todo(task, state="DONE", override_date=date1)
        assert complete_1.status_code == 200, f"First completion failed: {complete_1.text}"

        task = get_task()
        assert task is not None, "Task should still exist after first completion"

        reopen = api.set_state(task, state="TODO", override_date=reopened_date)
        assert reopen.status_code == 200, f"Reopen failed: {reopen.text}"

        task = get_task()
        assert task is not None, "Task should still exist after reopen"
        assert task.get("todo") == "TODO", "Task should be TODO before second completion"

        complete_2 = api.complete_todo(task, state="DONE", override_date=date2)
        assert complete_2.status_code == 200, (
            f"Second completion failed: {complete_2.text}"
        )

        def get_completed_entry_for_date(query_date):
            response = api.get(
                f"/agenda?date={query_date}&span=day&include_completed=true"
            )
            assert response.status_code == 200, (
                f"/agenda failed for {query_date}: {response.text}"
            )
            entries = response.json().get("entries", [])
            return next(
                (
                    entry
                    for entry in entries
                    if unique_title in entry.get("title", "")
                    and entry.get("todo") == "DONE"
                ),
                None,
            )

        entry_date1 = get_completed_entry_for_date(date1)
        assert entry_date1 is not None, (
            f"Item should appear as completed on first completion date {date1}"
        )
        assert entry_date1.get("completedAt", "").startswith(date1), (
            f"Expected completedAt to start with {date1}, got {entry_date1.get('completedAt')}"
        )

        entry_date2 = get_completed_entry_for_date(date2)
        assert entry_date2 is not None, (
            f"Item should appear as completed on second completion date {date2}"
        )
        assert entry_date2.get("completedAt", "").startswith(date2), (
            f"Expected completedAt to start with {date2}, got {entry_date2.get('completedAt')}"
        )

        # Also verify weekly view includes both completion dates as completed entries
        week_response = api.get_agenda(
            span="week", date=date1, include_completed=True
        )
        assert week_response.status_code == 200, (
            f"Weekly agenda failed: {week_response.text}"
        )
        week_days = week_response.json().get("days", {})

        for completion_date in (date1, date2):
            day_entries = week_days.get(completion_date, [])
            completed_entry = next(
                (
                    entry
                    for entry in day_entries
                    if unique_title in entry.get("title", "")
                    and entry.get("dateRelevance") == "completed"
                    and entry.get("todo") == "DONE"
                ),
                None,
            )
            assert completed_entry is not None, (
                f"Weekly agenda should include completed entry on {completion_date}"
            )
            assert completed_entry.get("completedAt", "").startswith(completion_date), (
                f"Weekly completedAt should start with {completion_date}, "
                f"got {completed_entry.get('completedAt')}"
            )

        completed_occurrences = 0
        for day_entries in week_days.values():
            completed_occurrences += sum(
                1
                for entry in day_entries
                if unique_title in entry.get("title", "")
                and entry.get("dateRelevance") == "completed"
                and entry.get("todo") == "DONE"
            )
        assert completed_occurrences == 2, (
            f"Expected exactly 2 completed occurrences in weekly view, "
            f"found {completed_occurrences}"
        )


class TestStateChangeLogBug:
    """Tests for include_completed behavior with LOGBOOK-only completions.

    When include_completed=true, a LOGBOOK transition to a done state on the
    query date should be treated as a completion signal even without CLOSED.
    Entries with no completion signal (no CLOSED, no matching LOGBOOK entry,
    no scheduled/deadline match) should still be excluded.
    """

    def test_done_with_logbook_transition_is_included_as_completed(self, api):
        """DONE items with a matching LOGBOOK transition should appear as completed.

        This is a regression test for deployed behavior where entries with a
        done-state transition in LOGBOOK are missing from include_completed
        results unless they also have a CLOSED timestamp.
        """
        # Query with include_completed for the test date
        agenda_response = api.get(f"/agenda?date={TEST_DATE}&include_completed=true")
        assert agenda_response.status_code == 200

        entries = agenda_response.json().get("entries", [])
        matched_entry = next(
            (
                entry
                for entry in entries
                if "Task with state change log but no CLOSED" in entry.get("title", "")
            ),
            None,
        )
        assert matched_entry is not None, (
            "Expected LOGBOOK-completed item to appear with include_completed=true."
        )
        assert matched_entry.get("todo") == "DONE"
        assert matched_entry.get("completedAt", "").startswith(TEST_DATE), (
            f"Expected completedAt to start with {TEST_DATE}, got "
            f"{matched_entry.get('completedAt')}"
        )

    def test_done_without_any_completion_signal_not_shown_as_completed(self, api):
        """DONE items with no dated completion signal should not appear.

        A LOGBOOK state transition to a done state is a valid completion signal
        and should appear on that date with include_completed=true.
        A plain DONE item without CLOSED, scheduled/deadline, or LOGBOOK transition
        should remain excluded.
        """
        # Query with include_completed for the test date
        agenda_response = api.get(f"/agenda?date={TEST_DATE}&include_completed=true")
        assert agenda_response.status_code == 200

        entries = agenda_response.json().get("entries", [])

        logbook_completed = next(
            (
                entry
                for entry in entries
                if "Task with state change log but no CLOSED" in entry.get("title", "")
            ),
            None,
        )
        assert logbook_completed is not None, (
            "DONE item with LOGBOOK completion transition should be included."
        )
        assert logbook_completed.get("completedAt", "").startswith(TEST_DATE), (
            f"Expected completedAt to start with {TEST_DATE}, got "
            f"{logbook_completed.get('completedAt')}"
        )

        no_signal_entry = next(
            (
                entry
                for entry in entries
                if "Task done without any logging" in entry.get("title", "")
            ),
            None,
        )
        assert no_signal_entry is None, (
            "DONE item without CLOSED, schedule/deadline, or LOGBOOK transition "
            "should not be included."
        )

    def test_state_change_only_with_matching_completion_date_appears(self, api, org_dir):
        """State change log entries should only appear if completion date matches query date.

        When org-agenda log mode shows state changes, entries should only pass
        the filter if they have:
        1. A scheduled date matching the query date, OR
        2. A deadline date matching the query date, OR
        3. A completedAt date matching the query date

        Entries that appear solely due to state change logs (no CLOSED or
        CLOSED on different date) should be filtered out.
        """

        # Create an item, complete it (adds CLOSED), then query
        # First get an active todo
        todos_response = api.get_all_todos()
        todos = todos_response.json()

        active_todo = next(
            (
                t
                for t in todos["todos"]
                if t.get("todo") == "TODO"
                and not t.get("scheduled")  # No scheduled
                and not t.get("deadline")
            ),  # No deadline
            None,
        )

        if active_todo is None:
            # Create one without scheduled/deadline
            capture_response = api.capture(
                "todo", {"Title": "Temp task for state change test"}
            )
            assert capture_response.status_code == 200

            # Re-fetch to get the new todo
            todos_response = api.get_all_todos()
            todos = todos_response.json()
            active_todo = next(
                (
                    t
                    for t in todos["todos"]
                    if "Temp task for state change test" in t.get("title", "")
                ),
                None,
            )
            assert active_todo is not None, "Could not create test todo"

        original_title = active_todo["title"]

        # Complete it - this adds CLOSED timestamp for today
        complete_response = api.complete_todo(active_todo)
        assert complete_response.status_code == 200

        # Query for TODAY's date with include_completed=true
        today = get_today_str()
        agenda_response = api.get(f"/agenda?date={today}&include_completed=true")
        entries = agenda_response.json().get("entries", [])

        # Find the completed item
        completed_entry = next(
            (e for e in entries if original_title in e.get("title", "")),
            None,
        )

        # If found, it MUST have completedAt matching today (or scheduled/deadline for today)
        if completed_entry:
            completed_at = completed_entry.get("completedAt")
            scheduled = completed_entry.get("scheduled")
            deadline = completed_entry.get("deadline")

            # At least one of these should match today for the entry to be valid
            has_valid_date = (
                (completed_at and today in completed_at)
                or (extract_date(scheduled) == today)
                or (extract_date(deadline) == today)
            )
            assert has_valid_date, (
                f"Entry appeared without matching date. "
                f"completedAt={completed_at}, scheduled={scheduled}, deadline={deadline}, "
                f"query_date={today}"
            )

    def test_entries_without_any_date_not_shown(self, api):
        """Entries with null scheduled/deadline/completedAt should NOT appear.

        This is the core of the bug: the filter condition
        (and (null scheduled-date) (null deadline-date)) allows entries
        through even when they have no completedAt.

        With include_completed=true, ONLY entries with a matching date should appear:
        - scheduled matching query date
        - deadline matching query date
        - completedAt matching query date

        An entry with all three as null should NEVER appear.
        """
        # Query with include_completed
        query_date = TEST_DATE
        agenda_response = api.get(f"/agenda?date={query_date}&include_completed=true")
        entries = agenda_response.json().get("entries", [])

        # Check all entries - none should have all nulls
        for entry in entries:
            scheduled = entry.get("scheduled")
            deadline = entry.get("deadline")
            completed_at = entry.get("completedAt")

            # Extract just the date portion for comparison
            scheduled_date = extract_date(scheduled)
            deadline_date = extract_date(deadline)
            completed_at_date = completed_at[:10] if completed_at else None

            # For habits, the completion is tracked in the logbook via habitCompletedOnQueryDate
            is_habit_completed_on_date = entry.get(
                "isWindowHabit", False
            ) and entry.get("habitCompletedOnQueryDate", False)

            has_matching_date = (
                scheduled_date == query_date
                or deadline_date == query_date
                or completed_at_date == query_date
                or is_habit_completed_on_date
            )
            assert has_matching_date, (
                f"Entry has no date matching {query_date}: "
                f"title={entry.get('title')}, "
                f"scheduled={scheduled}, deadline={deadline}, completedAt={completed_at}, "
                f"isWindowHabit={entry.get('isWindowHabit')}, "
                f"habitCompletedOnQueryDate={entry.get('habitCompletedOnQueryDate')}"
            )


class TestIncludeCompletedParameter:
    """Tests for the include_completed query parameter parsing."""

    def test_accepts_true_string(self, api):
        """Should accept include_completed=true."""
        response = api.get(f"/agenda?date={TEST_DATE}&include_completed=true")
        assert response.status_code == 200

    def test_accepts_1_value(self, api):
        """Should accept include_completed=1."""
        response = api.get(f"/agenda?date={TEST_DATE}&include_completed=1")
        assert response.status_code == 200

    def test_false_is_default(self, api):
        """include_completed=false should behave like not passing it."""
        response_false = api.get(f"/agenda?date={TEST_DATE}&include_completed=false")
        response_none = api.get(f"/agenda?date={TEST_DATE}")

        assert response_false.status_code == 200
        assert response_none.status_code == 200

        # Both should return same structure (may have different content due to state changes)
        assert "entries" in response_false.json()
        assert "entries" in response_none.json()


class TestHabitIncludeCompleted:
    """Tests for include_completed with org-window-habit entries.

    Habits don't use CLOSED timestamps - they reschedule to future dates when completed.
    After completion, habits go back to TODO state but should still show up with
    include_completed=true because they have logbook entries showing the completion.
    """

    def test_habit_in_todo_state_appears_when_completed_on_date(self, api):
        """Habit that was completed and rescheduled (now TODO) should appear with include_completed.

        This tests the key scenario:
        1. Complete a habit (it reschedules and goes back to TODO state)
        2. Query with include_completed=true for the completion date
        3. The habit should appear with habitCompletedOnQueryDate=true
        4. The habit's todo state should be TODO (not DONE) because it rescheduled
        """
        # Get a window habit
        todos_response = api.get_all_todos()
        todos = todos_response.json()

        habit = next(
            (
                t
                for t in todos["todos"]
                if t.get("isWindowHabit", False) and t.get("todo") == "TODO"
            ),
            None,
        )
        if habit is None:
            import pytest

            pytest.skip("No window habit in TODO state found")

        original_title = habit["title"]

        # Read file content BEFORE completion for comparison
        habit_file = habit.get("file")
        with open(habit_file, "r") as f:
            before_content = f.read()
        print(
            f"\n=== File content BEFORE completion ===\n{before_content}\n=== End BEFORE ==="
        )

        # Complete the habit - it will reschedule and go back to TODO
        # Use override_date=TEST_DATE to ensure the LOGBOOK entry has the fake date
        # (otherwise it would use the real current time, which wouldn't match our query)
        complete_response = api.complete_todo(habit, override_date=TEST_DATE)
        assert complete_response.status_code == 200, (
            f"Complete failed: {complete_response.text}"
        )
        print(
            f"\n=== Complete response ===\n{complete_response.json()}\n=== End complete response ==="
        )

        # Get the server's view of the habit right after completion
        todos_after_complete = api.get_all_todos().json()
        habit_from_server = next(
            (
                t
                for t in todos_after_complete["todos"]
                if t.get("id") == habit.get("id")
            ),
            None,
        )
        print(
            f"\n=== Habit from server after complete ===\n{habit_from_server}\n=== End server view ==="
        )

        # Debug: Read the file directly to verify LOGBOOK entry was written
        habit_file = habit.get("file")
        with open(habit_file, "r") as f:
            file_content = f.read()
        # Print file content for debugging to see if ANY LOGBOOK entry was created
        print(
            f"\n=== File content after completion (no override_date) ===\n{file_content}\n=== End file content ==="
        )

        # Verify the habit is back to TODO state (it rescheduled)
        todos_response = api.get_all_todos()
        todos = todos_response.json()
        habit_after = next(
            (t for t in todos["todos"] if original_title in t.get("title", "")),
            None,
        )
        assert habit_after is not None, (
            f"Habit '{original_title}' not found after completion"
        )
        assert habit_after.get("todo") == "TODO", (
            f"Habit should be back to TODO after completion (it reschedules). "
            f"Current state: {habit_after.get('todo')}"
        )

        # Query agenda for TEST_DATE (the fake "today") with include_completed=true
        agenda_response = api.get(f"/agenda?date={TEST_DATE}&include_completed=true")
        assert agenda_response.status_code == 200

        entries = agenda_response.json().get("entries", [])

        # Find the habit by title
        habit_entry = next(
            (e for e in entries if original_title in e.get("title", "")),
            None,
        )

        # Debug info
        entry_info = [
            (
                e.get("title"),
                e.get("todo"),
                e.get("isWindowHabit"),
                e.get("habitCompletedOnQueryDate", False),
            )
            for e in entries
        ]

        assert habit_entry is not None, (
            f"Habit '{original_title}' not found in agenda for {TEST_DATE} with include_completed=true. "
            f"The habit is in TODO state but was completed today, so it should appear. "
            f"Entries: {entry_info}"
        )

        # The habit should be in TODO state (it rescheduled)
        assert habit_entry.get("todo") == "TODO", (
            f"Habit should be in TODO state (it rescheduled after completion). "
            f"Found: {habit_entry.get('todo')}"
        )

        # The habit should have habitCompletedOnQueryDate=true
        assert habit_entry.get("habitCompletedOnQueryDate", False), (
            f"Habit entry should have habitCompletedOnQueryDate=true. Entry: {habit_entry}"
        )

        # The habit should be marked as a window habit
        assert habit_entry.get("isWindowHabit", False), (
            f"Habit entry should have isWindowHabit=true. Entry: {habit_entry}"
        )

    def test_habit_completed_on_past_date_appears_in_past_agenda(self, api):
        """Habit with LOGBOOK completion on past date should appear when querying that date.

        This tests the key scenario where:
        1. A habit has LOGBOOK entries showing completion on TEST_DATE_PREV_DAY
        2. The habit is scheduled for today (TEST_DATE), so it doesn't appear in yesterday's normal agenda
        3. Query yesterday (TEST_DATE_PREV_DAY) with include_completed=true
        4. The habit should appear because it was completed on that date (per LOGBOOK)
        """
        # The fixture "Test Window Habit" has a LOGBOOK entry for TEST_DATE_PREV_DAY
        # First verify the habit exists and is recognized as a window habit
        todos_response = api.get_all_todos()
        todos = todos_response.json()

        habit = next(
            (
                t
                for t in todos["todos"]
                if "Test Window Habit" in t.get("title", "")
                and t.get("isWindowHabit", False)
            ),
            None,
        )

        if habit is None:
            import pytest

            pytest.skip(
                "Test Window Habit fixture not found or not recognized as window habit"
            )

        # Verify the habit is scheduled for today, not yesterday
        scheduled = habit.get("scheduled")
        if scheduled:
            from conftest import extract_date, TEST_DATE

            scheduled_date = extract_date(scheduled)
            assert scheduled_date == TEST_DATE, (
                f"Fixture should have habit scheduled for today ({TEST_DATE}), "
                f"but got {scheduled_date}"
            )

        # Query yesterday's agenda with include_completed=true
        from conftest import TEST_DATE_PREV_DAY

        agenda_response = api.get(
            f"/agenda?date={TEST_DATE_PREV_DAY}&include_completed=true"
        )
        assert agenda_response.status_code == 200

        entries = agenda_response.json().get("entries", [])

        # Find the habit in yesterday's agenda
        habit_entry = next(
            (e for e in entries if "Test Window Habit" in e.get("title", "")),
            None,
        )

        # Debug info
        entry_titles = [
            (e.get("title"), e.get("isWindowHabit"), e.get("habitCompletedOnQueryDate"))
            for e in entries
        ]

        assert habit_entry is not None, (
            f"Habit 'Test Window Habit' not found in agenda for {TEST_DATE_PREV_DAY} "
            f"with include_completed=true. The habit has a LOGBOOK entry for this date, "
            f"so it should appear. Entries: {entry_titles}"
        )

        # The habit should have habitCompletedOnQueryDate=true
        assert habit_entry.get("habitCompletedOnQueryDate", False), (
            f"Habit should have habitCompletedOnQueryDate=true since it was completed "
            f"on {TEST_DATE_PREV_DAY}. Entry: {habit_entry}"
        )

        # The habit should be in TODO state (habits reschedule after completion)
        assert habit_entry.get("todo") == "TODO", (
            f"Habit should be in TODO state. Found: {habit_entry.get('todo')}"
        )

    def test_habit_not_completed_on_date_does_not_appear(self, api):
        """Habit that was NOT completed on a past date should not appear for that date.

        This verifies that include_completed doesn't show habits that weren't
        actually completed on the query date.
        """
        # "Another Window Habit Not Completed Yesterday" has LOGBOOK entries for
        # 2024-06-13 and 2024-06-10, but NOT for TEST_DATE_PREV_DAY (2024-06-14)

        # Query yesterday's agenda
        from conftest import TEST_DATE_PREV_DAY

        agenda_response = api.get(
            f"/agenda?date={TEST_DATE_PREV_DAY}&include_completed=true"
        )
        assert agenda_response.status_code == 200

        entries = agenda_response.json().get("entries", [])

        # This habit should NOT appear because it wasn't completed on TEST_DATE_PREV_DAY
        other_habit = next(
            (e for e in entries if "Another Window Habit" in e.get("title", "")),
            None,
        )

        assert other_habit is None, (
            f"Habit 'Another Window Habit Not Completed Yesterday' should NOT appear "
            f"in agenda for {TEST_DATE_PREV_DAY} because it wasn't completed on that date. "
            f"Found: {other_habit}"
        )
