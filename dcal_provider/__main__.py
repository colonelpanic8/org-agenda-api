"""Run the org-agenda-api provider for Dux Calendar (dcal) over stdio.

Connection settings come from the same environment as the MCP sidecar:
ORG_AGENDA_API_URL, ORG_AGENDA_API_USER and ORG_AGENDA_API_PASSWORD or
ORG_AGENDA_API_PASSWORD_COMMAND.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, tzinfo
from typing import Any, TextIO
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from mcp_server.api import OrgAgendaAPIError, OrgAgendaClient
from mcp_server.config import Config, ConfigurationError

from .provider import Options, OrgProvider, ProviderError

ERR_REAUTH = -32001
ERR_PROVIDER = -32000
ERR_METHOD = -32601


def _error_code(error: Exception) -> int:
    if isinstance(error, OrgAgendaAPIError) and "HTTP 401" in str(error):
        return ERR_REAUTH
    return ERR_PROVIDER


def local_timezone() -> tzinfo:
    """The local IANA zone, so DST is right for dates other than today."""
    candidates = [os.environ.get("TZ", "").lstrip(":")]
    target = os.path.realpath("/etc/localtime")
    if "zoneinfo/" in target:
        candidates.append(target.split("zoneinfo/", 1)[1])
    for key in candidates:
        if not key:
            continue
        try:
            return ZoneInfo(key)
        except (ZoneInfoNotFoundError, ValueError):
            continue
    return datetime.now().astimezone().tzinfo


def serve(provider: OrgProvider, stdin: TextIO, stdout: TextIO) -> None:
    handlers = provider.handlers()
    for line in stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except json.JSONDecodeError:
            continue
        request_id = request.get("id")
        if request_id is None:
            continue

        reply: dict[str, Any] = {"jsonrpc": "2.0", "id": request_id}
        handler = handlers.get(request.get("method"))
        if handler is None:
            reply["error"] = {"code": ERR_METHOD, "message": "method not found"}
        else:
            try:
                reply["result"] = handler(request.get("params") or {})
            except (OrgAgendaAPIError, ProviderError, KeyError, ValueError) as error:
                reply["error"] = {"code": _error_code(error), "message": str(error)}
        stdout.write(json.dumps(reply) + "\n")
        stdout.flush()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="org-agenda-dcal", description=__doc__)
    parser.add_argument("--calendar-name", default=Options.calendar_name)
    parser.add_argument("--include-habits", action="store_true")
    parser.add_argument(
        "--done-days",
        type=int,
        default=Options.done_days,
        help="keep tasks completed within this many days visible",
    )
    parser.add_argument(
        "--capture-template",
        default=Options.capture_template,
        help="capture template used for tasks created in the calendar",
    )
    args = parser.parse_args(argv)

    try:
        config = Config.from_env()
    except ConfigurationError as error:
        print(f"org-agenda-dcal: {error}", file=sys.stderr)
        return 2

    provider = OrgProvider(
        OrgAgendaClient(config),
        Options(
            calendar_name=args.calendar_name,
            include_habits=args.include_habits,
            done_days=args.done_days,
            capture_template=args.capture_template,
        ),
        tz=local_timezone(),
    )
    serve(provider, sys.stdin, sys.stdout)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
