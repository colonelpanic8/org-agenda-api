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


class EmacsServer:
    """Manages an Emacs subprocess running org-agenda-api."""

    def __init__(self, port: int, org_dir: Path, inbox_file: Path, fake_date: str):
        self.port = port
        self.org_dir = org_dir
        self.inbox_file = inbox_file
        self.fake_date = fake_date
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

    def __init__(self, base_url: str):
        self.base_url = base_url

    def get(self, path: str, **kwargs) -> requests.Response:
        """Make a GET request."""
        return requests.get(f"{self.base_url}{path}", **kwargs)

    def post(self, path: str, **kwargs) -> requests.Response:
        """Make a POST request."""
        return requests.post(f"{self.base_url}{path}", **kwargs)

    def get_all_todos(self) -> requests.Response:
        """GET /get-all-todos"""
        return self.get("/get-all-todos")

    def get_todays_agenda(self) -> requests.Response:
        """GET /get-todays-agenda"""
        return self.get("/get-todays-agenda")

    def get_agenda(self, span: str = "day", date: str = None, include_overdue: bool = None) -> requests.Response:
        """GET /agenda with optional span, date, and include_overdue parameters."""
        params = f"?span={span}"
        if date:
            params += f"&date={date}"
        if include_overdue is not None:
            params += f"&include_overdue={'true' if include_overdue else 'false'}"
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

    def complete_todo(self, todo: dict, state: str = "DONE") -> requests.Response:
        """POST /complete"""
        return self.post("/complete", json={
            "id": todo.get("id"),
            "file": todo.get("file"),
            "pos": todo.get("pos"),
            "title": todo.get("title"),
            "state": state,
        })

    def update_todo(self, todo: dict, updates: dict) -> requests.Response:
        """POST /update"""
        return self.post("/update", json={
            "id": todo.get("id"),
            "file": todo.get("file"),
            "pos": todo.get("pos"),
            "title": todo.get("title"),
            **updates,
        })

    def delete_todo(self, todo: dict, include_children: bool = False) -> requests.Response:
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

    def get_habit_status(self, org_id: str, preceding: int = None, following: int = None) -> requests.Response:
        """GET /habit-status with id and optional range parameters."""
        params = f"?id={org_id}"
        if preceding is not None:
            params += f"&preceding={preceding}"
        if following is not None:
            params += f"&following={following}"
        return self.get(f"/habit-status{params}")


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

    return test_dir


@pytest.fixture(scope="module")
def inbox_file(org_test_dir):
    """Path to inbox file for capturing new TODOs."""
    inbox = org_test_dir / "inbox.org"
    inbox.write_text("#+TITLE: Inbox\n\n")
    return inbox


@pytest.fixture(scope="module")
def emacs_server(org_test_dir, inbox_file):
    """Start an Emacs server for the test module."""
    port = find_free_port()
    server = EmacsServer(
        port=port,
        org_dir=org_test_dir,
        inbox_file=inbox_file,
        fake_date=TEST_DATE,
    )
    server.start()
    yield server
    server.stop()


@pytest.fixture
def api(emacs_server) -> APIClient:
    """HTTP client for making API requests."""
    return APIClient(emacs_server.base_url)


@pytest.fixture
def org_dir(emacs_server, org_test_dir) -> Path:
    """Access to the test org directory (for tests that need to read/modify files)."""
    return org_test_dir
