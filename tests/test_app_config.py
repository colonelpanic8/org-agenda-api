"""Integration tests for the /app-config JSON storage endpoints."""

import json


MOVA_CONFIG = {
    "todoStateColors": {
        "TODO": "#e06c75",
        "DONE": "theme:primary",
    },
    "version": 1,
}


class TestAppConfig:
    """Tests for GET/POST /app-config."""

    def test_list_namespaces_empty(self, api):
        response = api.get("/app-config")
        assert response.status_code == 200
        assert response.json() == {"namespaces": []}

    def test_get_missing_namespace(self, api):
        response = api.get("/app-config/mova")
        assert response.status_code == 200

        data = response.json()
        assert data["namespace"] == "mova"
        assert data["exists"] is False
        assert data["config"] is None

    def test_store_and_read_config(self, api):
        response = api.post("/app-config/mova", json=MOVA_CONFIG)
        assert response.status_code == 200
        assert response.json() == {"status": "ok", "namespace": "mova"}

        response = api.get("/app-config/mova")
        data = response.json()
        assert data["exists"] is True
        assert data["config"] == MOVA_CONFIG

    def test_store_writes_file_in_org_repo(self, api, org_dir):
        api.post("/app-config/mova", json=MOVA_CONFIG)

        config_file = org_dir / ".app-config" / "mova.json"
        assert config_file.exists()
        assert json.loads(config_file.read_text()) == MOVA_CONFIG

    def test_overwrite_replaces_config(self, api):
        api.post("/app-config/mova", json=MOVA_CONFIG)
        api.post("/app-config/mova", json={"other": True})

        response = api.get("/app-config/mova")
        assert response.json()["config"] == {"other": True}

    def test_namespaces_listed_after_store(self, api):
        api.post("/app-config/mova", json=MOVA_CONFIG)
        api.post("/app-config/other-app", json={"a": 1})

        response = api.get("/app-config")
        assert sorted(response.json()["namespaces"]) == ["mova", "other-app"]

    def test_json_types_round_trip(self, api):
        config = {
            "string": "value",
            "number": 3.5,
            "int": 7,
            "bool": True,
            "false": False,
            "null": None,
            "array": [1, "two", {"three": 3}],
            "nested": {"empty_object": {}, "empty_array": []},
        }
        api.post("/app-config/mova", json=config)

        response = api.get("/app-config/mova")
        assert response.json()["config"] == config

    def test_unicode_json_round_trip(self, api):
        config = {"label": "Unicode “smart quotes” café ☕"}

        response = api.post("/app-config/mova", json=config)
        assert response.status_code == 200

        response = api.get("/app-config/mova")
        assert response.json()["config"] == config

    def test_invalid_namespace_rejected(self, api):
        response = api.post("/app-config/..%2fevil", json={"a": 1})
        assert response.status_code == 200
        data = response.json()
        assert data["status"] == "error"
        assert "Invalid namespace" in data["message"]

    def test_invalid_json_body_rejected(self, api):
        response = api.post("/app-config/mova", data="not json {")
        assert response.status_code == 200
        assert response.json()["status"] == "error"

        response = api.get("/app-config/mova")
        assert response.json()["exists"] is False

    def test_metadata_includes_app_config(self, api):
        api.post("/app-config/mova", json=MOVA_CONFIG)

        response = api.get("/metadata")
        assert response.status_code == 200

        data = response.json()
        assert data["appConfig"] == {"mova": MOVA_CONFIG}
