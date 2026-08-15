\set ON_ERROR_STOP on

SELECT format('ALTER DATABASE odyssey OWNER TO %I', :'migration_user') \gexec
SELECT format('ALTER SCHEMA public OWNER TO %I', :'migration_user') \gexec
