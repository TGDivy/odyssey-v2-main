#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [[ "$(uname -s)" != "Darwin" ]]; then
  printf 'Xcode project generation requires macOS.\n' >&2
  exit 1
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  printf 'Install XcodeGen 2.44.1 with `brew install xcodegen`.\n' >&2
  exit 1
fi

actual_version="$(xcodegen version | awk '{print $2}')"
if [[ "${actual_version}" != "2.44.1" ]]; then
  printf 'Expected XcodeGen 2.44.1, found %s.\n' "${actual_version}" >&2
  exit 1
fi

(
  cd "${repository_root}/apple"
  xcodegen generate --spec project.yml
  xcodebuild -workspace Odyssey.xcworkspace -list
)

