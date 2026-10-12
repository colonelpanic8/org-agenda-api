"""MCP tool registration and dispatch."""

from __future__ import annotations

import asyncio
from typing import Any

from mcp import types
from mcp.server import Server

from . import __version__
from .api import OrgAgendaClient

_TIMESTAMP_SCHEMA: dict[str, Any] = {
    "type": "string",
    "pattern": r"^\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2})?$",
    "description": "YYYY-MM-DD or YYYY-MM-DDTHH:MM",
}
_NULLABLE_TIMESTAMP_SCHEMA = {"oneOf": [_TIMESTAMP_SCHEMA, {"type": "null"}]}
_PRIORITY_SCHEMA = {"type": "string", "enum": ["A", "B", "C"]}
_TAGS_SCHEMA = {
    "type": "array",
    "items": {"type": "string", "minLength": 1},
}


def create_server(api: OrgAgendaClient) -> Server:
    server = Server(
        "org-agenda-api",
        version=__version__,
        instructions="Capture and query org-mode tasks through org-agenda-api.",
    )

    @server.list_tools()
    async def list_tools() -> list[types.Tool]:
        return _tools()

    @server.call_tool()
    async def call_tool(name: str, arguments: dict[str, Any]) -> dict[str, Any]:
        if name == "org_agenda":
            return await asyncio.to_thread(
                api.agenda,
                arguments.get("span", "day"),
                arguments.get("date"),
                arguments.get("include_overdue"),
            )
        if name == "org_capture":
            return await asyncio.to_thread(api.capture, arguments)
        if name == "org_complete":
            return await asyncio.to_thread(api.complete, arguments)
        if name == "org_update":
            return await asyncio.to_thread(api.update, arguments)
        raise ValueError(f"unknown tool: {name}")

    return server


def _tools() -> list[types.Tool]:
    return [
        types.Tool(
            name="org_agenda",
            description=(
                "Query day or week agenda items; use span, optional YYYY-MM-DD "
                "date, and include_overdue to control the view."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "span": {
                        "type": "string",
                        "enum": ["day", "week"],
                        "default": "day",
                    },
                    "date": {
                        "type": "string",
                        "format": "date",
                        "pattern": r"^\d{4}-\d{2}-\d{2}$",
                    },
                    "include_overdue": {"type": "boolean"},
                },
                "additionalProperties": False,
            },
        ),
        types.Tool(
            name="org_capture",
            description=(
                "Capture a new GTD task; provide title and optionally todo, "
                "scheduled/deadline ISO timestamps, priority, and tags."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "title": {"type": "string", "minLength": 1},
                    "todo": {
                        "type": "string",
                        "minLength": 1,
                        "default": "TODO",
                    },
                    "scheduled": _TIMESTAMP_SCHEMA,
                    "deadline": _TIMESTAMP_SCHEMA,
                    "priority": _PRIORITY_SCHEMA,
                    "tags": _TAGS_SCHEMA,
                },
                "required": ["title"],
                "additionalProperties": False,
            },
        ),
        types.Tool(
            name="org_complete",
            description=(
                "Complete or transition a task by required title and optional "
                "stable id and target state."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "title": {"type": "string", "minLength": 1},
                    "id": {"type": "string", "minLength": 1},
                    "state": {"type": "string", "minLength": 1},
                },
                "required": ["title"],
                "additionalProperties": False,
            },
        ),
        types.Tool(
            name="org_update",
            description=(
                "Update a task by required title and optional id; set or clear "
                "scheduled, deadline, priority, or tags (null clears)."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "title": {"type": "string", "minLength": 1},
                    "id": {"type": "string", "minLength": 1},
                    "scheduled": _NULLABLE_TIMESTAMP_SCHEMA,
                    "deadline": _NULLABLE_TIMESTAMP_SCHEMA,
                    "priority": {
                        "oneOf": [_PRIORITY_SCHEMA, {"type": "null"}],
                    },
                    "tags": {"oneOf": [_TAGS_SCHEMA, {"type": "null"}]},
                },
                "required": ["title"],
                "anyOf": [
                    {"required": ["scheduled"]},
                    {"required": ["deadline"]},
                    {"required": ["priority"]},
                    {"required": ["tags"]},
                ],
                "additionalProperties": False,
            },
        ),
    ]
