"""Configuration tests for the MCP adapter."""

from __future__ import annotations

import pytest

from mcp_server.config import Config, ConfigurationError, DEFAULT_API_URL


def test_password_command_uses_first_stdout_line() -> None:
    config = Config.from_env(
        {
            "ORG_AGENDA_API_USER": "ivan",
            "ORG_AGENDA_API_PASSWORD_COMMAND": "printf 'first-secret\\nignored\\n'",
        }
    )

    assert config.base_url == DEFAULT_API_URL
    assert config.password == "first-secret"


def test_direct_password_takes_precedence_over_command() -> None:
    config = Config.from_env(
        {
            "ORG_AGENDA_API_USER": "ivan",
            "ORG_AGENDA_API_PASSWORD": "direct-secret",
            "ORG_AGENDA_API_PASSWORD_COMMAND": "exit 99",
        }
    )

    assert config.password == "direct-secret"


@pytest.mark.parametrize(
    ("env", "message"),
    [
        ({"ORG_AGENDA_API_PASSWORD": "secret"}, "ORG_AGENDA_API_USER"),
        ({"ORG_AGENDA_API_USER": "ivan"}, "ORG_AGENDA_API_PASSWORD"),
        (
            {
                "ORG_AGENDA_API_USER": "ivan",
                "ORG_AGENDA_API_PASSWORD_COMMAND": "exit 7",
            },
            "exit code 7",
        ),
    ],
)
def test_invalid_configuration_is_actionable(env: dict[str, str], message: str) -> None:
    with pytest.raises(ConfigurationError, match=message):
        Config.from_env(env)
