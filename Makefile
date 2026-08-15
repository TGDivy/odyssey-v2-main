SHELL := /usr/bin/env bash

.DEFAULT_GOAL := help

.PHONY: help diagnostics bootstrap dev stop verify format lint test schemas clean

help: ## Show repository commands
	@awk 'BEGIN {FS = ":.*## "; printf "Odyssey commands:\n"} /^[a-zA-Z_-]+:.*## / {printf "  %-14s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

diagnostics: ## Report local tool and platform capabilities
	@bash tools/diagnostics/environment.sh

bootstrap: ## Install local development dependencies
	@if [[ -f backend/pyproject.toml ]]; then cd backend && uv sync --all-groups; else echo "Backend scaffold not added yet."; fi

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

clean: ## Remove local build and test caches
	rm -rf backend/.venv backend/.pytest_cache backend/.mypy_cache backend/.ruff_cache backend/.coverage

