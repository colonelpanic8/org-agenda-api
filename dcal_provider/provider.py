"""Map org-agenda-api TODOs onto the dcal external provider protocol.

Dated TODOs (scheduled or deadline) become VTODO tasks in a single task list.
The org ID is the task UID, so headings without an ID are skipped.
"""

from __future__ import annotations

import hashlib
import json
import uuid
from dataclasses import dataclass
from datetime import UTC, date, datetime, timedelta, tzinfo
from typing import Any, Protocol

PROTOCOL_VERSION = 1
CALENDAR_REMOTE_ID = "org-tasks"

# org priority letters <-> iCalendar PRIORITY (1 highest, 9 lowest, 0 unset).
_PRIORITY_TO_ICAL = {"A": 1, "B": 5, "C": 9}


class Client(Protocol):
    def request(
        self,
        method: str,
        path: str,
        *,
        query: dict[str, str] | None = None,
        body: dict[str, Any] | None = None,
    ) -> dict[str, Any]: ...


@dataclass(frozen=True)
class Options:
    calendar_name: str = "Org agenda"
    include_habits: bool = False
    done_days: int = 7
    capture_template: str = "default"


def _priority_from_ical(value: int | None) -> str | None:
    if not value:
        return None
    if value <= 3:
        return "A"
    if value <= 6:
        return "B"
    return "C"


def _is_habit(todo: dict[str, Any]) -> bool:
    props = todo.get("properties") or {}
    return bool(todo.get("isWindowHabit")) or props.get("STYLE") == "habit"


def _ts_to_rfc3339(ts: dict[str, Any], tz: tzinfo) -> tuple[str, bool]:
    day = date.fromisoformat(ts["date"])
    if not ts.get("time"):
        return datetime(day.year, day.month, day.day, tzinfo=UTC).isoformat(), True
    hour, minute = (int(part) for part in ts["time"].split(":")[:2])
    moment = datetime(day.year, day.month, day.day, hour, minute, tzinfo=tz)
    return moment.isoformat(), False


def _rfc3339_to_ts(value: str, all_day: bool, tz: tzinfo) -> dict[str, str]:
    moment = datetime.fromisoformat(value)
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=UTC)
    if all_day:
        return {"date": moment.astimezone(UTC).date().isoformat()}
    local = moment.astimezone(tz)
    return {"date": local.date().isoformat(), "time": local.strftime("%H:%M")}


def _is_zero_time(value: str | None) -> bool:
    return not value or value.startswith("0001-01-01")


def _completed_at(todo: dict[str, Any], done_states: set[str]) -> datetime | None:
    stamps = [
        entry.get("timestamp")
        for entry in todo.get("logbook") or []
        if entry.get("type") == "state-change" and entry.get("to") in done_states
    ]
    stamps = [s for s in stamps if s]
    if not stamps:
        return None
    return max(datetime.fromisoformat(s) for s in stamps)


def _status(state: str, done_states: set[str]) -> str:
    if state in done_states:
        return "cancelled" if state.upper().startswith("CANCEL") else "completed"
    if state == "STARTED":
        return "in_process"
    return "needs_action"


class OrgProvider:
    def __init__(self, client: Client, options: Options, tz: tzinfo, now=None):
        self.client = client
        self.options = options
        self.tz = tz
        self._now = now or (lambda: datetime.now(tz))
        self._states: dict[str, list[str]] | None = None

    # -- org data -----------------------------------------------------------

    def _todo_states(self) -> dict[str, list[str]]:
        if self._states is None:
            self._states = self.client.request("GET", "/todo-states")
        return self._states

    def _done_states(self) -> set[str]:
        return set(self._todo_states().get("done") or [])

    def _todos(self) -> list[dict[str, Any]]:
        return self.client.request("GET", "/get-all-todos").get("todos") or []

    def _find_todo(self, org_id: str) -> dict[str, Any] | None:
        return next((t for t in self._todos() if t.get("id") == org_id), None)

    def task_from_todo(self, todo: dict[str, Any]) -> dict[str, Any] | None:
        org_id = todo.get("id")
        scheduled, deadline = todo.get("scheduled"), todo.get("deadline")
        if not org_id or not (scheduled or deadline) or not todo.get("todo"):
            return None
        if not self.options.include_habits and _is_habit(todo):
            return None

        done_states = self._done_states()
        state = todo["todo"]
        task: dict[str, Any] = {
            "uid": org_id,
            "remoteId": org_id,
            "summary": todo.get("title") or "",
            "status": _status(state, done_states),
        }
        if state in done_states:
            completed = _completed_at(todo, done_states)
            if completed is None:
                return None
            completed = completed.replace(tzinfo=completed.tzinfo or self.tz)
            if completed < self._now() - timedelta(days=self.options.done_days):
                return None
            task["completed"] = completed.isoformat()

        task["due"], task["allDay"] = _ts_to_rfc3339(deadline or scheduled, self.tz)
        if scheduled and deadline:
            task["start"], _ = _ts_to_rfc3339(scheduled, self.tz)
        if todo.get("priority") in _PRIORITY_TO_ICAL:
            task["priority"] = _PRIORITY_TO_ICAL[todo["priority"]]
        categories = [c for c in [todo.get("effectiveCategory")] if c]
        categories += todo.get("tags") or []
        if categories:
            task["categories"] = categories
        if len(todo.get("olpath") or []) > 1:
            task["description"] = " / ".join(todo["olpath"][:-1])
        return task

    def _tasks(self) -> list[dict[str, Any]]:
        tasks = (self.task_from_todo(t) for t in self._todos())
        return sorted((t for t in tasks if t), key=lambda t: t["uid"])

    def _fresh_task(self, org_id: str, fallback: dict[str, Any]) -> dict[str, Any]:
        todo = self._find_todo(org_id)
        task = self.task_from_todo(todo) if todo else None
        return task or {**fallback, "uid": org_id, "remoteId": org_id}

    # -- protocol methods ---------------------------------------------------

    def initialize(self, _params: dict[str, Any]) -> dict[str, Any]:
        return {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {"events": {"write": False}, "tasks": {"write": True}},
        }

    def list_calendars(self, _params: dict[str, Any]) -> dict[str, Any]:
        return {
            "calendars": [
                {
                    "remoteId": CALENDAR_REMOTE_ID,
                    "name": self.options.calendar_name,
                    "supportedComponents": ["VTODO"],
                }
            ]
        }

    def sync(self, params: dict[str, Any]) -> dict[str, Any]:
        tasks = self._tasks()
        digest = hashlib.sha256(json.dumps(tasks, sort_keys=True).encode()).hexdigest()[
            :32
        ]
        if params.get("token") == digest:
            return {"token": digest, "changes": [], "fullSnapshot": False}
        return {
            "token": digest,
            "changes": [],
            "taskChanges": [{"type": "upsert", "task": t} for t in tasks],
            "fullSnapshot": True,
        }

    def list_events(self, _params: dict[str, Any]) -> dict[str, Any]:
        return {"events": []}

    def create_task(self, params: dict[str, Any]) -> dict[str, Any]:
        task = params["task"]
        values: dict[str, Any] = {"Title": task.get("summary") or "Untitled"}
        if not _is_zero_time(task.get("due")):
            values["scheduled"] = _rfc3339_to_ts(
                task["due"], bool(task.get("allDay")), self.tz
            )
        priority = _priority_from_ical(task.get("priority"))
        if priority:
            values["priority"] = priority
        before = {(t.get("file"), t.get("pos"), t.get("title")) for t in self._todos()}
        self.client.request(
            "POST",
            "/capture",
            body={"template": self.options.capture_template, "values": values},
        )
        created = [
            t
            for t in self._todos()
            if t.get("title") == values["Title"]
            and (t.get("file"), t.get("pos"), t.get("title")) not in before
        ]
        if len(created) != 1:
            raise ProviderError("could not locate the captured org entry")
        entry = created[0]
        org_id = entry.get("id")
        if not org_id:
            org_id = str(uuid.uuid4())
            self.client.request(
                "POST",
                "/update",
                body={
                    "file": entry["file"],
                    "pos": entry["pos"],
                    "title": entry["title"],
                    "strict": True,
                    "properties": {"ID": org_id},
                },
            )
        return {"task": self._fresh_task(org_id, task)}

    def update_task(self, params: dict[str, Any]) -> dict[str, Any]:
        task = params["task"]
        org_id = task.get("remoteId") or task.get("uid")
        current = self._find_todo(org_id) if org_id else None
        if current is None:
            raise ProviderError(f"org entry {org_id!r} not found")

        done_states = self._done_states()
        currently_done = current["todo"] in done_states
        want = task.get("status") or "needs_action"
        body: dict[str, Any] = {}

        if task.get("summary") and task["summary"] != current.get("title"):
            body["new_title"] = task["summary"]

        due_field = "deadline" if current.get("deadline") else "scheduled"
        existing = current.get(due_field)
        if _is_zero_time(task.get("due")):
            if existing:
                body[due_field] = None
        else:
            wanted = _rfc3339_to_ts(task["due"], bool(task.get("allDay")), self.tz)
            if existing and existing.get("repeater"):
                wanted["repeater"] = existing["repeater"]
            if not existing or any(
                wanted.get(k) != existing.get(k) for k in ("date", "time")
            ):
                body[due_field] = wanted

        priority = _priority_from_ical(task.get("priority"))
        if priority != current.get("priority"):
            body["priority"] = priority

        cancel = next((s for s in done_states if s.upper().startswith("CANCEL")), None)
        if want == "cancelled" and cancel and current["todo"] != cancel:
            body["state"] = cancel
        elif want in ("needs_action", "in_process") and currently_done:
            active = self._todo_states().get("active") or []
            body["state"] = (
                "STARTED" if want == "in_process" and "STARTED" in active else "TODO"
            )

        if body:
            self.client.request("POST", "/update", body={"id": org_id, **body})
        if want == "completed" and not currently_done:
            self.client.request("POST", "/complete", body={"id": org_id})
        return {"task": self._fresh_task(org_id, task)}

    def delete_task(self, params: dict[str, Any]) -> None:
        task = params["task"]
        org_id = task.get("remoteId") or task.get("uid")
        self.client.request("POST", "/delete", body={"id": org_id})
        return None

    def handlers(self):
        return {
            "initialize": self.initialize,
            "calendars.list": self.list_calendars,
            "calendar.sync": self.sync,
            "events.list": self.list_events,
            "tasks.create": self.create_task,
            "tasks.update": self.update_task,
            "tasks.delete": self.delete_task,
        }


class ProviderError(RuntimeError):
    pass
