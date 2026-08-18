"""Run the org-agenda-api MCP server over stdio."""

from __future__ import annotations

import asyncio
import sys

from mcp.server.stdio import stdio_server

from .api import OrgAgendaClient
from .config import Config, ConfigurationError
from .server import create_server


async def _run() -> None:
    api = OrgAgendaClient(Config.from_env())
    server = create_server(api)
    async with stdio_server() as (read_stream, write_stream):
        await server.run(
            read_stream,
            write_stream,
            server.create_initialization_options(),
        )


def main() -> None:
    try:
        asyncio.run(_run())
    except ConfigurationError as error:
        print(f"org-agenda-mcp: {error}", file=sys.stderr)
        raise SystemExit(2) from None


if __name__ == "__main__":
    main()
