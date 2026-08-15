FROM python:3.13.7-slim AS application

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy

WORKDIR /app

COPY --from=ghcr.io/astral-sh/uv:0.12.0 /uv /uvx /bin/
COPY pyproject.toml uv.lock README.md ./
RUN uv sync --frozen --no-dev --no-install-project

COPY alembic.ini ./
COPY migrations ./migrations
COPY src ./src
RUN uv sync --frozen --no-dev

USER 65532:65532
EXPOSE 8080

FROM application AS backup

USER root
RUN apt-get update \
    && apt-get install --yes --no-install-recommends postgresql-client \
    && rm -rf /var/lib/apt/lists/*
USER 65532:65532

CMD ["uv", "run", "--no-sync", "odyssey-cloud-backup"]

FROM application AS runtime

CMD ["uv", "run", "--no-sync", "uvicorn", "odyssey.main:app", "--host", "0.0.0.0", "--port", "8080", "--no-access-log"]
