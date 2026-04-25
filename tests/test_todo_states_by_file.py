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
