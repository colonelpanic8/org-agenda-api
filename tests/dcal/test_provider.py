"""Tests for the Dux Calendar external provider."""

from __future__ import annotations

import io
import json
from datetime import datetime
from zoneinfo import ZoneInfo


from dcal_provider.__main__ import serve
from dcal_provider.provider import Options, OrgProvider

TZ = ZoneInfo("America/Los_Angeles")
NOW = datetime(2026, 11, 1, 12, 0, tzinfo=TZ)


class FakeClient:
    def __init__(self, todos):
        self.todos = todos
        self.calls: list[tuple[str, str, dict | None]] = []

    def request(self, method, path, *, query=None, body=None):
        self.calls.append((method, path, body))
        if path == "/todo-states":
            return {"active": ["TODO", "NEXT", "STARTED"], "done": ["DONE", "CANCELED"]}
        if path == "/get-all-todos":
            return {"todos": self.todos}
        if path == "/capture":
            self.todos.append(
                {
                    "id": None,
                    "todo": "TODO",
                    "title": body["values"]["Title"],
                    "file": "/org/gtd.org",
                    "pos": 999,
                    "scheduled": body["values"].get("scheduled"),
                }
            )
            return {"status": "created"}
        if path == "/update" and "properties" in body:
            for t in self.todos:
                if t["pos"] == body["pos"]:
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


def provider(todos, **options):
    return OrgProvider(FakeClient(todos), Options(**options), TZ, now=lambda: NOW)


def synced(p):
    return {c["task"]["uid"]: c["task"] for c in p.sync({})["taskChanges"]}


def test_sync_maps_dated_todos_and_filters():
    p = provider(
        [
            todo(),
            todo(
                id="timed",
                scheduled={"date": "2026-11-04", "time": "09:30"},
                deadline={"date": "2026-11-05"},
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
    assert timed["due"] == "2026-11-05T00:00:00+00:00", "deadline wins as due"
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


def test_create_captures_and_assigns_id():
    p = provider([])
    result = p.create_task(
        {"task": {"summary": "Buy soil", "due": "2026-11-07T00:00:00Z", "allDay": True}}
    )
    capture, assign = p.client.writes()
    assert capture == (
        "/capture",
        {
            "template": "default",
            "values": {"Title": "Buy soil", "scheduled": {"date": "2026-11-07"}},
        },
    )
    assert assign[1]["properties"]["ID"] == result["task"]["uid"]
    assert result["task"]["summary"] == "Buy soil"


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
