"""Run the org-agenda-api MCP server over stdio or Streamable HTTP."""

from __future__ import annotations

import argparse
import asyncio
import os
import sys

from mcp.server.stdio import stdio_server

from .api import OrgAgendaClient
from .config import Config, ConfigurationError
from .http import run_http
from .server import create_server


async def _run_stdio(api: OrgAgendaClient) -> None:
    server = create_server(api)
    async with stdio_server() as (read_stream, write_stream):
        await server.run(
            read_stream,
            write_stream,
            server.create_initialization_options(),
        )


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--transport",
        choices=("stdio", "streamable-http"),
        default="stdio",
    )
    parser.add_argument(
        "--host",
        default=os.environ.get("ORG_AGENDA_MCP_HOST", "127.0.0.1"),
    )
    parser.add_argument(
        "--port",
        type=int,
        default=int(os.environ.get("ORG_AGENDA_MCP_PORT", "2026")),
    )
    return parser.parse_args()


def main() -> None:
    try:
        arguments = _parse_args()
        api = OrgAgendaClient(Config.from_env())
        if arguments.transport == "streamable-http":
            asyncio.run(run_http(api, arguments.host, arguments.port))
        else:
            asyncio.run(_run_stdio(api))
    except ConfigurationError as error:
        print(f"org-agenda-mcp: {error}", file=sys.stderr)
        raise SystemExit(2) from None


if __name__ == "__main__":
    main()
