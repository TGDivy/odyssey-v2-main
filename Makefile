SHELL := /usr/bin/env bash
UV_SYSTEM_CERTS ?= true
UV_LINK_MODE ?= copy

export UV_SYSTEM_CERTS
export UV_LINK_MODE

.DEFAULT_GOAL := help

.PHONY: help diagnostics bootstrap dev stop verify format lint test schemas fixtures apple-project clean

help: ## Show repository commands
	@awk 'BEGIN {FS = ":.*## "; printf "Odyssey commands:\n"} /^[a-zA-Z_-]+:.*## / {printf "  %-14s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

diagnostics: ## Report local tool and platform capabilities
	@bash tools/diagnostics/environment.sh

bootstrap: ## Install local development dependencies
	@if [[ -f backend/pyproject.toml ]]; then cd backend && uv sync --frozen --all-groups; else echo "Backend scaffold not added yet."; fi

dev: ## Start local dependencies and backend
	@if [[ -f infra/compose.yaml ]]; then docker compose -f infra/compose.yaml up --build; else echo "Local stack scaffold not added yet."; fi

stop: ## Stop the local stack
	@if [[ -f infra/compose.yaml ]]; then docker compose -f infra/compose.yaml down; else echo "Local stack is not configured yet."; fi

verify: diagnostics ## Run all environment-available verification
	@if [[ -f tools/verify.sh ]]; then bash tools/verify.sh; else echo "Verification harness not added yet."; fi

format: ## Format source files
	@if [[ -f backend/pyproject.toml ]]; then cd backend && uv run ruff format .; fi

lint: ## Run linters and static analysis
	@if [[ -f backend/pyproject.toml ]]; then cd backend && uv run ruff check . && uv run mypy src; fi

test: ## Run automated tests
	@if [[ -f backend/pyproject.toml ]]; then cd backend && uv run pytest; fi

schemas: ## Regenerate schema artifacts
	@if [[ -f tools/codegen/generate.py ]]; then cd backend && uv run python ../tools/codegen/generate.py; else echo "Schema generator not added yet."; fi

fixtures: ## Regenerate deterministic synthetic-life fixtures
	@cd backend && uv run python ../tools/fixtures/generate_synthetic_life.py

apple-project: ## Generate the Xcode project on macOS
	@bash tools/apple/generate-project.sh

clean: ## Remove local build and test caches
	rm -rf backend/.venv backend/.pytest_cache backend/.mypy_cache backend/.ruff_cache backend/.coverage
