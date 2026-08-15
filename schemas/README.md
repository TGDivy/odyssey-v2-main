# Odyssey schemas

These artifacts are generated from the immutable Python contract models and are
the cross-environment boundary for backend, Apple clients, fixtures, and tools.

- `jsonschema/v1/` contains JSON Schema 2020-12 contracts.
- `openapi/` contains the OpenAPI 3.1 service contract.
- `events/` contains immutable event payload schemas.
- `generated/schema-manifest.json` pins artifact hashes.

Regenerate after an intentional contract change:

```bash
make schemas
```

CI runs the generator in check mode. Released schema meaning is never changed
in place; add a new schema or event version instead.

