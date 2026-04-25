"""Integration tests for per-file TODO state metadata."""

from pathlib import Path


def _states_for_file(response_data, filename):
    files = response_data["files"]
    match = next(
        (entry for entry in files if Path(entry["file"]).name == filename),
        None,
    )
    assert match is not None, f"Expected metadata for {filename}: {files}"
    return match["todoStates"]


def _todo_by_title(api, title):
    response = api.get_all_todos()
    assert response.status_code == 200
    todos = response.json()["todos"]
    match = next((todo for todo in todos if todo.get("title") == title), None)
    assert match is not None, f"Expected todo titled {title!r}"
    return match


class TestTodoStatesByFile:
    """Tests for GET /todo-states-by-file."""

    def test_returns_todo_states_for_each_agenda_file(self, api):
        response = api.get("/todo-states-by-file")
        assert response.status_code == 200

        data = response.json()
        assert "files" in data
        assert len(data["files"]) > 0
        assert data.get("errors") == []

    def test_file_local_todo_keywords_are_returned(self, api):
        response = api.get("/todo-states-by-file")
        data = response.json()

        states = _states_for_file(data, "custom_keywords.org")

        assert states["active"] == ["STOCKED", "VERIFY", "BUY"]
        assert states["done"] == ["PURCHASED", "SKIPPED"]

    def test_files_without_local_keywords_use_global_states(self, api):
        response = api.get("/todo-states-by-file")
        data = response.json()

        states = _states_for_file(data, "sample.org")

        assert "TODO" in states["active"]
        assert "STARTED" in states["active"]
        assert "DONE" in states["done"]
        assert "CANCELLED" in states["done"]

    def test_metadata_includes_todo_states_by_file(self, api):
        response = api.get("/metadata")
        assert response.status_code == 200

        data = response.json()
        assert "todoStatesByFile" in data

        states = _states_for_file(data["todoStatesByFile"], "custom_keywords.org")
        assert states["active"] == ["STOCKED", "VERIFY", "BUY"]
        assert states["done"] == ["PURCHASED", "SKIPPED"]

    def test_set_state_accepts_file_local_todo_keyword(self, api):
        todo = _todo_by_title(api, "Coffee beans")
        assert todo["todo"] == "BUY"

        response = api.set_state(todo, "VERIFY")
        assert response.status_code == 200
        data = response.json()

        assert data["status"] == "completed"
        assert data["oldState"] == "BUY"
        assert data["newState"] == "VERIFY"

        updated = _todo_by_title(api, "Coffee beans")
        assert updated["todo"] == "VERIFY"

    def test_update_accepts_file_local_done_keyword(self, api):
        todo = _todo_by_title(api, "Paper towels")
        assert todo["todo"] == "VERIFY"

        response = api.update_todo(todo, {"state": "PURCHASED"})
        assert response.status_code == 200
        data = response.json()

        assert data["status"] == "updated"

        updated = _todo_by_title(api, "Paper towels")
        assert updated["todo"] == "PURCHASED"
