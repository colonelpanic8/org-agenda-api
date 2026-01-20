# org-window-habit Integration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Expose org-window-habit status, configuration, and graph data via org-agenda-api HTTP endpoints.

**Architecture:** Add optional dependency on org-window-habit. When `org-window-habit-mode` is enabled, expose habit data through new endpoints (`/habit-config`, `/habit-status`) and augment existing endpoints (`/get-all-todos`, `/agenda`, `/complete`) with habit summary fields.

**Tech Stack:** Emacs Lisp (org-agenda-api.el), Python (pytest integration tests), org-window-habit EIEIO classes

---

## Task 1: Test Infrastructure - Add org-window-habit Support

**Files:**
- Modify: `scripts/run-emacs-server.el`
- Create: `tests/fixtures/habits.org`

**Step 1: Create test fixture with window-habit data**

Create `tests/fixtures/habits.org`:

```org
#+TITLE: Test Habits

* TODO Exercise daily
  DEADLINE: <2024-06-15 Sat .+1d>
  :PROPERTIES:
  :ID: habit-exercise-daily
  :OWH_ASSESSMENT_INTERVAL: 1d
  :OWH_WINDOW_DURATION: 7d
  :OWH_REPETITIONS_REQUIRED: 5
  :END:
  :LOGBOOK:
  - State "DONE"       from "TODO"       [2024-06-14 Fri 10:00]
  - State "DONE"       from "TODO"       [2024-06-13 Thu 09:30]
  - State "DONE"       from "TODO"       [2024-06-12 Wed 11:00]
  - State "DONE"       from "TODO"       [2024-06-10 Mon 08:45]
  :END:

* TODO Meditate
  DEADLINE: <2024-06-15 Sat .+1d>
  :PROPERTIES:
  :ID: habit-meditate
  :OWH_ASSESSMENT_INTERVAL: 1d
  :OWH_WINDOW_DURATION: 3d
  :OWH_REPETITIONS_REQUIRED: 2
  :END:
  :LOGBOOK:
  - State "DONE"       from "TODO"       [2024-06-14 Fri 07:00]
  :END:

* TODO Regular todo without habit
  :PROPERTIES:
  :ID: regular-todo-no-habit
  :END:
```

**Step 2: Add org-window-habit loading to test server**

Add to `scripts/run-emacs-server.el` after line 52 (after requiring org-agenda-api):

```elisp
;; Load org-window-habit if available for testing habit endpoints
(when (require 'org-window-habit nil t)
  (org-window-habit-mode 1)
  (message "org-window-habit-mode enabled for testing"))
```

**Step 3: Verify test server starts with org-window-habit**

Run: `cd /home/imalison/.../org-agenda-api/.worktrees/window-habit-integration && pytest tests/test_get_todos.py::TestGetAllTodos::test_returns_200 -v`

Expected: PASS (server starts successfully)

**Step 4: Commit**

```bash
git add tests/fixtures/habits.org scripts/run-emacs-server.el
git commit -m "test: add org-window-habit test infrastructure"
```

---

## Task 2: Implement `/habit-config` Endpoint

**Files:**
- Modify: `org-agenda-api.el`
- Create: `tests/test_habit_config.py`

**Step 1: Write the failing test**

Create `tests/test_habit_config.py`:

```python
"""Tests for /habit-config endpoint."""

import pytest


class TestHabitConfig:
    """Tests for the /habit-config endpoint."""

    def test_returns_200(self, api):
        """Endpoint returns 200 status."""
        response = api.get("/habit-config")
        assert response.status_code == 200

    def test_returns_json_object(self, api):
        """Endpoint returns valid JSON."""
        response = api.get("/habit-config")
        data = response.json()
        assert isinstance(data, dict)

    def test_has_status_field(self, api):
        """Response has status field."""
        response = api.get("/habit-config")
        data = response.json()
        assert "status" in data
        assert data["status"] == "ok"

    def test_has_enabled_field(self, api):
        """Response has enabled field indicating if org-window-habit-mode is on."""
        response = api.get("/habit-config")
        data = response.json()
        assert "enabled" in data
        assert isinstance(data["enabled"], bool)

    def test_has_colors_when_enabled(self, api):
        """Response has colors object when org-window-habit-mode is enabled."""
        response = api.get("/habit-config")
        data = response.json()
        if data.get("enabled"):
            assert "colors" in data
            colors = data["colors"]
            assert "conforming" in colors
            assert "notConforming" in colors

    def test_colors_are_hex_strings(self, api):
        """Color values are hex color strings."""
        response = api.get("/habit-config")
        data = response.json()
        if data.get("enabled") and "colors" in data:
            for key, value in data["colors"].items():
                assert isinstance(value, str), f"Color {key} should be string"
                assert value.startswith("#"), f"Color {key} should start with #"

    def test_has_display_settings_when_enabled(self, api):
        """Response has display settings when enabled."""
        response = api.get("/habit-config")
        data = response.json()
        if data.get("enabled"):
            assert "display" in data
            display = data["display"]
            assert "precedingIntervals" in display
            assert "followingDays" in display

    def test_has_behavior_settings_when_enabled(self, api):
        """Response has behavior settings when enabled."""
        response = api.get("/habit-config")
        data = response.json()
        if data.get("enabled"):
            assert "behavior" in data
            behavior = data["behavior"]
            assert "repeatToDeadline" in behavior
            assert "repeatToScheduled" in behavior
```

**Step 2: Run test to verify it fails**

Run: `pytest tests/test_habit_config.py -v`

Expected: FAIL with connection error or 404 (endpoint doesn't exist)

**Step 3: Write the endpoint implementation**

Add to `org-agenda-api.el` after the `/health` endpoint (around line 1150):

```elisp
(defservlet habit-config application/json ()
  "Endpoint: Return org-window-habit configuration including colors and settings."
  (let ((enabled (and (boundp 'org-window-habit-mode) org-window-habit-mode)))
    (if (not enabled)
        (insert (json-encode `(("status" . "ok")
                               ("enabled" . :json-false))))
      (insert (json-encode
               `(("status" . "ok")
                 ("enabled" . t)
                 ("colors" . (("conforming" . ,org-window-habit-conforming-color)
                              ("notConforming" . ,org-window-habit-not-conforming-color)
                              ("requiredCompletionForeground" . ,org-window-habit-required-completion-foreground-color)
                              ("nonRequiredCompletionForeground" . ,org-window-habit-non-required-completion-foreground-color)
                              ("requiredCompletionTodayForeground" . ,org-window-habit-required-completion-today-foreground-color)))
                 ("display" . (("precedingIntervals" . ,org-window-habit-preceding-intervals)
                               ("followingDays" . ,org-window-habit-following-days)
                               ("completionNeededTodayGlyph" . ,(char-to-string org-window-habit-completion-needed-today-glyph))
                               ("completedGlyph" . ,(char-to-string org-window-habit-completed-glyph))))
                 ("behavior" . (("repeatToDeadline" . ,(if org-window-habit-repeat-to-deadline t :json-false))
                                ("repeatToScheduled" . ,(if org-window-habit-repeat-to-scheduled t :json-false))
                                ("nonConformingScale" . ,org-window-habit-non-conforming-scale))))))))
  (org-agenda-api--track-request))
```

**Step 4: Run test to verify it passes**

Run: `pytest tests/test_habit_config.py -v`

Expected: PASS (all tests)

**Step 5: Commit**

```bash
git add org-agenda-api.el tests/test_habit_config.py
git commit -m "feat: add /habit-config endpoint for colors and settings"
```

---

## Task 3: Implement Habit Detection Helper

**Files:**
- Modify: `org-agenda-api.el`

**Step 1: Add detection function**

Add to `org-agenda-api.el` in the internal functions section (around line 330):

```elisp
;;; Window Habit Support

(defun org-agenda-api--window-habit-available-p ()
  "Return non-nil if org-window-habit is loaded and enabled."
  (and (featurep 'org-window-habit)
       (bound-and-true-p org-window-habit-mode)))

(defun org-agenda-api--is-window-habit-p ()
  "Return non-nil if entry at point is an org-window-habit.
Must be called with point at an org heading."
  (and (org-agenda-api--window-habit-available-p)
       (or (org-entry-get nil (org-window-habit-property "ASSESSMENT_INTERVAL") t)
           (org-entry-get nil (org-window-habit-property "WINDOW_SPECS") t))))
```

**Step 2: Verify elisp loads without errors**

Run: `emacs --batch -l org-agenda-api.el -f kill-emacs`

Expected: No errors

**Step 3: Commit**

```bash
git add org-agenda-api.el
git commit -m "feat: add window-habit detection helpers"
```

---

## Task 4: Implement Habit Summary Helper

**Files:**
- Modify: `org-agenda-api.el`

**Step 1: Add plist-to-alist converter**

Add after the detection functions:

```elisp
(defun org-agenda-api--plist-to-alist (plist)
  "Convert PLIST to an alist for JSON encoding.
Converts :key to \"key\" string."
  (let ((result nil))
    (while plist
      (let ((key (substring (symbol-name (car plist)) 1))  ; Remove leading :
            (value (cadr plist)))
        (push (cons key value) result))
      (setq plist (cddr plist)))
    (nreverse result)))
```

**Step 2: Add habit summary function**

```elisp
(defun org-agenda-api--get-habit-summary ()
  "Get habit summary for the entry at point.
Returns an alist suitable for JSON encoding, or nil if not a window-habit."
  (when (org-agenda-api--is-window-habit-p)
    (condition-case err
        (let* ((habit (org-window-habit-create-instance-from-heading-at-point))
               (window-specs (oref habit window-specs))
               (first-spec (car window-specs))
               (iterator (org-window-habit-iterator-from-time first-spec))
               (conforming-ratio (org-window-habit-conforming-ratio iterator))
               (next-required (org-window-habit-get-next-required-interval habit))
               (window (oref iterator window))
               (start-index (oref iterator start-index))
               (end-index (oref iterator end-index))
               (completions-in-window (- end-index start-index))
               (target-reps (oref first-spec target-repetitions))
               (now (current-time))
               (completion-needed-today
                (org-window-habit-time-falls-in-assessment-interval window next-required)))
          `(("conformingRatio" . ,conforming-ratio)
            ("completionNeededToday" . ,(if completion-needed-today t :json-false))
            ("nextRequiredInterval" . ,(format-time-string "%Y-%m-%d" next-required))
            ("completionsInWindow" . ,completions-in-window)
            ("targetRepetitions" . ,target-reps)))
      (error
       (org-agenda-api--log 'warn "Failed to get habit summary: %s" (error-message-string err))
       nil))))
```

**Step 3: Verify elisp loads without errors**

Run: `emacs --batch -l org-agenda-api.el -f kill-emacs`

Expected: No errors

**Step 4: Commit**

```bash
git add org-agenda-api.el
git commit -m "feat: add habit summary helper function"
```

---

## Task 5: Implement `/habit-status` Endpoint

**Files:**
- Modify: `org-agenda-api.el`
- Modify: `tests/conftest.py`
- Create: `tests/test_habit_status.py`

**Step 1: Add APIClient method for habit-status**

Add to `tests/conftest.py` in the APIClient class:

```python
    def get_habit_status(self, org_id: str, preceding: int = None, following: int = None) -> requests.Response:
        """GET /habit-status with id and optional range parameters."""
        params = f"?id={org_id}"
        if preceding is not None:
            params += f"&preceding={preceding}"
        if following is not None:
            params += f"&following={following}"
        return self.get(f"/habit-status{params}")
```

**Step 2: Write the failing tests**

Create `tests/test_habit_status.py`:

```python
"""Tests for /habit-status endpoint."""

import pytest


class TestHabitStatus:
    """Tests for the /habit-status endpoint."""

    def test_returns_200_for_valid_habit(self, api):
        """Endpoint returns 200 for a valid habit ID."""
        response = api.get_habit_status("habit-exercise-daily")
        assert response.status_code == 200

    def test_returns_error_for_missing_id(self, api):
        """Endpoint returns error when id parameter is missing."""
        response = api.get("/habit-status")
        data = response.json()
        assert data.get("status") == "error"

    def test_returns_error_for_nonexistent_id(self, api):
        """Endpoint returns error for non-existent org ID."""
        response = api.get_habit_status("nonexistent-id-12345")
        data = response.json()
        assert data.get("status") == "error"

    def test_returns_error_for_non_habit(self, api):
        """Endpoint returns error for entry that is not a window-habit."""
        response = api.get_habit_status("regular-todo-no-habit")
        data = response.json()
        assert data.get("status") == "error"
        assert "not" in data.get("message", "").lower()

    def test_has_required_fields(self, api):
        """Response has all required fields for a valid habit."""
        response = api.get_habit_status("habit-exercise-daily")
        data = response.json()
        assert data.get("status") == "ok"
        assert "id" in data
        assert "title" in data
        assert "habit" in data
        assert "currentState" in data
        assert "doneTimes" in data
        assert "graph" in data

    def test_habit_contains_config(self, api):
        """Habit field contains configuration."""
        response = api.get_habit_status("habit-exercise-daily")
        data = response.json()
        habit = data.get("habit", {})
        assert "assessmentInterval" in habit
        assert "windowSpecs" in habit

    def test_current_state_has_conforming_ratio(self, api):
        """Current state has conforming ratio between 0 and 1."""
        response = api.get_habit_status("habit-exercise-daily")
        data = response.json()
        state = data.get("currentState", {})
        ratio = state.get("conformingRatio")
        assert ratio is not None
        assert 0 <= ratio <= 1

    def test_graph_is_array(self, api):
        """Graph field is an array of intervals."""
        response = api.get_habit_status("habit-exercise-daily")
        data = response.json()
        graph = data.get("graph")
        assert isinstance(graph, list)
        assert len(graph) > 0

    def test_graph_entry_has_required_fields(self, api):
        """Each graph entry has required fields."""
        response = api.get_habit_status("habit-exercise-daily")
        data = response.json()
        graph = data.get("graph", [])
        if graph:
            entry = graph[0]
            assert "date" in entry
            assert "status" in entry
            assert "conformingRatioWithout" in entry
            assert "conformingRatioWith" in entry
            assert "completionCount" in entry

    def test_preceding_parameter_affects_graph_length(self, api):
        """Preceding parameter changes graph length."""
        response_default = api.get_habit_status("habit-exercise-daily")
        response_short = api.get_habit_status("habit-exercise-daily", preceding=5)

        default_graph = response_default.json().get("graph", [])
        short_graph = response_short.json().get("graph", [])

        # Shorter preceding should result in fewer or equal entries
        assert len(short_graph) <= len(default_graph)

    def test_done_times_is_array(self, api):
        """Done times field is an array of timestamps."""
        response = api.get_habit_status("habit-exercise-daily")
        data = response.json()
        done_times = data.get("doneTimes")
        assert isinstance(done_times, list)
```

**Step 3: Run tests to verify they fail**

Run: `pytest tests/test_habit_status.py -v`

Expected: FAIL (endpoint doesn't exist)

**Step 4: Implement graph builder helper**

Add to `org-agenda-api.el`:

```elisp
(defun org-agenda-api--build-habit-graph-data (habit &optional preceding following)
  "Build semantic graph data for HABIT.
PRECEDING is number of intervals before today (default 21).
FOLLOWING is number of intervals after today (default 4).
Returns a list of alists suitable for JSON encoding."
  (setq preceding (or preceding org-window-habit-preceding-intervals))
  (setq following (or following org-window-habit-following-days))
  (let* ((now (current-time))
         (window-specs (oref habit window-specs))
         (assessment-interval (oref habit assessment-interval))
         (assessment-decrement (org-window-habit-negate-plist assessment-interval))
         (start-time (oref habit start-time))
         (max-reps (oref habit max-repetitions-per-interval))
         (result nil))
    ;; Calculate start point by going back `preceding` intervals
    (let* ((target-start (org-window-habit-normalize-time-to-duration now assessment-interval)))
      (dotimes (_ preceding)
        (let ((new-time (org-window-habit-keyed-duration-add-plist target-start assessment-decrement)))
          (when (time-less-p start-time new-time)
            (setq target-start new-time))))
      ;; Build iterators starting at target-start
      (let ((iterators (mapcar (lambda (spec)
                                 (org-window-habit-iterator-from-time spec target-start))
                               window-specs))
            (intervals-processed 0)
            (total-intervals (+ preceding following 1)))
        ;; Process each interval
        (while (< intervals-processed total-intervals)
          (let* ((window (oref (car iterators) window))
                 (assessment-start (oref window assessment-start-time))
                 (assessment-end (oref window assessment-end-time))
                 ;; Determine if this is past, present, or future
                 (time-type (cond
                             ((time-less-p assessment-end now) 'past)
                             ((time-less-p now assessment-start) 'future)
                             (t 'present)))
                 ;; Get assessments with and without completion
                 (assess-data (org-window-habit-assess-interval-with-and-without-completions
                               habit iterators
                               (lambda (x) (if (eq time-type 'present) max-reps x))))
                 (no-completion-val (nth 2 assess-data))
                 (with-completion-val (nth 3 assess-data))
                 (completion-count (nth 4 assess-data))
                 (next-required (org-window-habit-get-next-required-interval habit))
                 (completion-expected (org-window-habit-time-falls-in-assessment-interval
                                       window next-required)))
            (push `(("date" . ,(format-time-string "%Y-%m-%d" assessment-start))
                    ("assessmentStart" . ,(format-time-string "%Y-%m-%dT%H:%M:%S" assessment-start))
                    ("assessmentEnd" . ,(format-time-string "%Y-%m-%dT%H:%M:%S" assessment-end))
                    ("conformingRatioWithout" . ,no-completion-val)
                    ("conformingRatioWith" . ,with-completion-val)
                    ("completionCount" . ,completion-count)
                    ("status" . ,(symbol-name time-type))
                    ("completionExpectedToday" . ,(if completion-expected t :json-false)))
                  result)
            ;; Advance all iterators
            (dolist (iter iterators)
              (org-window-habit-advance iter))
            (cl-incf intervals-processed)))))
    (nreverse result)))
```

**Step 5: Implement the endpoint**

Add to `org-agenda-api.el`:

```elisp
(defservlet habit-status application/json (_path query)
  "Endpoint: Return detailed habit status including graph data.
Accepts query params:
  - 'id' (required): org-id of the habit entry
  - 'preceding' (optional, default 21): intervals before today
  - 'following' (optional, default 4): intervals after today"
  (condition-case err
      (let* ((id (cadr (assoc "id" query)))
             (preceding (let ((p (cadr (assoc "preceding" query))))
                          (when p (string-to-number p))))
             (following (let ((f (cadr (assoc "following" query))))
                          (when f (string-to-number f)))))
        (unless id
          (throw 'done (insert (json-encode `(("status" . "error")
                                              ("message" . "Missing required 'id' parameter"))))))
        (unless (org-agenda-api--window-habit-available-p)
          (throw 'done (insert (json-encode `(("status" . "error")
                                              ("message" . "org-window-habit-mode is not enabled"))))))
        (let ((location (org-id-find id)))
          (unless location
            (throw 'done (insert (json-encode `(("status" . "error")
                                                ("message" . "Entry not found"))))))
          (let ((file (car location))
                (pos (cdr location)))
            (with-current-buffer (find-file-noselect file)
              (save-excursion
                (goto-char pos)
                (unless (org-agenda-api--is-window-habit-p)
                  (throw 'done (insert (json-encode `(("status" . "error")
                                                      ("message" . "Entry is not an org-window-habit"))))))
                (let* ((habit (org-window-habit-create-instance-from-heading-at-point))
                       (title (org-get-heading t t t t))
                       (done-times (oref habit done-times))
                       (window-specs (oref habit window-specs))
                       (graph (org-agenda-api--build-habit-graph-data habit preceding following))
                       (summary (org-agenda-api--get-habit-summary)))
                  (insert (json-encode
                           `(("status" . "ok")
                             ("id" . ,id)
                             ("title" . ,title)
                             ("habit" . (("assessmentInterval" . ,(org-agenda-api--plist-to-alist
                                                                   (oref habit assessment-interval)))
                                         ("rescheduleInterval" . ,(org-agenda-api--plist-to-alist
                                                                   (oref habit reschedule-interval)))
                                         ("rescheduleThreshold" . ,(oref habit reschedule-threshold))
                                         ("maxRepetitionsPerInterval" . ,(oref habit max-repetitions-per-interval))
                                         ("startTime" . ,(format-time-string "%Y-%m-%dT%H:%M:%S"
                                                                             (oref habit start-time)))
                                         ("windowSpecs" . ,(vconcat
                                                            (mapcar
                                                             (lambda (spec)
                                                               `(("duration" . ,(org-agenda-api--plist-to-alist
                                                                                 (oref spec duration-plist)))
                                                                 ("targetRepetitions" . ,(oref spec target-repetitions))
                                                                 ("conformingValue" . ,(oref spec conforming-value))))
                                                             window-specs)))))
                             ("currentState" . ,summary)
                             ("doneTimes" . ,(vconcat
                                              (mapcar (lambda (time)
                                                        (format-time-string "%Y-%m-%dT%H:%M:%S" time))
                                                      done-times)))
                             ("graph" . ,(vconcat graph)))))))))))
    (error
     (org-agenda-api--log-error-with-backtrace "/habit-status" err)
     (insert (json-encode `(("status" . "error")
                            ("message" . ,(error-message-string err)))))))
  (org-agenda-api--track-request))
```

**Step 6: Run tests to verify they pass**

Run: `pytest tests/test_habit_status.py -v`

Expected: PASS (all tests)

**Step 7: Commit**

```bash
git add org-agenda-api.el tests/conftest.py tests/test_habit_status.py
git commit -m "feat: add /habit-status endpoint with graph data"
```

---

## Task 6: Add `isWindowHabit` and `habitSummary` to `/get-all-todos`

**Files:**
- Modify: `org-agenda-api.el`
- Modify: `tests/test_get_todos.py`

**Step 1: Write the failing test**

Add to `tests/test_get_todos.py`:

```python
class TestGetAllTodosHabitFields:
    """Tests for habit-related fields in /get-all-todos."""

    def test_entries_have_is_window_habit_field(self, api):
        """Each entry has isWindowHabit field."""
        response = api.get_all_todos()
        data = response.json()
        todos = data.get("todos", [])
        for todo in todos:
            assert "isWindowHabit" in todo

    def test_habit_entry_has_habit_summary(self, api):
        """Habit entries have habitSummary field."""
        response = api.get_all_todos()
        data = response.json()
        todos = data.get("todos", [])
        habit_todos = [t for t in todos if t.get("isWindowHabit")]
        assert len(habit_todos) > 0, "Should have at least one habit in test data"
        for todo in habit_todos:
            assert "habitSummary" in todo
            summary = todo["habitSummary"]
            assert "conformingRatio" in summary
            assert "completionNeededToday" in summary

    def test_non_habit_entry_has_no_habit_summary(self, api):
        """Non-habit entries do not have habitSummary field."""
        response = api.get_all_todos()
        data = response.json()
        todos = data.get("todos", [])
        non_habit_todos = [t for t in todos if not t.get("isWindowHabit")]
        assert len(non_habit_todos) > 0, "Should have non-habit todos"
        for todo in non_habit_todos:
            assert "habitSummary" not in todo
```

**Step 2: Run test to verify it fails**

Run: `pytest tests/test_get_todos.py::TestGetAllTodosHabitFields -v`

Expected: FAIL (isWindowHabit field missing)

**Step 3: Modify `org-agenda-api--get-todo-elements-from-filepath`**

Find the function in `org-agenda-api.el` and modify the return alist to include habit fields. After the `("properties" . ,all-properties)` line, add:

```elisp
           ("isWindowHabit" . ,(if (org-agenda-api--is-window-habit-p) t :json-false))
           ,@(when (org-agenda-api--is-window-habit-p)
               (let ((summary (org-agenda-api--get-habit-summary)))
                 (when summary
                   `(("habitSummary" . ,summary)))))
```

**Step 4: Run tests to verify they pass**

Run: `pytest tests/test_get_todos.py::TestGetAllTodosHabitFields -v`

Expected: PASS

**Step 5: Commit**

```bash
git add org-agenda-api.el tests/test_get_todos.py
git commit -m "feat: add isWindowHabit and habitSummary to /get-all-todos"
```

---

## Task 7: Add Habit Fields to `/agenda` Endpoint

**Files:**
- Modify: `org-agenda-api.el`
- Modify: `tests/test_agenda.py`

**Step 1: Write the failing test**

Add to `tests/test_agenda.py`:

```python
class TestAgendaHabitFields:
    """Tests for habit-related fields in /agenda."""

    def test_entries_have_is_window_habit_field(self, api):
        """Each entry has isWindowHabit field."""
        response = api.get_agenda()
        data = response.json()
        entries = data.get("entries", [])
        for entry in entries:
            assert "isWindowHabit" in entry

    def test_habit_entry_has_habit_summary(self, api):
        """Habit entries have habitSummary field."""
        response = api.get_agenda()
        data = response.json()
        entries = data.get("entries", [])
        habit_entries = [e for e in entries if e.get("isWindowHabit")]
        # May or may not have habits scheduled for today
        for entry in habit_entries:
            assert "habitSummary" in entry
```

**Step 2: Run test to verify it fails**

Run: `pytest tests/test_agenda.py::TestAgendaHabitFields -v`

Expected: FAIL

**Step 3: Modify `org-agenda-api--extract-entry-data`**

Find the function and add habit fields to the return alist. After `("properties" . ,all-properties)`:

```elisp
             (is-window-habit (org-agenda-api--is-window-habit-p))
             (habit-summary (when is-window-habit (org-agenda-api--get-habit-summary)))
```

And add to the returned alist:

```elisp
              ("isWindowHabit" . ,(if is-window-habit t :json-false))
              ,@(when habit-summary
                  `(("habitSummary" . ,habit-summary)))
```

**Step 4: Run tests to verify they pass**

Run: `pytest tests/test_agenda.py::TestAgendaHabitFields -v`

Expected: PASS

**Step 5: Commit**

```bash
git add org-agenda-api.el tests/test_agenda.py
git commit -m "feat: add isWindowHabit and habitSummary to /agenda"
```

---

## Task 8: Add Habit Summary to `/complete` Response

**Files:**
- Modify: `org-agenda-api.el`
- Modify: `tests/test_complete.py`

**Step 1: Write the failing test**

Add to `tests/test_complete.py`:

```python
class TestCompleteHabitResponse:
    """Tests for habit-related fields in /complete response."""

    def test_completing_habit_returns_habit_summary(self, api, org_dir):
        """Completing a window-habit returns habitSummary in response."""
        # First get a habit todo
        todos_response = api.get_all_todos()
        todos = todos_response.json().get("todos", [])
        habit_todos = [t for t in todos if t.get("isWindowHabit") and t.get("todo") == "TODO"]

        if not habit_todos:
            pytest.skip("No uncompleted habits in test data")

        habit = habit_todos[0]
        response = api.complete_todo(habit)
        data = response.json()

        assert data.get("status") == "completed"
        assert "habitSummary" in data
        summary = data["habitSummary"]
        assert "conformingRatio" in summary
        assert "nextRequiredInterval" in summary
```

**Step 2: Run test to verify it fails**

Run: `pytest tests/test_complete.py::TestCompleteHabitResponse -v`

Expected: FAIL (habitSummary not in response)

**Step 3: Modify `/complete` endpoint**

Find the `defservlet complete` and modify `org-agenda-api--complete-todo-at` to return habit summary. After the completion logic, before returning the result, add:

```elisp
              ;; Add habit summary if this is a window-habit
              (habit-summary (when (org-agenda-api--is-window-habit-p)
                               (org-agenda-api--get-habit-summary)))
```

And modify the return alist to include it:

```elisp
              `(("status" . "completed")
                ("title" . ,title)
                ("oldState" . ,old-state)
                ("newState" . ,new-state)
                ,@(when habit-summary
                    `(("habitSummary" . ,habit-summary))))
```

**Step 4: Run tests to verify they pass**

Run: `pytest tests/test_complete.py::TestCompleteHabitResponse -v`

Expected: PASS

**Step 5: Commit**

```bash
git add org-agenda-api.el tests/test_complete.py
git commit -m "feat: add habitSummary to /complete response for window-habits"
```

---

## Task 9: Run Full Test Suite and Fix Issues

**Step 1: Run all tests**

Run: `pytest tests/ -v`

Expected: All tests pass (excluding pre-existing failures)

**Step 2: Fix any regressions**

If tests fail, investigate and fix.

**Step 3: Final commit**

```bash
git add -A
git commit -m "test: ensure all habit integration tests pass"
```

---

## Task 10: Update Documentation

**Files:**
- Modify: `README.md`

**Step 1: Add habit endpoints to documentation**

Add a section describing the new endpoints:

```markdown
### Habit Endpoints (requires org-window-habit)

These endpoints are available when `org-window-habit-mode` is enabled:

- `GET /habit-config` - Returns org-window-habit configuration (colors, display settings, behavior)
- `GET /habit-status?id=<org-id>&preceding=N&following=N` - Returns detailed habit status with graph data

Additionally, when org-window-habit is enabled:
- `/get-all-todos` entries include `isWindowHabit` and `habitSummary` fields
- `/agenda` entries include `isWindowHabit` and `habitSummary` fields
- `/complete` response includes `habitSummary` when completing a window-habit
```

**Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add habit endpoints documentation"
```

---

## Summary

| Task | Description | Tests |
|------|-------------|-------|
| 1 | Test infrastructure | Manual verification |
| 2 | `/habit-config` endpoint | test_habit_config.py |
| 3 | Detection helpers | Elisp load test |
| 4 | Summary helper | Elisp load test |
| 5 | `/habit-status` endpoint | test_habit_status.py |
| 6 | `/get-all-todos` habit fields | test_get_todos.py |
| 7 | `/agenda` habit fields | test_agenda.py |
| 8 | `/complete` habit summary | test_complete.py |
| 9 | Full test suite | All tests |
| 10 | Documentation | N/A |
