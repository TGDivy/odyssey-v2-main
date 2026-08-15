"""Run a bounded job command and terminate its local Cloud SQL proxy."""

import sys
from collections.abc import Sequence
from subprocess import run as run_process
from urllib.request import Request, urlopen

PROXY_SHUTDOWN_URL = "http://127.0.0.1:9091/quitquitquit"


def stop_proxy() -> None:
    request = Request(PROXY_SHUTDOWN_URL, method="POST")
    with urlopen(request, timeout=5) as response:
        if response.status >= 300:
            raise RuntimeError("Cloud SQL proxy rejected its shutdown request")


def run_bounded_command(command: Sequence[str]) -> int:
    if not command:
        raise ValueError("a bounded job command is required")
    try:
        return run_process(tuple(command), check=False).returncode
    finally:
        stop_proxy()


def main() -> None:
    try:
        return_code = run_bounded_command(sys.argv[1:])
    except Exception:
        print("bounded_job_wrapper_failed", file=sys.stderr)
        raise SystemExit(70) from None
    raise SystemExit(return_code)


if __name__ == "__main__":
    main()
