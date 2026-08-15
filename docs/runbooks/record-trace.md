# Durable record trace

Use this procedure only for a synthetic record or a record the owner explicitly
approved for investigation. The executable report contains identifiers, hashes,
timestamps, states, and trace metadata; it structurally omits record payloads,
projection documents, provenance details, and raw actor identifiers.

## Prerequisites

Record the environment, schema revision, release SHA, and incident or drill ID.
Rebuild projections if the investigation expects the latest ledger state:

```bash
make rebuild-projections
```

Choose exactly one selector: source-record ID, event ID, aggregate ID,
correlation UUID, or ledger sequence.

## Generate the report

Run from `backend/`. The optional HTTP trace value is a comma-separated
`PHASE,CORRELATION_ID,TRACE_ID,SPAN_ID` tuple copied from the response headers.
Repeat `--http-trace` for capture, sync, or other phases.

```bash
uv run python ../tools/diagnostics/trace_record.py \
  --source-record-id 0198... \
  --http-trace 'capture_commit,record-trace-drill,4bf92f3577b34da6a3ce929d0e0e4736,00f067aa0ba902b7' \
  --http-trace 'sync_push,record-trace-sync,4bf92f3577b34da6a3ce929d0e0e4737,00f067aa0ba902b8' \
  --report ../local-data/record-traces/trace-0198.json
```

Use `--database-url` only when the configured `ODYSSEY_DATABASE_URL` is not the
target. Report files are mode `0600`, and the command refuses to overwrite an
existing report.

Exit codes:

- `0`: every required source-to-sync link is present and content hashes match;
- `2`: the selected record exists, but one or more links are missing;
- `3`: the selected durable record does not exist.

## Interpret the links

The report verifies and names each hop:

1. source record to immutable provenance, including source content-hash check;
2. provenance to ledger event and ledger correlation ID;
3. ledger event to transactional outbox record;
4. ledger aggregate to projection and projection checkpoint;
5. aggregate to immutable device sync operation;
6. accepted sync operation to global server change and sync outbox record;
7. latest server change to canonical entity, including canonical hash check;
8. ledger correlation UUID to a supplied HTTP trace reference.

`report_sha256` covers the canonical payload-free report. Retain that hash with
the incident evidence and compare it before sharing or archiving the file.

## Missing links

Read `missing_links` and investigate the named boundary. Run the integrity
checker and retain its run ID/report hash:

```bash
uv run python ../tools/integrity/check_database.py \
  --report ../local-data/integrity/record-trace-check.json
```

If a link or content hash fails, enable the appropriate write freeze, preserve
a backup and checkpoint, and follow the incident-response runbook. Never edit
source, provenance, ledger, sync operation, server change, audit, or integrity
rows in place. Never add payload fields to the trace report to simplify an
investigation.
