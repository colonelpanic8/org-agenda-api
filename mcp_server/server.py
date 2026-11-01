"""MCP tool registration and dispatch."""

from __future__ import annotations

import asyncio
import json
from typing import Any

import jsonschema
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

    options: dict[str, Any] = {
        "version": __version__,
        "instructions": "Capture and query org-mode tasks through org-agenda-api.",
    }

    # mcp 1.x registers handlers with decorators, which also validate input and
    # wrap results; mcp 2.x takes raw handlers in the constructor.
    if hasattr(Server, "list_tools"):
        server = Server("org-agenda-api", **options)

        @server.list_tools()
        async def list_tools() -> list[types.Tool]:
            return _tools()

        server.call_tool()(call_tool)
        return server

    tools = {tool.name: tool for tool in _tools()}

    async def on_list_tools(_ctx: Any, _params: Any) -> types.ListToolsResult:
        return types.ListToolsResult(tools=list(tools.values()))

    async def on_call_tool(_ctx: Any, params: Any) -> types.CallToolResult:
        arguments = params.arguments or {}
        try:
            if tool := tools.get(params.name):
                try:
                    jsonschema.validate(arguments, tool.input_schema)
                except jsonschema.ValidationError as error:
                    raise ValueError(f"Input validation error: {error.message}")
            result = await call_tool(params.name, arguments)
        except Exception as error:  # noqa: BLE001 - report as a tool error, as 1.x does
            return types.CallToolResult(
                content=[types.TextContent(type="text", text=str(error))],
                isError=True,
            )
        return types.CallToolResult(
            content=[types.TextContent(type="text", text=json.dumps(result, indent=2))],
            structuredContent=result,
        )

    return Server(
        "org-agenda-api",
        **options,
        on_list_tools=on_list_tools,
        on_call_tool=on_call_tool,
    )


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
