"""Tests that reproduce the off-by-one date bug using actual system date.

Unlike other tests that use a global fake date override, these tests use
the actual system date to simulate production conditions where the server's
system date differs from the query date.

The bug manifests as:
- Query for yesterday returns items scheduled for today (the server's actual date)
- Items scheduled for the server's "today" appear even when querying other dates

To run these tests, we need a separate fixture that doesn't set the fake date.
"""

import os
import signal
import subprocess
import time
from datetime import date, timedelta
from pathlib import Path

import pytest
import requests


PROJECT_ROOT = Path(__file__).parent.parent


class EmacsServerNoFakeDate:
    """Emacs server WITHOUT fake date override - uses actual system date."""

    def __init__(self, port: int, org_dir: Path, inbox_file: Path):
        self.port = port
        self.org_dir = org_dir
        self.inbox_file = inbox_file
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
        # NOTE: We intentionally do NOT set ORG_AGENDA_API_TEST_FAKE_DATE
        # This makes the server use the actual system date

        script_path = PROJECT_ROOT / "scripts" / "run-emacs-server.el"

        self.process = subprocess.Popen(
            ["emacs", "--batch", "--script", str(script_path)],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )

        start_time = time.time()
        while time.time() - start_time < timeout:
            try:
                response = requests.get(f"{self.base_url}/health", timeout=1)
                if response.status_code == 200:
                    return
            except requests.exceptions.ConnectionError:
                pass

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


def find_free_port() -> int:
    import socket
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("", 0))
        return s.getsockname()[1]


@pytest.fixture(scope="module")
def system_date_test_dir(tmp_path_factory):
    """Create a temp directory with test org files using actual system dates."""
    test_dir = tmp_path_factory.mktemp("org_system_date")

    today = date.today()
    yesterday = today - timedelta(days=1)
    tomorrow = today + timedelta(days=1)

    # Create test file with items for today, yesterday, and tomorrow
    test_org = test_dir / "test.org"
    test_org.write_text(f"""\
#+TITLE: System Date Test

* NEXT Task for today
  SCHEDULED: <{today.strftime('%Y-%m-%d')}>

* TODO Task for yesterday
  SCHEDULED: <{yesterday.strftime('%Y-%m-%d')}>

* TODO Task for tomorrow
  SCHEDULED: <{tomorrow.strftime('%Y-%m-%d')}>
""")

    return test_dir


@pytest.fixture(scope="module")
def system_date_inbox(system_date_test_dir):
    """Inbox file for the test."""
    inbox = system_date_test_dir / "inbox.org"
    inbox.write_text("#+TITLE: Inbox\n\n")
    return inbox


@pytest.fixture(scope="module")
def server_no_fake_date(system_date_test_dir, system_date_inbox):
    """Emacs server using actual system date (no fake date)."""
    port = find_free_port()
    server = EmacsServerNoFakeDate(
        port=port,
        org_dir=system_date_test_dir,
        inbox_file=system_date_inbox,
    )
    server.start()
    yield server
    server.stop()


class TestSystemDateBug:
    """Tests that verify the off-by-one date bug using actual system date.

    These tests reproduce the production bug by not using the global fake date.
    The server uses the actual system date, and we query for different dates.
    """

    def test_query_yesterday_should_not_include_today_items(self, server_no_fake_date):
        """BUG REPRO: Querying for yesterday should NOT include items scheduled for today.

        This is the main bug: when the server's actual date is X and we query
        for X-1 (yesterday), items scheduled for X should NOT appear.
        """
        today = date.today()
        yesterday = today - timedelta(days=1)

        yesterday_str = yesterday.strftime("%Y-%m-%d")
        today_str = today.strftime("%Y-%m-%d")

        response = requests.get(
            f"{server_no_fake_date.base_url}/agenda",
            params={"span": "day", "date": yesterday_str},
        )
        data = response.json()

        # Check that no entry has scheduled date == today
        today_items = []
        for entry in data["entries"]:
            scheduled = entry.get("scheduled", "")[:10]  # Get date part only
            if scheduled == today_str:
                today_items.append({
                    "title": entry.get("title"),
                    "scheduled": entry.get("scheduled"),
                })

        assert len(today_items) == 0, (
            f"BUG CONFIRMED: Query for {yesterday_str} returned items scheduled for "
            f"today ({today_str}):\n{today_items}\n"
            f"This is the off-by-one date bug. Items scheduled for the server's "
            f"actual 'today' appear when querying for other dates."
        )

    def test_query_yesterday_includes_yesterday_items(self, server_no_fake_date):
        """Querying for yesterday SHOULD include items scheduled for yesterday."""
        today = date.today()
        yesterday = today - timedelta(days=1)

        yesterday_str = yesterday.strftime("%Y-%m-%d")

        response = requests.get(
            f"{server_no_fake_date.base_url}/agenda",
            params={"span": "day", "date": yesterday_str},
        )
        data = response.json()

        titles = [e.get("title", "").lower() for e in data["entries"]]

        assert any("yesterday" in t for t in titles), (
            f"Query for {yesterday_str} should include 'Task for yesterday'. "
            f"Found: {titles}"
        )

    def test_query_today_includes_today_items(self, server_no_fake_date):
        """Querying for today SHOULD include items scheduled for today."""
        today = date.today()
        today_str = today.strftime("%Y-%m-%d")

        response = requests.get(
            f"{server_no_fake_date.base_url}/agenda",
            params={"span": "day", "date": today_str},
        )
        data = response.json()

        titles = [e.get("title", "").lower() for e in data["entries"]]

        assert any("today" in t for t in titles), (
            f"Query for {today_str} should include 'Task for today'. "
            f"Found: {titles}"
        )

    def test_query_tomorrow_should_include_tomorrow_items(self, server_no_fake_date):
        """Querying for tomorrow SHOULD include items scheduled for tomorrow."""
        today = date.today()
        tomorrow = today + timedelta(days=1)
        tomorrow_str = tomorrow.strftime("%Y-%m-%d")

        response = requests.get(
            f"{server_no_fake_date.base_url}/agenda",
            params={"span": "day", "date": tomorrow_str},
        )
        data = response.json()

        titles = [e.get("title", "").lower() for e in data["entries"]]

        assert any("tomorrow" in t for t in titles), (
            f"Query for {tomorrow_str} should include 'Task for tomorrow'. "
            f"Found: {titles}"
        )

    def test_query_tomorrow_should_not_include_today_items(self, server_no_fake_date):
        """Querying for tomorrow should NOT include items scheduled for today.

        This tests the opposite direction - future dates shouldn't show
        items from the past.
        """
        today = date.today()
        tomorrow = today + timedelta(days=1)
        tomorrow_str = tomorrow.strftime("%Y-%m-%d")
        today_str = today.strftime("%Y-%m-%d")

        response = requests.get(
            f"{server_no_fake_date.base_url}/agenda",
            params={"span": "day", "date": tomorrow_str},
        )
        data = response.json()

        # Items scheduled for today should NOT appear (they're in the past)
        today_items = [e for e in data["entries"]
                       if e.get("scheduled", "")[:10] == today_str]

        assert len(today_items) == 0, (
            f"Query for {tomorrow_str} should NOT include items scheduled for "
            f"today ({today_str}). Found: {[e.get('title') for e in today_items]}"
        )

    def test_scheduled_dates_are_not_shifted(self, server_no_fake_date):
        """Verify that scheduled dates in response match the actual org file dates.

        This checks that we're not accidentally shifting dates during extraction.
        """
        today = date.today()
        today_str = today.strftime("%Y-%m-%d")

        response = requests.get(
            f"{server_no_fake_date.base_url}/agenda",
            params={"span": "day", "date": today_str},
        )
        data = response.json()

        # Find "Task for today"
        today_entry = None
        for entry in data["entries"]:
            if "today" in entry.get("title", "").lower():
                today_entry = entry
                break

        if today_entry:
            # The scheduled date should be today
            scheduled = today_entry.get("scheduled", "")[:10]
            assert scheduled == today_str, (
                f"'Task for today' should have scheduled={today_str}, "
                f"but got scheduled={scheduled}. "
                f"This indicates date extraction bug."
            )
