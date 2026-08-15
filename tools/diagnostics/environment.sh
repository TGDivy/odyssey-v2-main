#!/usr/bin/env bash
set -euo pipefail

status=0

check_tool() {
  local command_name="$1"
  local required="$2"
  if command -v "${command_name}" >/dev/null 2>&1; then
    printf 'available  %-12s %s\n' "${command_name}" "$(command -v "${command_name}")"
  elif [[ "${required}" == "required" ]]; then
    printf 'missing    %-12s required\n' "${command_name}"
    status=1
  else
    printf 'skipped    %-12s not available on this machine\n' "${command_name}"
  fi
}

printf 'Odyssey environment diagnostics\n'
printf 'platform   %-12s %s\n' 'os' "$(uname -s) $(uname -m)"
check_tool git required
check_tool make required
check_tool python3 required
check_tool uv required
check_tool docker required
check_tool swift optional
check_tool xcodebuild optional
check_tool tofu optional
check_tool terraform optional

if command -v docker >/dev/null 2>&1; then
  if docker compose version >/dev/null 2>&1; then
    printf 'available  %-12s %s\n' 'compose' "$(docker compose version --short)"
  else
    printf 'missing    %-12s Docker Compose v2 is required\n' 'compose'
    status=1
  fi
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  printf 'note       Apple builds and device capability checks require macOS/Xcode.\n'
fi

exit "${status}"
