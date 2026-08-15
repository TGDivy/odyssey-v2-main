#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export UV_SYSTEM_CERTS="${UV_SYSTEM_CERTS:-true}"
export UV_LINK_MODE="${UV_LINK_MODE:-copy}"

printf '\n[backend] formatting\n'
(
  cd "${repository_root}/backend"
  uv run ruff format --check . ../tools/codegen/generate.py
)

printf '\n[backend] lint and types\n'
(
  cd "${repository_root}/backend"
  uv run ruff check . ../tools/codegen/generate.py
  uv run mypy src ../tools/codegen/generate.py
)

printf '\n[backend] tests and coverage\n'
(
  cd "${repository_root}/backend"
  uv run pytest --cov=odyssey --cov-report=term-missing
)

printf '\n[schemas] deterministic generation\n'
(
  cd "${repository_root}/backend"
  uv run python ../tools/codegen/generate.py --check
)

printf '\n[infrastructure] compose contract\n'
docker compose -f "${repository_root}/infra/compose.yaml" config --quiet

if command -v swift >/dev/null 2>&1 && [[ -f "${repository_root}/apple/Package.swift" ]]; then
  printf '\n[apple] Swift package tests\n'
  swift test --package-path "${repository_root}/apple"
else
  printf '\n[apple] skipped: Swift/Xcode is unavailable or package scaffold is pending\n'
fi

printf '\nOdyssey verification completed successfully.\n'

