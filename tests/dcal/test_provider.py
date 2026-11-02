"""Tests for the Dux Calendar external provider."""

from __future__ import annotations

import io
import json
from datetime import datetime
from zoneinfo import ZoneInfo


from dcal_provider.__main__ import serve
import pytest

from dcal_provider.provider import Options, OrgProvider, ProviderError

TZ = ZoneInfo("America/Los_Angeles")
NOW = datetime(2026, 11, 1, 12, 0, tzinfo=TZ)


class FakeClient:
    def __init__(self, todos, capture_returns_id=True):
        self.todos = todos
        self.capture_returns_id = capture_returns_id
        self.calls: list[tuple[str, str, dict | None]] = []

    def request(self, method, path, *, query=None, body=None):
        self.calls.append((method, path, body))
        if path == "/todo-states":
            return {"active": ["TODO", "NEXT", "STARTED"], "done": ["DONE", "CANCELED"]}
        if path == "/get-all-todos":
            return {"todos": self.todos}
        if path == "/capture":
            new = {
                "id": "captured-id" if self.capture_returns_id else None,
                "todo": "TODO",
                "title": body["values"]["Title"],
                "file": "/org/gtd.org",
                "pos": 1,
                "scheduled": body["values"].get("scheduled"),
            }
            for t in self.todos:
                if t["file"] == new["file"]:
                    t["pos"] += 50
            self.todos.append(new)
            if self.capture_returns_id and body.get("assign_id"):
                return {"status": "created", "id": "captured-id"}
            return {"status": "created"}
        if path == "/update" and "properties" in body:
            for t in self.todos:
                if (t["file"], t["pos"]) == (body["file"], body["pos"]):
                    t["id"] = body["properties"]["ID"]
        return {"status": "ok"}

    def writes(self):
        return [(p, b) for m, p, b in self.calls if m == "POST"]


def todo(**overrides):
    base = {
        "id": "id-1",
        "todo": "TODO",
        "title": "Water plants",
        "file": "/org/gtd.org",
        "pos": 10,
        "scheduled": {"date": "2026-11-03"},
        "deadline": None,
        "priority": None,
        "tags": None,
        "effectiveCategory": "gtd",
        "olpath": ["Home", "Water plants"],
        "isWindowHabit": False,
        "properties": {},
    }
    return {**base, **overrides}


def provider(todos, client=None, **options):
    return OrgProvider(
        client or FakeClient(todos), Options(**options), TZ, now=lambda: NOW
    )


def synced(p):
    return {c["task"]["uid"]: c["task"] for c in p.sync({})["taskChanges"]}


def test_sync_maps_dated_todos_and_filters():
    p = provider(
        [
            todo(),
            todo(
                id="timed",
                scheduled={"date": "2026-11-04", "time": "09:30"},
                deadline={"date": "2026-11-05", "time": "17:00"},
                priority="A",
                tags=["work"],
            ),
            todo(id=None),
            todo(id="undated", scheduled=None),
            todo(id="habit", properties={"STYLE": "habit"}),
            todo(
                id="old-done",
                todo="DONE",
                logbook=[
                    {
                        "type": "state-change",
                        "to": "DONE",
                        "timestamp": "2026-10-01T10:00:00",
                    }
                ],
            ),
            todo(
                id="recent-done",
                todo="DONE",
                logbook=[
                    {
                        "type": "state-change",
                        "to": "DONE",
                        "timestamp": "2026-10-30T10:00:00",
                    }
                ],
            ),
        ]
    )
    tasks = synced(p)
    assert set(tasks) == {"id-1", "timed", "recent-done"}
    assert tasks["id-1"] | {} == {
        "uid": "id-1",
        "remoteId": "id-1",
        "summary": "Water plants",
        "status": "needs_action",
        "due": "2026-11-03T00:00:00+00:00",
        "allDay": True,
        "categories": ["gtd"],
        "description": "Home",
    }
    timed = tasks["timed"]
    assert timed["due"] == "2026-11-05T17:00:00-08:00", "deadline wins as due"
    assert timed["allDay"] is False
    assert timed["start"] == "2026-11-04T09:30:00-08:00"
    assert timed["priority"] == 1
    assert timed["categories"] == ["gtd", "work"]
    assert tasks["recent-done"]["status"] == "completed"


def test_sync_token_skips_unchanged_snapshot():
    p = provider([todo()])
    first = p.sync({})
    assert first["fullSnapshot"]
    again = p.sync({"token": first["token"]})
    assert again == {"token": first["token"], "changes": [], "fullSnapshot": False}


def test_update_completes_and_reschedules_preserving_repeater():
    p = provider(
        [
            todo(
                scheduled={
                    "date": "2026-11-03",
                    "repeater": {"type": ".+", "value": 3, "unit": "day"},
                }
            )
        ]
    )
    task = synced(p)["id-1"]
    p.update_task(
        {"task": {**task, "status": "completed", "due": "2026-11-06T00:00:00Z"}}
    )
    assert p.client.writes() == [
        (
            "/update",
            {
                "id": "id-1",
                "scheduled": {
                    "date": "2026-11-06",
                    "repeater": {"type": ".+", "value": 3, "unit": "day"},
                },
            },
        ),
        ("/complete", {"id": "id-1"}),
    ]


def test_update_noop_sends_nothing():
    p = provider([todo(priority="B")])
    p.update_task({"task": synced(p)["id-1"]})
    assert p.client.writes() == []


def test_update_reopens_and_retitles_timed_task():
    p = provider(
        [
            todo(
                todo="DONE",
                scheduled={"date": "2026-11-03", "time": "08:00"},
                logbook=[
                    {
                        "type": "state-change",
                        "to": "DONE",
                        "timestamp": "2026-10-31T10:00:00",
                    }
                ],
            )
        ]
    )
    task = synced(p)["id-1"]
    p.update_task(
        {
            "task": {
                **task,
                "status": "needs_action",
                "summary": "Water ferns",
                "due": "2026-11-03T17:00:00Z",
                "allDay": False,
            }
        }
    )
    assert p.client.writes() == [
        (
            "/update",
            {
                "id": "id-1",
                "new_title": "Water ferns",
                "state": "TODO",
                "scheduled": {"date": "2026-11-03", "time": "09:00"},
            },
        ),
    ]


def test_create_uses_id_assigned_by_capture():
    p = provider([])
    result = p.create_task(
        {"task": {"summary": "Buy soil", "due": "2026-11-07T00:00:00Z", "allDay": True}}
    )
    assert p.client.writes() == [
        (
            "/capture",
            {
                "template": "default",
                "values": {"Title": "Buy soil", "scheduled": {"date": "2026-11-07"}},
                "assign_id": True,
            },
        )
    ]
    assert result["task"]["uid"] == "captured-id"


def test_create_identifies_capture_on_servers_without_ids():
    # Same-titled ID-less entry elsewhere whose position shifts on insert.
    existing = todo(id=None, title="Buy soil", file="/org/other.org", pos=1)
    client = FakeClient([existing], capture_returns_id=False)
    p = provider(None, client=client)
    result = p.create_task({"task": {"summary": "Buy soil"}})
    _, assign = client.writes()
    assert assign[1]["file"] == "/org/gtd.org"
    assert result["task"]["uid"] == assign[1]["properties"]["ID"]
    assert existing["id"] is None


def test_create_refuses_to_guess_between_identical_entries():
    existing = todo(id=None, title="Buy soil", pos=10)
    client = FakeClient([existing], capture_returns_id=False)
    with pytest.raises(ProviderError, match="could not be identified"):
        provider(None, client=client).create_task({"task": {"summary": "Buy soil"}})
    assert [p for p, _ in client.writes()] == ["/capture"]


@pytest.mark.parametrize(
    ("state", "want", "writes"),
    [
        ("TODO", "in_process", [("/update", {"id": "id-1", "state": "STARTED"})]),
        ("STARTED", "needs_action", [("/update", {"id": "id-1", "state": "TODO"})]),
        ("WAIT", "needs_action", []),
        ("TODO", "cancelled", [("/update", {"id": "id-1", "state": "CANCELED"})]),
        ("TODO", "completed", [("/complete", {"id": "id-1"})]),
    ],
)
def test_update_status_transitions(state, want, writes):
    p = provider([todo(todo=state)])
    task = p.task_from_todo(todo(todo=state))
    p.update_task({"task": {**task, "status": want}})
    assert p.client.writes() == writes


def test_update_completes_cancelled_task():
    done = todo(
        todo="CANCELED",
        logbook=[
            {
                "type": "state-change",
                "to": "CANCELED",
                "timestamp": "2026-10-31T10:00:00",
            }
        ],
    )
    p = provider([done])
    p.update_task({"task": {**synced(p)["id-1"], "status": "completed"}})
    assert p.client.writes() == [("/complete", {"id": "id-1"})]


def test_update_rejects_status_without_matching_state():
    class NoStarted(FakeClient):
        def request(self, method, path, **kwargs):
            if path == "/todo-states":
                return {"active": ["TODO"], "done": ["DONE"]}
            return super().request(method, path, **kwargs)

    p = provider(None, client=NoStarted([todo()]))
    with pytest.raises(ProviderError, match="in_process"):
        p.update_task({"task": {**synced(p)["id-1"], "status": "in_process"}})
    assert p.client.writes() == []


@pytest.mark.parametrize("response", [{}, {"todos": None}, {"todos": [1]}])
def test_sync_fails_on_malformed_todos(response):
    class Broken(FakeClient):
        def request(self, method, path, **kwargs):
            if path == "/get-all-todos":
                return response
            return super().request(method, path, **kwargs)

    with pytest.raises(ProviderError):
        provider(None, client=Broken([])).sync({})


def test_timed_schedule_is_not_paired_with_all_day_deadline():
    p = provider(
        [
            todo(
                scheduled={"date": "2026-11-04", "time": "09:30"},
                deadline={"date": "2026-11-05"},
            )
        ]
    )
    task = synced(p)["id-1"]
    assert task["allDay"] is True
    assert "start" not in task


def test_serve_reports_errors_per_request():
    p = provider([])
    stdin = io.StringIO(
        '{"jsonrpc":"2.0","method":"note"}\n'
        '{"jsonrpc":"2.0","id":1,"method":"nope"}\n'
        '{"jsonrpc":"2.0","id":2,"method":"tasks.update","params":{"task":{"uid":"missing"}}}\n'
        '{"jsonrpc":"2.0","id":3,"method":"initialize","params":{}}\n'
    )
    stdout = io.StringIO()
    serve(p, stdin, stdout)
    replies = [json.loads(line) for line in stdout.getvalue().splitlines()]
    assert [r["id"] for r in replies] == [1, 2, 3]
    assert replies[0]["error"]["code"] == -32601
    assert "not found" in replies[1]["error"]["message"]
    assert replies[2]["result"]["protocolVersion"] == 1
