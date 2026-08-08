"""Pytest configuration and fixtures for org-agenda-api integration tests."""

import os
import shutil
import signal
import subprocess
import time
from pathlib import Path

import pytest
import requests


# Project root directory
PROJECT_ROOT = Path(__file__).parent.parent

# Fixed test date - Emacs will be configured to think this is "today"
# This makes tests fully deterministic and reproducible
TEST_DATE = "2024-06-15"  # A Saturday
TEST_DATE_ORG = "2024-06-15 Sat"
TEST_DATE_NEXT_DAY = "2024-06-16"
TEST_DATE_NEXT_DAY_ORG = "2024-06-16 Sun"
TEST_DATE_PREV_DAY = "2024-06-14"
TEST_DATE_PREV_DAY_ORG = "2024-06-14 Fri"
TEST_TIMEZONE = "America/Los_Angeles"

# Week range for multi-day tests (TEST_DATE is Saturday, so week is Sat-Fri)
TEST_WEEK_START = "2024-06-15"  # Saturday
TEST_WEEK_END = "2024-06-21"  # Friday
TEST_WEEK_DATES = [
    "2024-06-15",
    "2024-06-16",
    "2024-06-17",
    "2024-06-18",
    "2024-06-19",
    "2024-06-20",
    "2024-06-21",
]


def extract_date(timestamp):
    """Extract the date string from a timestamp.

    Handles both old format (string like "2024-06-15") and new format
    (dict like {"date": "2024-06-15", "time": "10:00"}).

    Returns None if timestamp is None or invalid.
    """
    if timestamp is None:
        return None
    if isinstance(timestamp, dict):
        return timestamp.get("date")
    if isinstance(timestamp, str):
        return timestamp[:10] if len(timestamp) >= 10 else timestamp
    return None


class EmacsServer:
    """Manages an Emacs subprocess running org-agenda-api."""

    def __init__(
        self,
        port: int,
        org_dir: Path,
        inbox_file: Path,
        fake_date: str,
        timezone: str = TEST_TIMEZONE,
    ):
        self.port = port
        self.org_dir = org_dir
        self.inbox_file = inbox_file
        self.fake_date = fake_date
        self.timezone = timezone
        self.process = None

    @property
    def base_url(self) -> str:
        return f"http://localhost:{self.port}"

    def start(self, timeout: float = 30.0) -> None:
        """Start Emacs with org-agenda-api server."""
        env = os.environ.copy()
        env["ORG_AGENDA_API_TEST_ORG_DIR"] = str(self.org_dir)
        env["ORG_AGENDA_API_TEST_PORT"] = str(self.port)
        env["ORG_AGENDA_API_TEST_INBOX"] = str(self.inbox_file)
        env["ORG_AGENDA_API_PACKAGE_DIR"] = str(PROJECT_ROOT)
        env["ORG_AGENDA_API_TEST_FAKE_DATE"] = self.fake_date
        # Keep Emacs timezone explicit for deterministic date behavior.
        env["TZ"] = self.timezone

        script_path = PROJECT_ROOT / "scripts" / "run-emacs-server.el"

        self.process = subprocess.Popen(
            ["emacs", "--batch", "--script", str(script_path)],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )

        # Wait for server to be ready
        start_time = time.time()
        while time.time() - start_time < timeout:
            try:
                response = requests.get(f"{self.base_url}/get-all-todos", timeout=1)
                if response.status_code == 200:
                    return
            except requests.exceptions.ConnectionError:
                pass

            # Check if process died
            if self.process.poll() is not None:
                stdout = self.process.stdout.read() if self.process.stdout else ""
                raise RuntimeError(
                    f"Emacs process died during startup. Output:\n{stdout}"
                )

            time.sleep(0.1)

        raise TimeoutError(f"Emacs server did not start within {timeout} seconds")

    def stop(self) -> None:
        """Stop the Emacs server."""
        if self.process:
            self.process.send_signal(signal.SIGTERM)
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
            self.process = None


class APIClient:
    """Simple HTTP client for org-agenda-api."""

    # Default timeout for all requests (seconds)
    DEFAULT_TIMEOUT = 10.0

    def __init__(self, base_url: str):
        self.base_url = base_url

    def get(self, path: str, **kwargs) -> requests.Response:
        """Make a GET request."""
        if "timeout" not in kwargs:
            kwargs["timeout"] = self.DEFAULT_TIMEOUT
        return requests.get(f"{self.base_url}{path}", **kwargs)

    def post(self, path: str, **kwargs) -> requests.Response:
        """Make a POST request."""
        if "timeout" not in kwargs:
            kwargs["timeout"] = self.DEFAULT_TIMEOUT
        return requests.post(f"{self.base_url}{path}", **kwargs)

    def get_all_todos(self) -> requests.Response:
        """GET /get-all-todos"""
        return self.get("/get-all-todos")

    def get_todays_agenda(self) -> requests.Response:
        """GET /get-todays-agenda"""
        return self.get("/get-todays-agenda")

    def get_agenda(
        self,
        span: str = "day",
        date: str = None,
        include_overdue: bool = None,
        include_completed: bool = None,
        start_date: str = None,
        end_date: str = None,
        today: str = None,
        overdue_behavior: str = None,
    ) -> requests.Response:
        """GET /agenda with optional parameters.

        Args:
            span: 'day' or 'week' (default: 'day')
            date: Date for single-day agenda (YYYY-MM-DD)
            include_overdue: Include overdue items
            include_completed: Include completed items
            start_date: Start of date range (YYYY-MM-DD)
            end_date: End of date range (YYYY-MM-DD)
            today: Date to treat as "today" for overdue calculations
            overdue_behavior: 'original', 'today', or 'both'
        """
        params = f"?span={span}"
        if date:
            params += f"&date={date}"
        if include_overdue is not None:
            params += f"&include_overdue={'true' if include_overdue else 'false'}"
        if include_completed is not None:
            params += f"&include_completed={'true' if include_completed else 'false'}"
        if start_date:
            params += f"&start_date={start_date}"
        if end_date:
            params += f"&end_date={end_date}"
        if today:
            params += f"&today={today}"
        if overdue_behavior:
            params += f"&overdue_behavior={overdue_behavior}"
        return self.get(f"/agenda{params}")

    def create_todo(self, title: str) -> requests.Response:
        """Create a todo using capture with the 'todo' template."""
        return self.capture("todo", {"Title": title})

    def get_templates(self) -> requests.Response:
        """GET /capture-templates"""
        return self.get("/capture-templates")

    def capture(self, template: str, values: dict) -> requests.Response:
        """POST /capture"""
        return self.post("/capture", json={"template": template, "values": values})

    def complete_todo(
        self, todo: dict, state: str = "DONE", override_date: str = None
    ) -> requests.Response:
        """POST /complete

        Args:
            todo: Dict with id, file, pos, title to identify the todo
            state: New state (defaults to DONE)
            override_date: Optional ISO date string (YYYY-MM-DD) to use as effective date
                          for the state change (affects LOGBOOK timestamp)
        """
        payload = {
            "id": todo.get("id"),
            "file": todo.get("file"),
            "pos": todo.get("pos"),
            "title": todo.get("title"),
            "state": state,
        }
        if override_date:
            payload["override_date"] = override_date
        return self.post("/complete", json=payload)

    def set_state(
        self, todo: dict, state: str, override_date: str = None
    ) -> requests.Response:
        """POST /set-state

        More accurately named endpoint for state transitions.

        Args:
            todo: Dict with id, file, pos, title to identify the todo
            state: New state (required)
            override_date: Optional ISO date string (YYYY-MM-DD) to use as effective date
                          for the state change (affects LOGBOOK timestamp)
        """
        payload = {
            "id": todo.get("id"),
            "file": todo.get("file"),
            "pos": todo.get("pos"),
            "title": todo.get("title"),
            "state": state,
        }
        if override_date:
            payload["override_date"] = override_date
        return self.post("/set-state", json=payload)

    def update_todo(self, todo: dict, updates: dict) -> requests.Response:
        """POST /update"""
        return self.post(
            "/update",
            json={
                "id": todo.get("id"),
                "file": todo.get("file"),
                "pos": todo.get("pos"),
                "title": todo.get("title"),
                **updates,
            },
        )

    def delete_todo(
        self, todo: dict, include_children: bool = False
    ) -> requests.Response:
        """POST /delete"""
        payload = {
            "file": todo.get("file"),
            "position": todo.get("pos"),
        }
        if todo.get("id"):
            payload["id"] = todo["id"]
        if include_children:
            payload["include_children"] = True
        return self.post("/delete", json=payload)

    def get_custom_views(self) -> requests.Response:
        """GET /custom-views"""
        return self.get("/custom-views")

    def get_custom_view(self, key: str) -> requests.Response:
        """GET /custom-view with key parameter."""
        return self.get(f"/custom-view?key={key}")

    def get_habit_status(
        self,
        org_id: str,
        preceding: int = None,
        following: int = None,
        date: str = None,
    ) -> requests.Response:
        """GET /habit-status with id and optional range parameters.

        Args:
            org_id: The org ID of the habit
            preceding: Number of intervals before reference date
            following: Number of intervals after reference date
            date: Reference date as YYYY-MM-DD (default: today)
        """
        params = f"?id={org_id}"
        if preceding is not None:
            params += f"&preceding={preceding}"
        if following is not None:
            params += f"&following={following}"
        if date is not None:
            params += f"&date={date}"
        return self.get(f"/habit-status{params}")

    def get_all_habit_statuses(
        self, preceding: int = None, following: int = None, date: str = None
    ) -> requests.Response:
        """GET /all-habit-statuses with optional range parameters.

        Args:
            preceding: Number of intervals before reference date
            following: Number of intervals after reference date
            date: Reference date as YYYY-MM-DD (default: today)
        """
        params = []
        if preceding is not None:
            params.append(f"preceding={preceding}")
        if following is not None:
            params.append(f"following={following}")
        if date is not None:
            params.append(f"date={date}")
        query = f"?{'&'.join(params)}" if params else ""
        return self.get(f"/all-habit-statuses{query}")

    def get_notifications(self, as_of: str = None) -> requests.Response:
        """GET /notifications with optional asOf parameter (ISO datetime)."""
        if as_of is not None:
            return self.get(f"/notifications?asOf={as_of}")
        return self.get("/notifications")

    def reload(self, timeout: float = 10.0) -> requests.Response:
        """GET /reload - Reload all org files from disk and invalidate cache.

        Useful for testing when files are modified externally (e.g., git reset).

        Args:
            timeout: Request timeout in seconds (default 10s)
        """
        return self.get("/reload", timeout=timeout)

    def delete_logbook_entry(
        self, todo: dict, date: str, entry_type: str = None, start: str = None
    ) -> requests.Response:
        """POST /delete-logbook-entry

        Args:
            todo: Dict with id, file, pos to identify the todo
            date: The date of the logbook entry to delete (YYYY-MM-DD)
            entry_type: Optional type filter ("state-change", "note", "clock")
            start: Optional clock start timestamp for precise clock deletion
        """
        payload = {
            "file": todo.get("file"),
            "pos": todo.get("pos"),
            "date": date,
        }
        if todo.get("id"):
            payload["id"] = todo["id"]
        if entry_type:
            payload["type"] = entry_type
        if start:
            payload["start"] = start
        return self.post("/delete-logbook-entry", json=payload)

    def add_clock(self, todo: dict, start: str, end: str) -> requests.Response:
        """POST /add-clock"""
        return self.post(
            "/add-clock",
            json={
                "id": todo.get("id"),
                "file": todo.get("file"),
                "pos": todo.get("pos"),
                "title": todo.get("title"),
                "start": start,
                "end": end,
            },
        )

    def update_clock(
        self, todo: dict, original_start: str, start: str, end: str
    ) -> requests.Response:
        """POST /update-clock"""
        return self.post(
            "/update-clock",
            json={
                "id": todo.get("id"),
                "file": todo.get("file"),
                "pos": todo.get("pos"),
                "title": todo.get("title"),
                "original_start": original_start,
                "start": start,
                "end": end,
            },
        )


def find_free_port() -> int:
    """Find a free port to use for testing."""
    import socket

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("", 0))
        return s.getsockname()[1]


@pytest.fixture(scope="module")
def org_test_dir(tmp_path_factory):
    """Create a temporary directory with test org files.

    Uses fixed dates that match TEST_DATE for deterministic tests.
    """
    test_dir = tmp_path_factory.mktemp("org")
    fixtures_dir = PROJECT_ROOT / "tests" / "fixtures"

    # Copy static fixtures
    for fixture_file in fixtures_dir.glob("*.org"):
        shutil.copy(fixture_file, test_dir / fixture_file.name)
    for fixture_file in fixtures_dir.glob("*.org_archive"):
        shutil.copy(fixture_file, test_dir / fixture_file.name)

    # Create a fixture with the fake "today" date for agenda tests
    today_org = test_dir / "today.org"
    today_org.write_text(f"""\
#+TITLE: Today's Tasks

* TODO Task scheduled for today
  SCHEDULED: <{TEST_DATE_ORG}>

* TODO Task with deadline today
  DEADLINE: <{TEST_DATE_ORG}>

* TODO Task scheduled for tomorrow
  SCHEDULED: <{TEST_DATE_NEXT_DAY_ORG}>

* TODO Task scheduled for yesterday
  SCHEDULED: <{TEST_DATE_PREV_DAY_ORG}>

* TODO Task scheduled with specific time
  SCHEDULED: <{TEST_DATE_ORG} 10:00>

* TODO Task with both scheduled and deadline
  SCHEDULED: <{TEST_DATE_ORG}> DEADLINE: <{TEST_DATE_ORG}>
""")

    # Create projects file for category strategy tests
    projects_org = test_dir / "projects.org"
    projects_org.write_text("""\
#+TITLE: Test Projects

* Project Alpha
** TODO Existing task in Alpha

* Project Beta
** TODO Existing task in Beta
""")

    # Create file with parent/child structure for delete tests
    hierarchy_org = test_dir / "hierarchy.org"
    hierarchy_org.write_text("""\
#+TITLE: Hierarchy Test

* TODO Parent task
** TODO Child task 1
** TODO Child task 2
** TODO Child task 3

* TODO Standalone task
""")

    custom_keywords_org = test_dir / "custom_keywords.org"
    custom_keywords_org.write_text("""\
#+TITLE: Custom Keyword Test
#+TODO: STOCKED VERIFY BUY | PURCHASED SKIPPED

* BUY Coffee beans

* VERIFY Paper towels

* PURCHASED Dish soap
""")

    # Create file for testing include_completed bug
    # This file contains items that should NOT appear with include_completed:
    # - DONE items with LOGBOOK state change but no CLOSED timestamp
    # Bug: the filter passes items with null scheduled/deadline through,
    # even when they have no completedAt.
    state_change_bug_org = test_dir / "state_change_bug.org"
    state_change_bug_org.write_text(f"""\
#+TITLE: State Change Bug Test

* DONE Task with state change log but no CLOSED
  :LOGBOOK:
  - State "DONE"       from "TODO"       [{TEST_DATE_ORG} 10:00]
  :END:
  This task has a state change log for TEST_DATE but no CLOSED timestamp.
  With include_completed=true, this should NOT appear because completedAt is null.

* DONE Task done without any logging
  This is DONE but has no CLOSED, no LOGBOOK, no scheduled, no deadline.
  It should never appear in any agenda.
""")

    # Create file for testing ranged timestamps and plain timestamps
    timestamps_org = test_dir / "timestamps.org"
    timestamps_org.write_text(f"""\
#+TITLE: Timestamp Tests

* TODO Task with ranged schedule
  SCHEDULED: <{TEST_DATE_ORG}>--<{TEST_DATE_NEXT_DAY_ORG}>
  This task spans multiple days.

* TODO Task with same-day scheduled time range
  SCHEDULED: <{TEST_DATE_ORG} 09:00-11:30>
  Meeting scheduled from 9am to 11:30am.

* TODO Task with same-day deadline time range
  DEADLINE: <{TEST_DATE_ORG} 14:00-16:00>
  Must be completed during this window.

* TODO Task with ranged deadline
  DEADLINE: <{TEST_DATE_ORG} 10:00>--<{TEST_DATE_ORG} 14:00>
  This task has a time range deadline.

* TODO Task with plain timestamp in body
  SCHEDULED: <{TEST_DATE_ORG}>
  Meeting notes from <{TEST_DATE_PREV_DAY_ORG} 09:00>.
  Follow up on <{TEST_DATE_NEXT_DAY_ORG}>.

* TODO Task with multiple plain timestamps
  Need to review:
  - First review: <{TEST_DATE_ORG} 10:00>
  - Second review: <{TEST_DATE_ORG} 15:00>
  - Final deadline: <{TEST_DATE_NEXT_DAY_ORG}>

* TODO Task with ranged plain timestamp
  Event runs <{TEST_DATE_ORG}>--<{TEST_DATE_NEXT_DAY_ORG}>.

* TODO Task with no special timestamps
  SCHEDULED: <{TEST_DATE_ORG}>
  Just a regular task with no body timestamps.
""")

    # Create window habits file for window habit tests
    # (named differently from fixtures/habits.org to avoid overwriting it)
    # This habit was completed yesterday and has a deadline for today
    # Note: org-window-habit requires OWH_ prefixed property names
    # Note: org-window-habit uses DEADLINE by default (org-window-habit-repeat-to-deadline is t)
    window_habits_org = test_dir / "window_habits.org"
    window_habits_org.write_text(
        f"""\
#+TITLE: Test Window Habits

* TODO Test Window Habit
  DEADLINE: <{TEST_DATE_ORG} .+1d>
  :PROPERTIES:
  :STYLE: habit
  :OWH_WINDOW_DURATION: 7d
  :OWH_REPETITIONS_REQUIRED: 3
  :ID: test-window-habit-001
  :END:
  :LOGBOOK:
  - State "DONE"       from "TODO"       [{TEST_DATE_PREV_DAY_ORG} 14:00]
  - State "DONE"       from "TODO"       [2024-06-13 Thu 10:00]
  - State "DONE"       from "TODO"       [2024-06-12 Wed 09:00]
  :END:
  This is a test window habit that was completed yesterday.

* TODO Another Window Habit Not Completed Yesterday
  DEADLINE: <{TEST_DATE_ORG} .+1d>
  :PROPERTIES:
  :STYLE: habit
  :OWH_WINDOW_DURATION: 7d
  :OWH_REPETITIONS_REQUIRED: 2
  :ID: test-window-habit-002
  :END:
  :LOGBOOK:
  - State "DONE"       from "TODO"       [2024-06-13 Thu 10:00]
  - State "DONE"       from "TODO"       [2024-06-10 Mon 09:00]
  :END:
  This habit was NOT completed yesterday.

* TODO Paused Window Habit
  DEADLINE: <{TEST_DATE_ORG} .+1d>
  :PROPERTIES:
  :STYLE: habit
  :OWH_CONFIG: (:window-specs ((:duration (:days 7) :repetitions 2)) :until "2024-06-01")
  :ID: test-window-habit-paused
  :END:
  This habit is retained as history but is inactive on the test date.
"""
    )

    # Create DST test habits file for testing across daylight saving transitions
    # These habits started in summer (PDT) and have completions in winter (PST)
    # to test that anchor drift doesn't cause midnight completions to be miscounted
    dst_habits_org = test_dir / "dst_habits.org"
    dst_habits_org.write_text(
        """\
#+TITLE: DST Test Habits

* TODO Habit started in summer for DST testing
  DEADLINE: <2024-01-26 Fri .+1d>
  :PROPERTIES:
  :STYLE: habit
  :OWH_WINDOW_DURATION: 7d
  :OWH_REPETITIONS_REQUIRED: 3
  :OWH_ASSESSMENT_INTERVAL: 1d
  :ID: habit-dst-summer-start
  :CREATED: [2023-08-16 Wed]
  :END:
  :LOGBOOK:
  - State "DONE"       from "TODO"       [2024-11-04 Mon 00:00]
  - State "DONE"       from "TODO"       [2024-11-03 Sun 10:00]
  - State "DONE"       from "TODO"       [2024-11-02 Sat 10:00]
  - State "DONE"       from "TODO"       [2024-03-11 Mon 00:00]
  - State "DONE"       from "TODO"       [2024-03-10 Sun 10:00]
  - State "DONE"       from "TODO"       [2024-03-09 Sat 10:00]
  - State "DONE"       from "TODO"       [2024-01-26 Fri 00:00]
  - State "DONE"       from "TODO"       [2024-01-25 Thu 10:00]
  - State "DONE"       from "TODO"       [2024-01-24 Wed 10:00]
  - State "DONE"       from "TODO"       [2023-08-17 Thu 10:00]
  - State "DONE"       from "TODO"       [2023-08-16 Wed 10:00]
  :END:
  This habit was created in summer 2023 (PDT, UTC-7) and has completions
  at midnight during winter (PST, UTC-8) to test DST handling.
  The midnight completions should be counted for the correct date,
  not the previous day due to anchor drift.
"""
    )

    # Create notifications test file with various notification types
    notifications_org = test_dir / "notifications.org"
    notifications_org.write_text(
        f"""\
#+TITLE: Notification Tests

* TODO Task with timed deadline for relative notification
  DEADLINE: <{TEST_DATE_ORG} 14:00>
  :PROPERTIES:
  :ID: notif-relative-deadline
  :END:
  This task has a deadline with a specific time, should trigger relative notifications.

* TODO Task with timed schedule for relative notification
  SCHEDULED: <{TEST_DATE_ORG} 15:30>
  :PROPERTIES:
  :ID: notif-relative-scheduled
  :END:
  This task has a scheduled time, should trigger relative notifications.

* TODO Task with explicit notify-at time
  SCHEDULED: <{TEST_DATE_ORG} 18:00>
  :PROPERTIES:
  :ID: notif-absolute
  :WILD_NOTIFIER_NOTIFY_AT: <{TEST_DATE_ORG} 12:00>
  :END:
  This task has an explicit NOTIFY_AT time for absolute notification.

* TODO Task with multiple notify-at times
  SCHEDULED: <{TEST_DATE_ORG} 20:00>
  :PROPERTIES:
  :ID: notif-absolute-multiple
  :WILD_NOTIFIER_NOTIFY_AT: <{TEST_DATE_ORG} 11:00> <{TEST_DATE_ORG} 13:00>
  :END:
  This task has multiple explicit NOTIFY_AT times.

* TODO Day-wide task without specific time
  SCHEDULED: <{TEST_DATE_ORG}>
  :PROPERTIES:
  :ID: notif-day-wide
  :END:
  This task is scheduled for today but has no specific time (day-wide).

* TODO Task with custom notify-before intervals
  DEADLINE: <{TEST_DATE_ORG} 16:00>
  :PROPERTIES:
  :ID: notif-custom-intervals
  :WILD_NOTIFIER_NOTIFY_BEFORE: 5 30 60
  :END:
  This task has custom notification intervals: 5, 30, and 60 minutes before.
"""
    )

    # Create inbox file BEFORE git commit so it's tracked
    inbox_org = test_dir / "inbox.org"
    inbox_org.write_text("#+TITLE: Inbox\n\n")

    # Initialize git repo for fixture reset between tests
    subprocess.run(
        ["git", "init"],
        cwd=test_dir,
        capture_output=True,
        check=True,
    )
    # Configure git user for commits (required for some systems)
    subprocess.run(
        ["git", "config", "user.email", "test@test.com"],
        cwd=test_dir,
        capture_output=True,
    )
    subprocess.run(
        ["git", "config", "user.name", "Test User"],
        cwd=test_dir,
        capture_output=True,
    )
    subprocess.run(
        ["git", "add", "."],
        cwd=test_dir,
        capture_output=True,
        check=True,
    )
    subprocess.run(
        ["git", "commit", "-m", "Initial fixtures"],
        cwd=test_dir,
        capture_output=True,
        check=True,
    )

    return test_dir


@pytest.fixture(scope="module")
def inbox_file(org_test_dir):
    """Path to inbox file for capturing new TODOs.

    Note: The file is created in org_test_dir before the git commit
    so that it gets tracked and isn't deleted by git clean.
    """
    return org_test_dir / "inbox.org"


@pytest.fixture(scope="module")
def emacs_server(org_test_dir, inbox_file):
    """Start an Emacs server for the test module."""
    port = find_free_port()
    server = EmacsServer(
        port=port,
        org_dir=org_test_dir,
        inbox_file=inbox_file,
        fake_date=TEST_DATE,
        timezone=TEST_TIMEZONE,
    )
    server.start()
    yield server
    server.stop()


@pytest.fixture
def api(emacs_server, org_test_dir) -> APIClient:
    """HTTP client for making API requests.

    Resets org files to pristine state before each test using git reset,
    then calls /reload to invalidate Emacs's cached buffers.
    """
    import sys

    # Reset org files to initial state before each test
    subprocess.run(
        ["git", "reset", "--hard", "HEAD"],
        cwd=org_test_dir,
        capture_output=True,
    )
    subprocess.run(
        ["git", "clean", "-fd"],
        cwd=org_test_dir,
        capture_output=True,
    )
    # Create client and reload to invalidate Emacs's cached buffers
    client = APIClient(emacs_server.base_url)
    reload_succeeded = False
    try:
        reload_response = client.reload(timeout=5.0)
        if reload_response.status_code == 200:
            reload_succeeded = True
        else:
            print(
                f"[api fixture] WARNING: /reload returned {reload_response.status_code}",
                file=sys.stderr,
            )
    except requests.exceptions.Timeout:
        print("[api fixture] WARNING: /reload timed out", file=sys.stderr)
    except requests.exceptions.ConnectionError as e:
        print(f"[api fixture] WARNING: /reload connection error: {e}", file=sys.stderr)

    # If reload failed, verify server is still responsive with a simple health check
    if not reload_succeeded:
        try:
            # Try a simple GET request to verify server is responsive
            health_response = client.get("/get-all-todos", timeout=5.0)
            if health_response.status_code == 200:
                print(
                    "[api fixture] Server still responsive after reload failure",
                    file=sys.stderr,
                )
            else:
                print(
                    f"[api fixture] WARNING: Health check returned {health_response.status_code}",
                    file=sys.stderr,
                )
        except (requests.exceptions.Timeout, requests.exceptions.ConnectionError) as e:
            print(
                f"[api fixture] ERROR: Server unresponsive after reload failure: {e}",
                file=sys.stderr,
            )
            # Server is hung - tests will likely fail
            # Could potentially restart the server here, but that's complex

    return client


@pytest.fixture
def org_dir(emacs_server, org_test_dir) -> Path:
    """Access to the test org directory (for tests that need to read/modify files)."""
    return org_test_dir
