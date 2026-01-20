"""
Integration tests for the full container setup including git synchronization.

These tests require Docker and take longer to run. They verify:
- Container builds successfully
- API endpoints work in container context
- Git sync commits changes automatically

Run with: pytest tests/test_container_integration.py -v -s
Skip with: pytest tests/ --ignore=tests/test_container_integration.py
"""

import os
import shutil
import subprocess
import time
from pathlib import Path

import pytest
import requests

# Skip all tests in this module if Docker is not available
pytestmark = pytest.mark.skipif(
    shutil.which("docker") is None,
    reason="Docker not available"
)

PROJECT_ROOT = Path(__file__).parent.parent


def wait_for_server(url: str, timeout: float = 60.0, interval: float = 1.0) -> bool:
    """Wait for server to be ready."""
    start = time.time()
    while time.time() - start < timeout:
        try:
            response = requests.get(url, timeout=2)
            if response.status_code == 200:
                return True
        except requests.exceptions.RequestException:
            pass
        time.sleep(interval)
    return False


def run_command(cmd: list, **kwargs) -> subprocess.CompletedProcess:
    """Run a command and return result."""
    return subprocess.run(cmd, capture_output=True, text=True, **kwargs)


class TestContainerBuild:
    """Tests for container build process."""

    def test_container_builds(self):
        """Container should build without errors."""
        result = run_command(
            ["nix", "build", ".#container", "--no-link", "--print-out-paths"],
            cwd=PROJECT_ROOT
        )
        assert result.returncode == 0, f"Build failed: {result.stderr}"
        assert result.stdout.strip().endswith(".tar.gz")


@pytest.fixture(scope="module")
def container_image():
    """Build and load the container image."""
    # Build container
    result = run_command(
        ["nix", "build", ".#container", "--no-link", "--print-out-paths"],
        cwd=PROJECT_ROOT
    )
    if result.returncode != 0:
        pytest.skip(f"Container build failed: {result.stderr}")

    image_path = result.stdout.strip()

    # Load into Docker
    result = run_command(["docker", "load", "-i", image_path])
    if result.returncode != 0:
        pytest.skip(f"Docker load failed: {result.stderr}")

    # Extract image name from output (format: "Loaded image: name:tag")
    for line in result.stdout.split("\n"):
        if "Loaded image:" in line:
            image_name = line.split("Loaded image:")[-1].strip()
            return image_name

    # Fallback to default name
    return "org-agenda-api:latest"


@pytest.fixture
def git_repo(tmp_path):
    """Create a temporary git repository with a bare remote for testing.

    Sets up:
    - A bare repo to act as the "remote" (origin)
    - A working repo that pushes to the bare repo

    Returns a dict with paths to both repos.
    """
    # Create bare repo (acts as origin) - use fixed path that matches container mount
    bare_path = tmp_path / "bare-repo.git"
    bare_path.mkdir()
    run_command(["git", "init", "--bare"], cwd=bare_path)

    # Create working repo
    repo_path = tmp_path / "org-repo"
    repo_path.mkdir()

    # Initialize git repo
    run_command(["git", "init"], cwd=repo_path)
    run_command(["git", "config", "user.email", "test@test.com"], cwd=repo_path)
    run_command(["git", "config", "user.name", "Test User"], cwd=repo_path)

    # Add bare repo as origin using container path (we'll mount it there)
    run_command(["git", "remote", "add", "origin", "/data/remote.git"], cwd=repo_path)

    # Create initial org file
    inbox = repo_path / "inbox.org"
    inbox.write_text("#+TITLE: Inbox\n\n* TODO Initial task\n")

    # Initial commit
    run_command(["git", "add", "."], cwd=repo_path)
    run_command(["git", "commit", "-m", "Initial commit"], cwd=repo_path)

    # Push to bare repo (using host path for initial setup)
    run_command(["git", "remote", "set-url", "origin", str(bare_path)], cwd=repo_path)
    run_command(["git", "push", "-u", "origin", "master"], cwd=repo_path)
    # Set back to container path
    run_command(["git", "remote", "set-url", "origin", "/data/remote.git"], cwd=repo_path)

    return {"repo": repo_path, "bare": bare_path}


@pytest.fixture
def running_container(container_image, git_repo, tmp_path):
    """Start a container for testing."""
    container_name = f"org-api-test-{os.getpid()}"
    port = 18080  # Use a high port to avoid conflicts

    repo_path = git_repo["repo"]
    bare_path = git_repo["bare"]

    # Start container with both working repo and bare repo mounted
    result = run_command([
        "docker", "run", "-d",
        "--name", container_name,
        "-p", f"{port}:80",
        "-v", f"{repo_path}:/data/org",
        "-v", f"{bare_path}:/data/remote.git",
        "-e", "GIT_SYNC_INTERVAL=2",  # Fast sync for testing
        "-e", "GIT_SYNC_NEW_FILES=true",
        container_image
    ])

    if result.returncode != 0:
        pytest.fail(f"Failed to start container: {result.stderr}")

    container_id = result.stdout.strip()
    base_url = f"http://localhost:{port}"

    # Wait for server to be ready
    if not wait_for_server(f"{base_url}/get-all-todos", timeout=60):
        # Get container logs for debugging
        logs = run_command(["docker", "logs", container_name])
        run_command(["docker", "rm", "-f", container_name])
        pytest.fail(f"Container did not start in time. Logs:\n{logs.stdout}\n{logs.stderr}")

    yield {
        "id": container_id,
        "name": container_name,
        "url": base_url,
        "repo": git_repo,
        "port": port,
    }

    # Cleanup
    run_command(["docker", "rm", "-f", container_name])


class TestContainerAPI:
    """Tests for API endpoints running in container."""

    def test_get_all_todos(self, running_container):
        """GET /get-all-todos should work in container."""
        response = requests.get(f"{running_container['url']}/get-all-todos")
        assert response.status_code == 200
        data = response.json()
        assert isinstance(data, list)
        # Should have the initial task from fixture
        titles = [item.get("title", "") for item in data]
        assert any("Initial task" in t for t in titles)

    def test_create_todo(self, running_container):
        """POST /capture should work in container to create todos."""
        response = requests.post(
            f"{running_container['url']}/capture",
            json={"template": "todo", "values": {"Title": "Container test todo"}}
        )
        assert response.status_code == 200
        data = response.json()
        assert data.get("status") == "captured"

    def test_templates_endpoint(self, running_container):
        """GET /capture-templates should return empty or configured templates."""
        response = requests.get(f"{running_container['url']}/capture-templates")
        assert response.status_code == 200
        # May be empty if no templates configured in container


class TestGitSync:
    """Tests for git synchronization functionality."""

    def test_new_todo_gets_committed(self, running_container):
        """New todos should be committed by git-sync."""
        repo_path = running_container["repo"]["repo"]
        url = running_container["url"]

        # Get initial commit count
        result = run_command(["git", "rev-list", "--count", "HEAD"], cwd=repo_path)
        initial_commits = int(result.stdout.strip())

        # Create a new todo via API
        unique_title = f"Git sync test {time.time()}"
        response = requests.post(
            f"{url}/capture",
            json={"template": "todo", "values": {"Title": unique_title}}
        )
        assert response.status_code == 200

        # Wait for git-sync to commit (interval is 2s, give it some buffer)
        max_wait = 30
        start = time.time()
        new_commits = initial_commits

        while time.time() - start < max_wait:
            result = run_command(["git", "rev-list", "--count", "HEAD"], cwd=repo_path)
            new_commits = int(result.stdout.strip())
            if new_commits > initial_commits:
                break
            time.sleep(1)

        assert new_commits > initial_commits, \
            f"No new commits after {max_wait}s. Expected > {initial_commits}, got {new_commits}"

        # Verify the content is in the repo
        inbox = repo_path / "inbox.org"
        content = inbox.read_text()
        assert unique_title in content, f"Todo not found in inbox:\n{content}"

    def test_multiple_todos_synced(self, running_container):
        """Multiple todos should all be synced."""
        repo_path = running_container["repo"]["repo"]
        url = running_container["url"]

        # Create multiple todos
        todos = [f"Multi-sync test {i} - {time.time()}" for i in range(3)]
        for title in todos:
            response = requests.post(
                f"{url}/capture",
                json={"template": "todo", "values": {"Title": title}}
            )
            assert response.status_code == 200

        # Wait for sync
        time.sleep(10)

        # All should be in the file
        inbox = repo_path / "inbox.org"
        content = inbox.read_text()
        for title in todos:
            assert title in content, f"Todo '{title}' not found in inbox"

        # Check git log for commits
        result = run_command(["git", "log", "--oneline", "-10"], cwd=repo_path)
        print(f"Git log:\n{result.stdout}")


class TestContainerRestart:
    """Tests for container restart functionality."""

    def test_restart_endpoint(self, running_container):
        """POST /restart should trigger container restart via supervisor."""
        url = running_container["url"]
        running_container["name"]

        # Call restart
        response = requests.post(f"{url}/restart")
        assert response.status_code == 200
        data = response.json()
        assert data.get("status") == "restarting"

        # Wait a moment for Emacs to restart
        time.sleep(5)

        # Server should come back up (supervisord restarts it)
        assert wait_for_server(f"{url}/get-all-todos", timeout=30), \
            "Server did not come back after restart"


if __name__ == "__main__":
    pytest.main([__file__, "-v", "-s"])
