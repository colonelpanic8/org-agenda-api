"""Fake HTTP server fixture for MCP adapter tests."""

from __future__ import annotations

import json
import queue
import threading
import time
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

import pytest


@dataclass
class RecordedRequest:
    method: str
    path: str
    headers: dict[str, str]
    body: Any


@dataclass
class QueuedResponse:
    status: int
    body: bytes
    content_type: str = "application/json"
    delay: float = 0


class FakeAPI:
    def __init__(self) -> None:
        self.requests: queue.Queue[RecordedRequest] = queue.Queue()
        self.responses: queue.Queue[QueuedResponse] = queue.Queue()
        self._server = ThreadingHTTPServer(("127.0.0.1", 0), self._handler())
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)
        self._thread.start()

    @property
    def url(self) -> str:
        host, port = self._server.server_address
        return f"http://{host}:{port}"

    def enqueue(self, payload: Any, status: int = 200, delay: float = 0) -> None:
        self.responses.put(
            QueuedResponse(status, json.dumps(payload).encode(), delay=delay)
        )

    def enqueue_raw(
        self, body: bytes, status: int = 200, content_type: str = "text/plain"
    ) -> None:
        self.responses.put(QueuedResponse(status, body, content_type))

    def next_request(self) -> RecordedRequest:
        return self.requests.get(timeout=2)

    def close(self) -> None:
        self._server.shutdown()
        self._server.server_close()
        self._thread.join(timeout=2)

    def _handler(self) -> type[BaseHTTPRequestHandler]:
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self) -> None:  # noqa: N802
                self._handle()

            def do_POST(self) -> None:  # noqa: N802
                self._handle()

            def _handle(self) -> None:
                length = int(self.headers.get("Content-Length", "0"))
                raw_body = self.rfile.read(length) if length else b""
                body = json.loads(raw_body) if raw_body else None
                owner.requests.put(
                    RecordedRequest(
                        method=self.command,
                        path=self.path,
                        headers=dict(self.headers),
                        body=body,
                    )
                )
                response = owner.responses.get(timeout=2)
                if response.delay:
                    time.sleep(response.delay)
                self.send_response(response.status)
                self.send_header("Content-Type", response.content_type)
                self.send_header("Content-Length", str(len(response.body)))
                self.end_headers()
                try:
                    self.wfile.write(response.body)
                except BrokenPipeError:
                    pass

            def log_message(self, _format: str, *_args: object) -> None:
                return

        return Handler


@pytest.fixture
def fake_api() -> FakeAPI:
    server = FakeAPI()
    try:
        yield server
    finally:
        server.close()
