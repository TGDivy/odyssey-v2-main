from subprocess import CompletedProcess
from typing import Any

import pytest

from odyssey.jobs import sidecar


class StubResponse:
    status = 200

    def __enter__(self) -> "StubResponse":
        return self

    def __exit__(self, *_arguments: object) -> None:
        return None


def test_bounded_command_preserves_status_and_stops_proxy(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    observed: dict[str, Any] = {}

    def fake_run(command: tuple[str, ...], *, check: bool) -> CompletedProcess[str]:
        observed["command"] = command
        observed["check"] = check
        return CompletedProcess(command, 9)

    def fake_urlopen(request: Any, *, timeout: int) -> StubResponse:
        observed["shutdown_url"] = request.full_url
        observed["shutdown_method"] = request.method
        observed["timeout"] = timeout
        return StubResponse()

    monkeypatch.setattr(sidecar, "run_process", fake_run)
    monkeypatch.setattr(sidecar, "urlopen", fake_urlopen)

    assert sidecar.run_bounded_command(("synthetic-command", "argument")) == 9
    assert observed == {
        "command": ("synthetic-command", "argument"),
        "check": False,
        "shutdown_url": sidecar.PROXY_SHUTDOWN_URL,
        "shutdown_method": "POST",
        "timeout": 5,
    }


def test_bounded_command_stops_proxy_after_command_error(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    stopped = False

    def failed_run(*_arguments: object, **_keywords: object) -> CompletedProcess[str]:
        raise OSError("synthetic execution failure")

    def fake_stop_proxy() -> None:
        nonlocal stopped
        stopped = True

    monkeypatch.setattr(sidecar, "run_process", failed_run)
    monkeypatch.setattr(sidecar, "stop_proxy", fake_stop_proxy)

    with pytest.raises(OSError, match="synthetic execution failure"):
        sidecar.run_bounded_command(("synthetic-command",))
    assert stopped is True


def test_bounded_command_requires_a_command() -> None:
    with pytest.raises(ValueError, match="command is required"):
        sidecar.run_bounded_command(())
