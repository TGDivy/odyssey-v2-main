\set ON_ERROR_STOP on

SELECT format('GRANT CONNECT ON DATABASE odyssey TO %I', :'api_user') \gexec
SELECT format('GRANT CONNECT ON DATABASE odyssey TO %I', :'worker_user') \gexec
SELECT format('GRANT CONNECT ON DATABASE odyssey TO %I', :'backup_user') \gexec
SELECT format('GRANT USAGE ON SCHEMA public TO %I', :'api_user') \gexec
SELECT format('GRANT USAGE ON SCHEMA public TO %I', :'worker_user') \gexec
SELECT format('GRANT USAGE ON SCHEMA public TO %I', :'backup_user') \gexec
SELECT format(
  'GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO %I',
  :'api_user'
) \gexec
SELECT format(
  'GRANT SELECT, UPDATE ON TABLE public.outbox_records TO %I',
  :'worker_user'
) \gexec
SELECT format(
  'GRANT SELECT ON TABLE '
  'public.assertions, public.attachments, public.auth_device_audit, public.auth_devices, '
  'public.canonical_entities, public.context_snapshots, public.decision_preparations, '
  'public.evidence_queries, public.integrity_runs, public.intervention_evaluations, '
  'public.kill_switch_audit, public.kill_switches, public.ledger_events, '
  'public.life_model_versions, '
  'public.owner_identities, public.projection_checkpoints, public.projection_records, '
  'public.provenance_records, public.recommendation_feedback, public.server_changes, '
  'public.source_records, public.sync_conflict_resolutions, public.sync_conflicts, '
  'public.sync_devices, public.sync_operations TO %I',
  :'worker_user'
) \gexec
SELECT format(
  'GRANT SELECT, UPDATE ON TABLE public.export_jobs TO %I',
  :'worker_user'
) \gexec
SELECT format(
  'GRANT SELECT, INSERT ON TABLE public.export_job_audit TO %I',
  :'worker_user'
) \gexec
SELECT format(
  'GRANT USAGE, SELECT ON SEQUENCE public.export_job_audit_sequence_seq TO %I',
  :'worker_user'
) \gexec
SELECT format('GRANT SELECT ON ALL TABLES IN SCHEMA public TO %I', :'backup_user') \gexec
SELECT format(
  'GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA public TO %I',
  :'api_user'
) \gexec
SELECT format('GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO %I', :'backup_user') \gexec
SELECT format(
  'ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA public '
  'GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO %I',
  :'migration_user',
  :'api_user'
) \gexec
SELECT format(
  'ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA public GRANT SELECT ON TABLES TO %I',
  :'migration_user',
  :'backup_user'
) \gexec
SELECT format(
  'ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA public '
  'GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO %I',
  :'migration_user',
  :'api_user'
) \gexec
SELECT format(
  'ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA public GRANT SELECT ON SEQUENCES TO %I',
  :'migration_user',
  :'backup_user'
) \gexec
