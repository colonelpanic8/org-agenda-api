# MCP Server Design

## Decision

Add a thin Python sidecar that uses the official `mcp` Python SDK and the
repository's existing HTTP API. The server exposes stdio only: an MCP host
starts one process, and each tool call becomes one authenticated HTTP request.

Python fits the repository better than a TypeScript sidecar because pytest is
already the integration-test harness and Python is already present in the Nix
development and container environments. Keeping the adapter outside Emacs also
preserves the HTTP API as the only implementation of org-mode behavior.

The SDK's low-level server API will define the four schemas explicitly. This is
slightly more verbose than decorator-based registration, but it preserves the
important difference between an omitted `org_update` field and an explicit JSON
`null` that clears it.

## Shape

- `mcp_server/config.py`: read the base URL and Basic Auth settings. A password
  command is executed once at startup and only its first stdout line is used.
- `mcp_server/api.py`: a 10-second JSON HTTP client, error normalization, agenda
  condensation, and request-shape translation.
- `mcp_server/server.py`: MCP tool schemas/descriptions and dispatch only.
- `mcp_server/__main__.py`: stdio entry point.

Agenda responses are reduced to the documented fields. The HTTP API returns a
flat `entries` array for a day and a date-keyed `days` object for a week; the
adapter flattens the latter to the MCP tool's single `entries` array. Scheduled
and deadline arguments use compact ISO strings (`YYYY-MM-DD` or
`YYYY-MM-DDTHH:MM`) and are translated to the HTTP API's timestamp objects.

All upstream non-2xx responses, invalid JSON, timeouts, transport failures, and
JSON bodies with `status: "error"` become MCP tool errors. Error text includes
the API's message when available but never the Authorization header, password,
or password command output.

## Packaging and deployment

The project will expose a Nix package/app for the sidecar and include its
executable in the existing container image. The container uses supervisord for
long-running services, but a stdio MCP process must be started by its host and
must not be supervised as a daemon. A future Streamable HTTP transport could be
added as another supervisord program behind nginx; it is intentionally outside
v1 because it would add an authenticated network service rather than being
nearly free.

## Verification

Pytest tests will use an in-process fake HTTP server to cover query and mutation
shapes, Basic Auth, response condensation, API/HTTP failures, timeouts where
practical, and password-command sourcing. An SDK client will also launch the
stdio executable and exercise tool listing and a read-only call end to end.
Production verification is limited to authenticated `GET /agenda` and
`GET /metadata`; no production mutation endpoint will be called.
