from fastapi.testclient import TestClient

from odyssey.api.errors import OdysseyError
from odyssey.config import Environment, Settings
from odyssey.main import create_app
from odyssey.worker import main as run_worker


def test_live_health_check() -> None:
    with TestClient(create_app(Settings(env=Environment.TEST))) as client:
        response = client.get("/health/live", headers={"X-Correlation-ID": "test-trace"})

    assert response.status_code == 200
    assert response.json() == {"status": "ok"}
    assert response.headers["X-Correlation-ID"] == "test-trace"


def test_readiness_check_has_timestamp() -> None:
    with TestClient(create_app(Settings(env=Environment.TEST))) as client:
        response = client.get("/health/ready")

    assert response.status_code == 200
    assert response.json()["status"] == "ready"
    assert response.json()["checked_at"].endswith("Z")


def test_diagnostics_excludes_secret_configuration() -> None:
    settings = Settings(
        env=Environment.TEST,
        database_url="postgresql://user:secret@private.example/odyssey",
        storage_secret_key="must-not-leak",
    )
    with TestClient(create_app(settings)) as client:
        response = client.get("/v1/admin/diagnostics")

    body = response.text
    assert response.status_code == 200
    assert "must-not-leak" not in body
    assert "private.example" not in body
    assert response.json()["configuration"]["environment"] == "test"


def test_not_found_uses_stable_error_envelope() -> None:
    with TestClient(create_app(Settings(env=Environment.TEST))) as client:
        response = client.get("/does-not-exist")

    assert response.status_code == 404
    assert response.json()["error"]["code"] == "HTTP_404"
    assert response.json()["error"]["correlation_id"] == response.headers["X-Correlation-ID"]
    assert response.json()["error"]["retryable"] is False


def test_domain_error_uses_stable_error_envelope() -> None:
    app = create_app(Settings(env=Environment.TEST))

    @app.get("/test/domain-error")
    async def domain_error() -> None:
        raise OdysseyError(
            code="TEST_CONFLICT",
            message="Synthetic conflict.",
            status_code=409,
            details={"conflict_id": "synthetic"},
        )

    with TestClient(app) as client:
        response = client.get("/test/domain-error")

    assert response.status_code == 409
    assert response.json()["error"]["code"] == "TEST_CONFLICT"
    assert response.json()["error"]["details"] == {"conflict_id": "synthetic"}


def test_validation_error_does_not_echo_payload() -> None:
    app = create_app(Settings(env=Environment.TEST))

    @app.get("/test/validated")
    async def validated(count: int) -> dict[str, int]:
        return {"count": count}

    with TestClient(app) as client:
        response = client.get("/test/validated", params={"count": "private-invalid-value"})

    assert response.status_code == 422
    assert response.json()["error"]["code"] == "REQUEST_VALIDATION_FAILED"
    assert "private-invalid-value" not in response.text
    assert response.json()["error"]["details"]["fields"] == ["query.count"]


def test_unhandled_error_is_redacted() -> None:
    app = create_app(Settings(env=Environment.TEST))

    @app.get("/test/unhandled")
    async def unhandled() -> None:
        raise RuntimeError("private provider payload")

    with TestClient(app, raise_server_exceptions=False) as client:
        response = client.get("/test/unhandled")

    assert response.status_code == 500
    assert response.json()["error"]["code"] == "INTERNAL_ERROR"
    assert "private provider payload" not in response.text


def test_worker_starts_without_credentials() -> None:
    run_worker()
