"""HTTP translation tests for the MCP adapter."""

from __future__ import annotations

import base64
import urllib.parse

import pytest

from mcp_server.api import OrgAgendaAPIError, OrgAgendaClient
from mcp_server.config import Config


def client(fake_api) -> OrgAgendaClient:
    return OrgAgendaClient(
        Config(
            base_url=fake_api.url,
            username="test-user",
            password="test-secret",
        )
    )


def test_agenda_request_auth_and_condensation(fake_api) -> None:
    fake_api.enqueue(
        {
            "date": "2026-08-18",
            "span": "day",
            "entries": [
                {
                    "todo": "NEXT",
                    "title": "Write MCP sidecar",
                    "scheduled": {"date": "2026-08-18"},
                    "deadline": None,
                    "priority": "A",
                    "tags": ["code"],
                    "effectiveCategory": "org-agenda-api",
                    "id": "task-id",
                    "file": "/private/tasks.org",
                    "pos": 42,
                    "agendaLine": "private formatted line",
                }
            ],
        }
    )

    result = client(fake_api).agenda(
        span="day", date="2026-08-18", include_overdue=False
    )

    request = fake_api.next_request()
    parsed = urllib.parse.urlsplit(request.path)
    assert request.method == "GET"
    assert parsed.path == "/agenda"
    assert urllib.parse.parse_qs(parsed.query) == {
        "span": ["day"],
        "date": ["2026-08-18"],
        "include_overdue": ["false"],
    }
    encoded = base64.b64encode(b"test-user:test-secret").decode()
    assert request.headers["Authorization"] == f"Basic {encoded}"
    assert result == {
        "date": "2026-08-18",
        "span": "day",
        "entries": [
            {
                "todo": "NEXT",
                "title": "Write MCP sidecar",
                "scheduled": {"date": "2026-08-18"},
                "deadline": None,
                "priority": "A",
                "tags": ["code"],
                "category": "org-agenda-api",
                "id": "task-id",
            }
        ],
    }


def test_week_agenda_is_flattened(fake_api) -> None:
    fake_api.enqueue(
        {
            "span": "week",
            "startDate": "2026-08-17",
            "endDate": "2026-08-23",
            "days": {
                "2026-08-17": [],
                "2026-08-18": [{"todo": "TODO", "title": "Tuesday task", "tags": []}],
            },
        }
    )

    result = client(fake_api).agenda(span="week", date="2026-08-17")

    assert result["date"] == "2026-08-17"
    assert [entry["title"] for entry in result["entries"]] == ["Tuesday task"]


def test_capture_uses_gtd_template_and_omits_unset_values(fake_api) -> None:
    fake_api.enqueue(
        {
            "status": "created",
            "template": "capture-g",
            "file": "/private/inbox.org",
        }
    )

    result = client(fake_api).capture(
        {
            "title": "Call the dentist",
            "scheduled": "2026-08-19T09:30",
            "priority": "B",
            "tags": ["phone", "health"],
        }
    )

    request = fake_api.next_request()
    assert request.method == "POST"
    assert request.path == "/capture"
    assert request.body == {
        "template": "capture-g",
        "values": {
            "Title": "Call the dentist",
            "todo": "TODO",
            "scheduled": {"date": "2026-08-19", "time": "09:30"},
            "priority": "B",
            "tags": ["phone", "health"],
        },
    }
    assert result == {"status": "created", "template": "capture-g"}


def test_complete_request_and_trimmed_response(fake_api) -> None:
    fake_api.enqueue(
        {
            "status": "completed",
            "title": "Call the dentist",
            "oldState": "TODO",
            "newState": "DONE",
            "file": "/private/inbox.org",
        }
    )

    result = client(fake_api).complete(
        {"title": "Call the dentist", "id": "task-id", "state": "DONE"}
    )

    assert fake_api.next_request().body == {
        "title": "Call the dentist",
        "id": "task-id",
        "state": "DONE",
    }
    assert result == {
        "status": "completed",
        "title": "Call the dentist",
        "oldState": "TODO",
        "newState": "DONE",
    }


def test_update_preserves_omitted_fields_and_translates_null_tags(fake_api) -> None:
    fake_api.enqueue(
        {
            "status": "updated",
            "title": "Call the dentist",
            "updates": {"scheduled": None, "tags": []},
            "file": "/private/inbox.org",
            "pos": 12,
        }
    )

    result = client(fake_api).update(
        {
            "title": "Call the dentist",
            "id": "task-id",
            "scheduled": None,
            "tags": None,
        }
    )

    assert fake_api.next_request().body == {
        "title": "Call the dentist",
        "id": "task-id",
        "scheduled": None,
        "tags": [],
    }
    assert result == {
        "status": "updated",
        "title": "Call the dentist",
        "updates": {"scheduled": None, "tags": []},
    }


@pytest.mark.parametrize("status", [200, 500])
def test_api_errors_become_safe_tool_messages(fake_api, status: int) -> None:
    fake_api.enqueue(
        {"status": "error", "message": "upstream rejected test-secret"},
        status=status,
    )

    with pytest.raises(OrgAgendaAPIError) as raised:
        client(fake_api).complete({"title": "Missing"})

    assert "[REDACTED]" in str(raised.value)
    assert "test-secret" not in str(raised.value)
    if status == 500:
        assert "HTTP 500" in str(raised.value)


def test_redirect_is_a_non_success_without_forwarding_auth(fake_api) -> None:
    fake_api.enqueue({"message": "unexpected redirect"}, status=302)

    with pytest.raises(OrgAgendaAPIError, match="HTTP 302: unexpected redirect"):
        client(fake_api).agenda()


def test_invalid_json_is_an_error_without_echoing_body(fake_api) -> None:
    fake_api.enqueue_raw(b"not json and test-secret")

    with pytest.raises(OrgAgendaAPIError, match="invalid JSON") as raised:
        client(fake_api).agenda()

    assert "test-secret" not in str(raised.value)


def test_timeout_is_mapped_to_an_api_error(fake_api) -> None:
    fake_api.enqueue({"date": "2026-08-18", "span": "day", "entries": []}, delay=0.1)
    timed_client = OrgAgendaClient(
        Config(
            base_url=fake_api.url,
            username="test-user",
            password="test-secret",
            timeout=0.01,
        )
    )

    with pytest.raises(OrgAgendaAPIError, match="timed out after 0.01 seconds"):
        timed_client.agenda()


@pytest.mark.parametrize("value", ["tomorrow", "2026-02-30", "2026-08-18T25:00"])
def test_invalid_timestamps_are_rejected_before_http(fake_api, value: str) -> None:
    with pytest.raises(OrgAgendaAPIError, match="timestamp"):
        client(fake_api).capture({"title": "Bad date", "scheduled": value})
