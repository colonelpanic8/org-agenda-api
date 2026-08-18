"""Environment configuration for the MCP sidecar."""

from __future__ import annotations

import os
import subprocess
from collections.abc import Mapping
from dataclasses import dataclass

DEFAULT_API_URL = "https://org-agenda-api.rocket-sense.duckdns.org"
PASSWORD_COMMAND_TIMEOUT_SECONDS = 10


class ConfigurationError(ValueError):
    """Raised when required sidecar configuration is unavailable."""


@dataclass(frozen=True)
class Config:
    """Connection settings for org-agenda-api."""

    base_url: str
    username: str
    password: str
    timeout: float = 10.0

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None) -> Config:
        values = os.environ if env is None else env
        base_url = values.get("ORG_AGENDA_API_URL", DEFAULT_API_URL).rstrip("/")
        username = values.get("ORG_AGENDA_API_USER", "")
        password = values.get("ORG_AGENDA_API_PASSWORD")

        if not base_url.startswith(("http://", "https://")):
            raise ConfigurationError("ORG_AGENDA_API_URL must use http or https")
        if not username:
            raise ConfigurationError("ORG_AGENDA_API_USER is required")

        if password is None:
            command = values.get("ORG_AGENDA_API_PASSWORD_COMMAND")
            if not command:
                raise ConfigurationError(
                    "set ORG_AGENDA_API_PASSWORD or ORG_AGENDA_API_PASSWORD_COMMAND"
                )
            password = _read_password_command(command)

        if not password:
            raise ConfigurationError("the configured org-agenda-api password is empty")

        return cls(base_url=base_url, username=username, password=password)


def _read_password_command(command: str) -> str:
    try:
        completed = subprocess.run(
            command,
            shell=True,
            check=False,
            capture_output=True,
            text=True,
            timeout=PASSWORD_COMMAND_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired as error:
        raise ConfigurationError("password command timed out") from error
    except OSError as error:
        raise ConfigurationError("password command could not be started") from error

    if completed.returncode != 0:
        raise ConfigurationError(
            f"password command failed with exit code {completed.returncode}"
        )

    lines = completed.stdout.splitlines()
    if not lines or not lines[0]:
        raise ConfigurationError("password command returned no password")
    return lines[0]
