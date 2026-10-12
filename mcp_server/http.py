"""Streamable HTTP transport for the MCP adapter."""

from __future__ import annotations

from contextlib import asynccontextmanager
from typing import Any

import uvicorn
from mcp.server.streamable_http_manager import StreamableHTTPSessionManager
from mcp.server.transport_security import TransportSecuritySettings
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.routing import Route

from .api import OrgAgendaClient
from .server import create_server


class _StreamableHTTPApp:
    def __init__(self, manager: StreamableHTTPSessionManager):
        self.manager = manager

    async def __call__(self, scope: Any, receive: Any, send: Any) -> None:
        await self.manager.handle_request(scope, receive, send)


def create_http_app(api: OrgAgendaClient, port: int) -> Starlette:
    """Create the loopback-only ASGI application served behind nginx."""
    server = create_server(api)
    security = TransportSecuritySettings(
        enable_dns_rebinding_protection=True,
        allowed_hosts=[f"127.0.0.1:{port}", f"localhost:{port}"],
        allowed_origins=[],
    )
    manager = StreamableHTTPSessionManager(
        app=server,
        json_response=True,
        stateless=True,
        security_settings=security,
    )
    mcp_app = _StreamableHTTPApp(manager)

    @asynccontextmanager
    async def lifespan(_app: Starlette):
        async with manager.run():
            yield

    async def health(_request: Request) -> JSONResponse:
        return JSONResponse({"status": "ok"})

    return Starlette(
        routes=[
            Route("/mcp", endpoint=mcp_app),
            Route("/health", endpoint=health, methods=["GET"]),
        ],
        lifespan=lifespan,
    )


async def run_http(api: OrgAgendaClient, host: str, port: int) -> None:
    """Serve Streamable HTTP until terminated."""
    app = create_http_app(api, port)
    config = uvicorn.Config(
        app,
        host=host,
        port=port,
        access_log=False,
        log_level="info",
        proxy_headers=False,
    )
    await uvicorn.Server(config).serve()
