# Durable record trace

Use this procedure to trace a synthetic or explicitly owner-approved record
without exporting unrelated payloads.

## Inputs

Start with one of: `source_record_id`, `event_id`, aggregate ID, correlation ID,
or ledger sequence. Record the environment, schema revision, and release SHA.

## Relational trace

The following read-only SQL uses IDs and metadata only. Bind values through the
database client; do not interpolate untrusted input.

```sql
SELECT id, source_kind, occurred_at, recorded_at, content_hash, provenance_id
FROM source_records
WHERE id = :source_record_id;

SELECT id, source_kind, source_id, actor_type, actor_id,
       recorded_at, transformation_chain, content_hash
FROM provenance_records
WHERE id = :provenance_id;

SELECT sequence, event_id, event_type, event_schema_version,
       aggregate_type, aggregate_id, occurred_at, recorded_at,
       correlation_id, causation_id, provenance_id
FROM ledger_events
WHERE event_id = :event_id OR correlation_id = :correlation_id
ORDER BY sequence;

SELECT id, topic, aggregate_id, idempotency_key, status, attempts,
       available_at, completed_at, last_error_code
FROM outbox_records
WHERE idempotency_key = :ledger_idempotency_key;

SELECT projection_name, projection_key, source_sequence,
       projection_version, updated_at
FROM projection_records
WHERE projection_key = :projection_key;

SELECT projection_name, last_sequence, projection_version, updated_at
FROM projection_checkpoints
WHERE projection_name = 'current_entities';
```

For captures, the outbox key is `ledger:<event_id>` and the current projection
key is `<aggregate_type>:<aggregate_id>`. The ledger sequence referenced by the
projection must not exceed the checkpoint, and the checkpoint must reconcile
with the ledger maximum in a healthy current rebuild.

## Verification

Run the integrity checker and retain its run ID/report hash. Confirm:

- source payload canonical hash equals `source_records.content_hash`;
- source and event provenance IDs resolve;
- event type/version exists in the immutable registry;
- outbox retry uses the same idempotency key;
- projection source sequence and version are current;
- no logs or reports contain the source payload.

If any link fails, enable `destructive_compaction`, preserve a checkpoint, and
follow the incident-response runbook. Do not edit source, provenance, ledger,
audit, or integrity-run rows in place.
