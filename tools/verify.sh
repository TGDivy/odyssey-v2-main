#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export UV_SYSTEM_CERTS="${UV_SYSTEM_CERTS:-true}"
export UV_LINK_MODE="${UV_LINK_MODE:-copy}"

printf '\n[backend] formatting\n'
(
  cd "${repository_root}/backend"
  uv run ruff format --check . ../tools
)

printf '\n[backend] lint and types\n'
(
  cd "${repository_root}/backend"
  uv run ruff check . ../tools
  uv run mypy src ../tools
)

printf '\n[backend] tests and coverage\n'
(
  cd "${repository_root}/backend"
  uv run pytest --cov=odyssey --cov-report=term-missing
)

printf '\n[evaluations] contracts, manifest, and deterministic replays\n'
(
  cd "${repository_root}/backend"
  uv run python ../tools/evals/run.py --check
)

printf '\n[schemas] deterministic generation\n'
(
  cd "${repository_root}/backend"
  uv run python ../tools/codegen/generate.py --check
)

printf '\n[fixtures] deterministic synthetic history\n'
(
  cd "${repository_root}/backend"
  uv run python ../tools/fixtures/generate_synthetic_life.py --check
)

printf '\n[infrastructure] compose contract\n'
docker compose -f "${repository_root}/infra/compose.yaml" config --quiet

printf '\n[infrastructure] GCP deployment contract\n'
python3 "${repository_root}/tools/infra/check_gcp_contract.py"

if command -v tofu >/dev/null 2>&1; then
  printf '\n[infrastructure] OpenTofu formatting, validation, and mocked plans\n'
  tofu -chdir="${repository_root}/infra/gcp" fmt -check -recursive
  tofu -chdir="${repository_root}/infra/gcp" init -backend=false -input=false >/dev/null
  tofu -chdir="${repository_root}/infra/gcp" validate -no-color
  tofu -chdir="${repository_root}/infra/gcp" test -no-color
  tofu -chdir="${repository_root}/infra/gcp/bootstrap" init -backend=false -input=false >/dev/null
  tofu -chdir="${repository_root}/infra/gcp/bootstrap" validate -no-color
else
  printf '\n[infrastructure] skipped: OpenTofu is unavailable; structural contract passed\n'
fi

if command -v swift >/dev/null 2>&1 && [[ -f "${repository_root}/apple/Package.swift" ]]; then
  printf '\n[apple] Swift package tests\n'
  swift test --package-path "${repository_root}/apple"
else
  printf '\n[apple] skipped: Swift/Xcode is unavailable or package scaffold is pending\n'
fi

if command -v xcodegen >/dev/null 2>&1 && command -v xcodebuild >/dev/null 2>&1; then
  printf '\n[apple] Xcode project generation\n'
  bash "${repository_root}/tools/apple/generate-project.sh"
else
  printf '\n[apple] skipped: XcodeGen/Xcode project validation is unavailable\n'
fi

printf '\nOdyssey verification completed successfully.\n'
