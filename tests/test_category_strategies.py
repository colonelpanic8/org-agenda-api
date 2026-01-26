"""Tests for category strategy endpoints."""

import pytest


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


@pytest.fixture
def has_projects_strategy(api):
    """Check if the 'projects' strategy is registered."""
    response = api.get("/category-types")
    data = response.json()
    type_names = [t["name"] for t in data.get("types", [])]
    return "projects" in type_names


class TestCategoryTypes:
    """Tests for GET /category-types endpoint."""

    def test_returns_200(self, api):
        """Endpoint returns 200 status."""
        response = api.get("/category-types")
        assert response.status_code == 200

    def test_returns_json(self, api):
        """Endpoint returns valid JSON."""
        response = api.get("/category-types")
        data = response.json()
        assert isinstance(data, dict)

    def test_has_types_array(self, api):
        """Response has types array."""
        response = api.get("/category-types")
        data = response.json()
        assert "types" in data
        assert isinstance(data["types"], list)

    def test_projects_strategy_registered(self, api, has_projects_strategy):
        """The test environment has a 'projects' strategy registered."""
        if not has_projects_strategy:
            pytest.skip("org-category-capture not available in test environment")
        response = api.get("/category-types")
        data = response.json()
        type_names = [t["name"] for t in data["types"]]
        assert "projects" in type_names

    def test_projects_strategy_has_categories(self, api, has_projects_strategy):
        """The projects strategy indicates it has categories."""
        if not has_projects_strategy:
            pytest.skip("org-category-capture not available in test environment")
        response = api.get("/category-types")
        data = response.json()
        projects_type = next(
            (t for t in data["types"] if t["name"] == "projects"), None
        )
        assert projects_type is not None
        assert projects_type["hasCategories"] is True


class TestCategoriesEndpoint:
    """Tests for GET /categories endpoint."""

    def test_returns_200(self, api):
        """Endpoint returns 200 status even with missing params."""
        response = api.get("/categories")
        assert response.status_code == 200

    def test_missing_type_returns_error(self, api):
        """Missing type parameter returns error."""
        response = api.get("/categories")
        data = response.json()
        assert data.get("status") == "error"
        assert "type" in data.get("message", "").lower()

    def test_unknown_type_returns_error(self, api):
        """Unknown strategy type returns error."""
        response = api.get("/categories?type=nonexistent")
        data = response.json()
        assert data.get("status") == "error"
        assert "unknown" in data.get("message", "").lower()

    def test_projects_returns_categories(self, api, has_projects_strategy):
        """The projects strategy returns Project Alpha and Project Beta."""
        if not has_projects_strategy:
            pytest.skip("org-category-capture not available in test environment")
        response = api.get("/categories?type=projects")
        data = response.json()
        assert data.get("type") == "projects"
        assert "categories" in data
        categories = data["categories"]
        assert "Project Alpha" in categories
        assert "Project Beta" in categories

    def test_projects_returns_todo_files(self, api, has_projects_strategy):
        """The projects strategy returns the projects.org file."""
        if not has_projects_strategy:
            pytest.skip("org-category-capture not available in test environment")
        response = api.get("/categories?type=projects")
        data = response.json()
        assert "todoFiles" in data
        assert len(data["todoFiles"]) > 0
        assert any("projects.org" in f for f in data["todoFiles"])


class TestCategoryTasksEndpoint:
    """Tests for GET /category-tasks endpoint."""

    def test_returns_200(self, api):
        """Endpoint returns 200 status even with missing params."""
        response = api.get("/category-tasks")
        assert response.status_code == 200

    def test_missing_type_returns_error(self, api):
        """Missing type parameter returns error."""
        response = api.get("/category-tasks")
        data = response.json()
        assert data.get("status") == "error"
        assert "type" in data.get("message", "").lower()

    def test_missing_category_returns_error(self, api):
        """Missing category parameter returns error."""
        response = api.get("/category-tasks?type=sometype")
        data = response.json()
        # First it should check for type validity, then category
        # Since 'sometype' doesn't exist, we get unknown strategy error
        assert data.get("status") == "error"

    def test_unknown_type_returns_error(self, api):
        """Unknown strategy type returns error."""
        response = api.get("/category-tasks?type=nonexistent&category=test")
        data = response.json()
        assert data.get("status") == "error"
        assert "unknown" in data.get("message", "").lower()

    def test_get_tasks_for_project_alpha(self, api, has_projects_strategy):
        """Can retrieve tasks for Project Alpha."""
        if not has_projects_strategy:
            pytest.skip("org-category-capture not available in test environment")
        response = api.get("/category-tasks?type=projects&category=Project%20Alpha")
        data = response.json()
        assert data.get("type") == "projects"
        assert data.get("category") == "Project Alpha"
        assert "tasks" in data
        # Should have the existing task
        tasks = data["tasks"]
        assert isinstance(tasks, list)
        task_titles = [t.get("title") for t in tasks]
        assert "Existing task in Alpha" in task_titles

    def test_get_tasks_for_project_beta(self, api, has_projects_strategy):
        """Can retrieve tasks for Project Beta."""
        if not has_projects_strategy:
            pytest.skip("org-category-capture not available in test environment")
        response = api.get("/category-tasks?type=projects&category=Project%20Beta")
        data = response.json()
        assert data.get("category") == "Project Beta"
        tasks = data["tasks"]
        task_titles = [t.get("title") for t in tasks]
        assert "Existing task in Beta" in task_titles


class TestCategoryCaptureEndpoint:
    """Tests for POST /category-capture endpoint."""

    def test_returns_200(self, api):
        """Endpoint returns 200 status even with missing params."""
        response = api.post("/category-capture", json={})
        assert response.status_code == 200

    def test_missing_type_returns_error(self, api):
        """Missing type parameter returns error."""
        response = api.post(
            "/category-capture", json={"category": "test", "title": "Test"}
        )
        data = response.json()
        assert data.get("status") == "error"
        assert "type" in data.get("message", "").lower()

    def test_missing_category_returns_error(self, api):
        """Missing category parameter returns error."""
        response = api.post(
            "/category-capture", json={"type": "projects", "title": "Test"}
        )
        data = response.json()
        assert data.get("status") == "error"
        assert "category" in data.get("message", "").lower()

    def test_missing_title_returns_error(self, api):
        """Missing title parameter returns error."""
        response = api.post(
            "/category-capture", json={"type": "projects", "category": "test"}
        )
        data = response.json()
        assert data.get("status") == "error"
        assert "title" in data.get("message", "").lower()

    def test_unknown_type_returns_error(self, api):
        """Unknown strategy type returns error."""
        response = api.post(
            "/category-capture",
            json={"type": "nonexistent", "category": "test", "title": "Test Task"},
        )
        data = response.json()
        assert data.get("status") == "error"
        assert "unknown" in data.get("message", "").lower()

    def test_capture_basic_todo(self, api, has_projects_strategy):
        """Can capture a basic TODO to a category."""
        if not has_projects_strategy:
            pytest.skip("org-category-capture not available in test environment")
        response = api.post(
            "/category-capture",
            json={
                "type": "projects",
                "category": "Project Alpha",
                "title": "New task from API",
            },
        )
        data = response.json()
        assert data.get("status") == "created"
        assert data.get("category") == "Project Alpha"
        assert data.get("title") == "New task from API"
        assert "file" in data
        assert "projects.org" in data["file"]

    def test_captured_todo_appears_in_tasks(self, api, has_projects_strategy):
        """A captured TODO appears when querying category tasks."""
        if not has_projects_strategy:
            pytest.skip("org-category-capture not available in test environment")
        # First capture a uniquely named task
        unique_title = "Unique test task for verification"
        response = api.post(
            "/category-capture",
            json={
                "type": "projects",
                "category": "Project Beta",
                "title": unique_title,
            },
        )
        assert response.json().get("status") == "created"

        # Now query tasks for that category
        response = api.get("/category-tasks?type=projects&category=Project%20Beta")
        data = response.json()
        task_titles = [t.get("title") for t in data["tasks"]]
        assert unique_title in task_titles

    def test_capture_with_priority(self, api, has_projects_strategy):
        """Can capture a TODO with priority."""
        if not has_projects_strategy:
            pytest.skip("org-category-capture not available in test environment")
        response = api.post(
            "/category-capture",
            json={
                "type": "projects",
                "category": "Project Alpha",
                "title": "High priority task",
                "priority": "A",
            },
        )
        data = response.json()
        assert data.get("status") == "created"

        # Verify the task has the priority
        response = api.get("/category-tasks?type=projects&category=Project%20Alpha")
        tasks = response.json()["tasks"]
        task = next((t for t in tasks if t.get("title") == "High priority task"), None)
        assert task is not None
        assert task.get("priority") == "A"

    def test_capture_with_scheduled(self, api, has_projects_strategy):
        """Can capture a TODO with scheduled date."""
        if not has_projects_strategy:
            pytest.skip("org-category-capture not available in test environment")
        # Use new object format for scheduled timestamp
        response = api.post(
            "/category-capture",
            json={
                "type": "projects",
                "category": "Project Alpha",
                "title": "Scheduled task",
                "scheduled": {"date": "2024-07-01"},
            },
        )
        data = response.json()
        assert data.get("status") == "created", f"Expected 'created', got: {data}"

        # Verify the task has the scheduled date
        response = api.get("/category-tasks?type=projects&category=Project%20Alpha")
        tasks = response.json()["tasks"]
        task = next((t for t in tasks if t.get("title") == "Scheduled task"), None)
        assert task is not None
        assert task.get("scheduled") is not None
        assert extract_date(task.get("scheduled")) == "2024-07-01"

    def test_capture_with_tags(self, api, has_projects_strategy):
        """Can capture a TODO with tags."""
        if not has_projects_strategy:
            pytest.skip("org-category-capture not available in test environment")
        response = api.post(
            "/category-capture",
            json={
                "type": "projects",
                "category": "Project Beta",
                "title": "Tagged task",
                "tags": ["urgent", "bug"],
            },
        )
        data = response.json()
        assert data.get("status") == "created"

        # Verify the task has the tags
        response = api.get("/category-tasks?type=projects&category=Project%20Beta")
        tasks = response.json()["tasks"]
        task = next((t for t in tasks if t.get("title") == "Tagged task"), None)
        assert task is not None
        assert "urgent" in task.get("tags", [])
        assert "bug" in task.get("tags", [])
