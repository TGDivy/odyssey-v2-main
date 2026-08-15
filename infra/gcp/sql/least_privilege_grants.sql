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
