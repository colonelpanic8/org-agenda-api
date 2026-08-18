"""End-to-end MCP stdio verification using the official SDK client."""

from __future__ import annotations

import asyncio
import sys

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


def test_stdio_lists_tools_and_calls_agenda(fake_api) -> None:
    fake_api.enqueue(
        {
            "date": "2026-08-18",
            "span": "day",
            "entries": [{"todo": "TODO", "title": "MCP works", "tags": []}],
        }
    )
    fake_api.enqueue({"status": "error", "message": "Todo not found"})

    async def exercise() -> None:
        parameters = StdioServerParameters(
            command=sys.executable,
            args=["-m", "mcp_server"],
            env={
                "ORG_AGENDA_API_URL": fake_api.url,
                "ORG_AGENDA_API_USER": "stdio-user",
                "ORG_AGENDA_API_PASSWORD": "stdio-secret",
            },
        )
        async with stdio_client(parameters) as (read_stream, write_stream):
            async with ClientSession(read_stream, write_stream) as session:
                await session.initialize()
                listed = await session.list_tools()
                assert [tool.name for tool in listed.tools] == [
                    "org_agenda",
                    "org_capture",
                    "org_complete",
                    "org_update",
                ]
                result = await session.call_tool("org_agenda", {"date": "2026-08-18"})
                assert result.isError is False
                assert result.structuredContent is not None
                assert result.structuredContent["entries"][0]["title"] == "MCP works"
                error_result = await session.call_tool(
                    "org_complete", {"title": "Missing task"}
                )
                assert error_result.isError is True
                assert error_result.structuredContent is None
                assert "Todo not found" in error_result.content[0].text

    asyncio.run(exercise())

    request = fake_api.next_request()
    assert request.path == "/agenda?span=day&date=2026-08-18"
    assert fake_api.next_request().path == "/complete"
