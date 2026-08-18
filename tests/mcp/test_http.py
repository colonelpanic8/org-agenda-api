"""End-to-end Streamable HTTP verification using the official SDK client."""

from __future__ import annotations

import asyncio
import os
import socket
import subprocess
import sys
import time

import requests
from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client


def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def _wait_until_ready(url: str, process: subprocess.Popen[str]) -> None:
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if process.poll() is not None:
            stderr = process.stderr.read() if process.stderr else ""
            raise AssertionError(f"MCP HTTP server exited early: {stderr}")
        try:
            if requests.get(url, timeout=0.2).status_code == 200:
                return
        except requests.RequestException:
            pass
        time.sleep(0.05)
    raise AssertionError("MCP HTTP server did not become ready")


def test_streamable_http_lists_tools_and_calls_agenda(fake_api) -> None:
    fake_api.enqueue(
        {
            "date": "2026-08-18",
            "span": "day",
            "entries": [{"todo": "TODO", "title": "HTTP MCP works", "tags": []}],
        }
    )
    port = _free_port()
    env = {
        **os.environ,
        "ORG_AGENDA_API_URL": fake_api.url,
        "ORG_AGENDA_API_USER": "http-user",
        "ORG_AGENDA_API_PASSWORD": "http-secret",
    }
    process = subprocess.Popen(
        [
            sys.executable,
            "-m",
            "mcp_server",
            "--transport",
            "streamable-http",
            "--port",
            str(port),
        ],
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        _wait_until_ready(f"http://127.0.0.1:{port}/health", process)

        async def exercise() -> None:
            async with streamable_http_client(f"http://127.0.0.1:{port}/mcp") as (
                read_stream,
                write_stream,
                _get_session_id,
            ):
                async with ClientSession(read_stream, write_stream) as session:
                    await session.initialize()
                    listed = await session.list_tools()
                    assert [tool.name for tool in listed.tools] == [
                        "org_agenda",
                        "org_capture",
                        "org_complete",
                        "org_update",
                    ]
                    result = await session.call_tool(
                        "org_agenda", {"date": "2026-08-18"}
                    )
                    assert result.isError is False
                    assert result.structuredContent is not None
                    assert result.structuredContent["entries"][0]["title"] == (
                        "HTTP MCP works"
                    )

        asyncio.run(exercise())
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)

    assert fake_api.next_request().path == "/agenda?span=day&date=2026-08-18"
