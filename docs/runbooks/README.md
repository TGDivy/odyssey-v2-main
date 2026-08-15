# Odyssey operator runbooks

These runbooks are the executable safety procedures for the single-owner
deployment. They apply to development, staging, and production unless a step is
explicitly marked local-only.

- [`incident-response.md`](incident-response.md) — contain, preserve, diagnose,
  recover, and close an integrity or availability incident.
- [`schema-migration.md`](schema-migration.md) — expand/migrate/contract releases
  with a pre-migration checkpoint and no destructive reset.
- [`clean-room-recovery.md`](clean-room-recovery.md) — restore an isolated target,
  validate it, enroll a fresh client, and reconcile surviving operations.
- [`record-trace.md`](record-trace.md) — trace a synthetic record through source,
  provenance, ledger, outbox, and projection state.

## Non-negotiable rules

1. Never delete a database, Compose volume, Cloud SQL instance, or local app
   container to resolve a migration failure.
2. Never run destructive repair without an explicit backup checkpoint and
   owner authorization.
3. Never copy real owner data into source control, CI, tickets, chat, or an
   unmanaged development machine.
4. Never declare a backup valid from a hash check alone; it must restore and
   pass integrity checks.
5. Never auto-disable a safety kill switch after a green check. Record the
   owner/operator decision and reason.
6. Preserve correlation IDs, schema revisions, report hashes, and command
   outputs; do not preserve unrestricted sensitive payloads in incident notes.

The production account names, identities, secrets, alert channels, and exact
Google Cloud/Apple setup are maintained in `docs/deployment/OWNER_HANDOFF.md`.
