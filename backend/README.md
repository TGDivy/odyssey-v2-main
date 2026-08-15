# Odyssey backend

The backend is a Python modular monolith with separately runnable API and worker
processes. It keeps module ownership explicit while sharing one PostgreSQL
database and deployment artifact.

```bash
uv sync --all-groups
uv run odyssey-api
uv run pytest
```

The default configuration is safe for credential-free local development. Real
authentication, storage, integrations, and model providers must be enabled via
typed environment configuration and the deployment handoff.

