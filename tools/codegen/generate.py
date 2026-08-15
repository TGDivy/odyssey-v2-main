#!/usr/bin/env python3
"""Generate deterministic JSON Schema and OpenAPI artifacts."""

import argparse
import json
import sys
from hashlib import sha256
from pathlib import Path
from typing import Any

from odyssey.config import Environment, Settings
from odyssey.domain.schema_registry import SCHEMA_MODELS
from odyssey.main import create_app

REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
JSON_SCHEMA_ROOT = REPOSITORY_ROOT / "schemas" / "jsonschema" / "v1"
OPENAPI_PATH = REPOSITORY_ROOT / "schemas" / "openapi" / "odyssey-v1.openapi.json"
MANIFEST_PATH = REPOSITORY_ROOT / "schemas" / "generated" / "schema-manifest.json"


def serialize(document: dict[str, Any]) -> bytes:
    return (json.dumps(document, indent=2, sort_keys=True) + "\n").encode()


def generated_artifacts() -> dict[Path, bytes]:
    artifacts: dict[Path, bytes] = {}
    for name, model in sorted(SCHEMA_MODELS.items()):
        schema = model.model_json_schema(mode="validation")
        schema["$schema"] = "https://json-schema.org/draft/2020-12/schema"
        schema["$id"] = f"https://schemas.odyssey.local/v1/{name}.schema.json"
        artifacts[JSON_SCHEMA_ROOT / f"{name}.schema.json"] = serialize(schema)

    app = create_app(
        Settings(
            env=Environment.TEST,
            api_docs_enabled=False,
            model_provider="deterministic",
            proactive_enabled=False,
        )
    )
    artifacts[OPENAPI_PATH] = serialize(app.openapi())

    manifest_entries = []
    for path, content in sorted(artifacts.items(), key=lambda item: str(item[0])):
        manifest_entries.append(
            {
                "path": str(path.relative_to(REPOSITORY_ROOT)),
                "sha256": sha256(content).hexdigest(),
            }
        )
    manifest = {"schema_version": 1, "artifacts": manifest_entries}
    artifacts[MANIFEST_PATH] = serialize(manifest)
    return artifacts


def write_artifacts(artifacts: dict[Path, bytes]) -> None:
    for path, content in artifacts.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)


def check_artifacts(artifacts: dict[Path, bytes]) -> int:
    stale: list[str] = []
    for path, expected in artifacts.items():
        if not path.exists() or path.read_bytes() != expected:
            stale.append(str(path.relative_to(REPOSITORY_ROOT)))
    if stale:
        print("Generated schema artifacts are stale:", file=sys.stderr)
        for stale_path in stale:
            print(f"  {stale_path}", file=sys.stderr)
        print("Run `make schemas` and commit the result.", file=sys.stderr)
        return 1
    print(f"Verified {len(artifacts)} generated schema artifacts.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    arguments = parser.parse_args()
    artifacts = generated_artifacts()
    if arguments.check:
        return check_artifacts(artifacts)
    write_artifacts(artifacts)
    print(f"Generated {len(artifacts)} schema artifacts.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
