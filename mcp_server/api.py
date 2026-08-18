"""HTTP translation layer for org-agenda-api MCP tools."""

from __future__ import annotations

import base64
import json
import re
import socket
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime
from typing import Any

from .config import Config

_TIMESTAMP_RE = re.compile(r"^(?P<date>\d{4}-\d{2}-\d{2})(?:T(?P<time>\d{2}:\d{2}))?$")
_AGENDA_FIELDS = (
    "todo",
    "title",
    "scheduled",
    "deadline",
    "priority",
    "tags",
)


class OrgAgendaAPIError(RuntimeError):
    """A safe-to-display failure from the upstream HTTP API."""


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Treat redirects as errors and never forward Basic Auth elsewhere."""

    def redirect_request(self, *_args: Any, **_kwargs: Any) -> None:
        return None


class OrgAgendaClient:
    """Small synchronous JSON client for the existing HTTP API."""

    def __init__(self, config: Config):
        self.config = config
        credentials = f"{config.username}:{config.password}".encode()
        self._authorization = "Basic " + base64.b64encode(credentials).decode()
        self._opener = urllib.request.build_opener(_NoRedirect)

    def agenda(
        self,
        span: str = "day",
        date: str | None = None,
        include_overdue: bool | None = None,
    ) -> dict[str, Any]:
        query: dict[str, str] = {"span": span}
        if date is not None:
            query["date"] = date
        if include_overdue is not None:
            query["include_overdue"] = str(include_overdue).lower()

        response = self._request("GET", "/agenda", query=query)
        entries = response.get("entries")
        if entries is None and isinstance(response.get("days"), dict):
            entries = [
                entry
                for day_entries in response["days"].values()
                if isinstance(day_entries, list)
                for entry in day_entries
            ]
        if not isinstance(entries, list):
            raise OrgAgendaAPIError("org-agenda-api returned no agenda entries")

        response_date = response.get("date") or response.get("startDate") or date
        return {
            "date": response_date,
            "span": response.get("span", span),
            "entries": [self._condense_agenda_entry(entry) for entry in entries],
        }

    def capture(self, arguments: dict[str, Any]) -> dict[str, Any]:
        values: dict[str, Any] = {"Title": arguments["title"]}
        values["todo"] = arguments.get("todo", "TODO")
        for field in ("priority", "tags"):
            if field in arguments:
                values[field] = arguments[field]
        for field in ("scheduled", "deadline"):
            if field in arguments:
                values[field] = self._timestamp(arguments[field])

        response = self._request(
            "POST",
            "/capture",
            body={"template": "capture-g", "values": values},
        )
        return self._pick(response, ("status", "template", "title", "id"))

    def complete(self, arguments: dict[str, Any]) -> dict[str, Any]:
        body = {
            key: arguments[key] for key in ("title", "id", "state") if key in arguments
        }
        response = self._request("POST", "/complete", body=body)
        return self._pick(
            response,
            (
                "status",
                "title",
                "oldState",
                "newState",
                "id",
                "scheduledPreserved",
                "deadlinePreserved",
            ),
        )

    def update(self, arguments: dict[str, Any]) -> dict[str, Any]:
        body = {key: arguments[key] for key in ("title", "id") if key in arguments}
        update_fields = ("scheduled", "deadline", "priority", "tags")
        if not any(field in arguments for field in update_fields):
            raise OrgAgendaAPIError("org_update requires at least one field to update")

        for field in update_fields:
            if field not in arguments:
                continue
            value = arguments[field]
            if field in ("scheduled", "deadline") and value is not None:
                value = self._timestamp(value)
            # The HTTP API uses [] (rather than null) to clear all tags.
            if field == "tags" and value is None:
                value = []
            body[field] = value

        response = self._request("POST", "/update", body=body)
        return self._pick(response, ("status", "title", "id", "updates"))

    def _request(
        self,
        method: str,
        path: str,
        *,
        query: dict[str, str] | None = None,
        body: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        url = f"{self.config.base_url}{path}"
        if query:
            url = f"{url}?{urllib.parse.urlencode(query)}"
        encoded_body = None if body is None else json.dumps(body).encode()
        request = urllib.request.Request(
            url,
            data=encoded_body,
            method=method,
            headers={
                "Accept": "application/json",
                "Authorization": self._authorization,
                **({"Content-Type": "application/json"} if body is not None else {}),
            },
        )

        try:
            with self._opener.open(request, timeout=self.config.timeout) as response:
                raw_body = response.read()
        except urllib.error.HTTPError as error:
            raw_body = error.read()
            message = self._response_message(raw_body) or "request failed"
            raise OrgAgendaAPIError(
                self._redact(f"org-agenda-api HTTP {error.code}: {message}")
            ) from None
        except (TimeoutError, socket.timeout):
            raise OrgAgendaAPIError(
                f"org-agenda-api request timed out after {self.config.timeout:g} seconds"
            ) from None
        except urllib.error.URLError as error:
            reason = self._redact(str(error.reason))
            raise OrgAgendaAPIError(
                f"org-agenda-api request failed: {reason}"
            ) from None

        try:
            decoded = json.loads(raw_body)
        except (UnicodeDecodeError, json.JSONDecodeError):
            raise OrgAgendaAPIError("org-agenda-api returned invalid JSON") from None
        if not isinstance(decoded, dict):
            raise OrgAgendaAPIError("org-agenda-api returned an unexpected JSON value")
        if decoded.get("status") == "error":
            message = decoded.get("message") or "unknown API error"
            raise OrgAgendaAPIError(self._redact(f"org-agenda-api: {message}"))
        return decoded

    def _response_message(self, raw_body: bytes) -> str | None:
        try:
            decoded = json.loads(raw_body)
        except (UnicodeDecodeError, json.JSONDecodeError):
            return None
        if isinstance(decoded, dict) and isinstance(decoded.get("message"), str):
            return decoded["message"]
        return None

    def _redact(self, message: str) -> str:
        return message.replace(self.config.password, "[REDACTED]")

    @staticmethod
    def _timestamp(value: str) -> dict[str, str]:
        match = _TIMESTAMP_RE.fullmatch(value)
        if not match:
            raise OrgAgendaAPIError(
                "timestamps must use YYYY-MM-DD or YYYY-MM-DDTHH:MM"
            )
        date = match.group("date")
        time = match.group("time")
        try:
            datetime.strptime(
                f"{date}{'T' + time if time else ''}",
                "%Y-%m-%dT%H:%M" if time else "%Y-%m-%d",
            )
        except ValueError:
            raise OrgAgendaAPIError(f"invalid calendar timestamp: {value}") from None
        return {"date": date, **({"time": time} if time else {})}

    @staticmethod
    def _condense_agenda_entry(entry: Any) -> dict[str, Any]:
        if not isinstance(entry, dict):
            raise OrgAgendaAPIError("org-agenda-api returned an invalid agenda entry")
        condensed = {field: entry.get(field) for field in _AGENDA_FIELDS}
        condensed["category"] = entry.get("category", entry.get("effectiveCategory"))
        if entry.get("id") is not None:
            condensed["id"] = entry["id"]
        return condensed

    @staticmethod
    def _pick(response: dict[str, Any], fields: tuple[str, ...]) -> dict[str, Any]:
        return {field: response[field] for field in fields if field in response}
