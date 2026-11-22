-- The assistant's Postgres roles (ADR 0025; same pattern as ADR 0018).
--
--   admin    superuser, from initdb. Held only by the Postgres pod and the
--            role Job that runs this script.
--   indexer  owns the index tables; used by the index CronJob. Not a
--            superuser: the Job fetches content from the internet every night,
--            and a superuser can run shell commands in the database container
--            (COPY ... TO PROGRAM).
--   app      read-only; used by the app, which only searches.
--
-- Run as the admin by the oncall-db-roles Job on every ArgoCD sync, so it must
-- be safe to run again: on a fresh database, on an existing one, and after a
-- password change. Values come from the environment, never from the command
-- line (where other processes could read them) and never pasted into SQL.
\set ON_ERROR_STOP on
-- Keep the Job log to real problems (no "already exists, skipping" notices).
SET client_min_messages = warning;
\getenv indexer_user INDEXER_PGUSER
\getenv indexer_password INDEXER_PGPASSWORD
\getenv app_user APP_PGUSER
\getenv app_password APP_PGPASSWORD
\getenv db PGDATABASE

-- pgvector is not a "trusted" extension, so only a superuser may create it.
-- The indexer's own CREATE EXTENSION IF NOT EXISTS then finds it and does nothing.
CREATE EXTENSION IF NOT EXISTS vector;

SELECT format('CREATE ROLE %I LOGIN', :'indexer_user')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'indexer_user') \gexec
SELECT format('CREATE ROLE %I LOGIN', :'app_user')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'app_user') \gexec

-- Stated in full every time, so a role changed by hand is put back. Setting the
-- password here is also how it rotates: re-seal the Secret, sync.
-- Connection limits: the app's pool holds 2; an index run holds 1.
ALTER ROLE :"indexer_user" WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE
  NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 3 PASSWORD :'indexer_password';
ALTER ROLE :"app_user" WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE
  NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 5 PASSWORD :'app_password';
-- A second lock on the app role: even a grant added by mistake cannot write.
ALTER ROLE :"app_user" SET default_transaction_read_only = on;

-- Only these two roles (and the admin) may connect; PUBLIC also loses TEMP.
REVOKE ALL ON DATABASE :"db" FROM PUBLIC;
GRANT CONNECT ON DATABASE :"db" TO :"indexer_user", :"app_user";

-- Postgres 15+ gives PUBLIC no CREATE on schema public; the indexer needs it to
-- create its tables (the app's index code runs CREATE TABLE IF NOT EXISTS,
-- which Postgres checks even when the table exists). The app only reads.
GRANT USAGE, CREATE ON SCHEMA public TO :"indexer_user";
GRANT USAGE ON SCHEMA public TO :"app_user";
REVOKE CREATE ON SCHEMA public FROM :"app_user";

-- Tables made before the indexer role existed (or by the admin by hand)
-- belong to the indexer from now on, so it can keep writing them.
SELECT format('ALTER TABLE public.%I OWNER TO %I', tablename, :'indexer_user')
FROM pg_tables
WHERE schemaname = 'public' AND tableowner <> :'indexer_user' \gexec

-- The app reads every table the indexer has made or will make.
GRANT SELECT ON ALL TABLES IN SCHEMA public TO :"app_user";
ALTER DEFAULT PRIVILEGES FOR ROLE :"indexer_user" IN SCHEMA public
  GRANT SELECT ON TABLES TO :"app_user";
