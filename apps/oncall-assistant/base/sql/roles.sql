-- The assistant's Postgres roles (ADR 0025; same pattern as ADR 0018).
--
--   admin    superuser, from initdb. Held only by the Postgres pod and the
--            role Job that runs this script.
--   indexer  owns the index tables; used by the index CronJob. Not a
--            superuser: the Job fetches content from the internet every night,
--            and a superuser can run shell commands in the database container
--            (COPY ... TO PROGRAM). No access to the usage ledger.
--   app      read-only; used by the app, which only searches. ONE exception
--            (ADR 0003, app issue #6): it may insert into and update the daily
--            LLM budget's ledger, llm_usage, and nothing else. It writes there
--            only inside an explicit `SET TRANSACTION READ WRITE`; the role's
--            read-only default (below) stays on, so any other write path fails.
--            scripts/test-oncall-roles.sh proves all of this on a real Postgres.
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

-- The daily LLM budget's ledger (ADR 0003): tokens and calls per UTC day and
-- per caller ("public" or a demo token's name). Owned by the admin and kept out
-- of the loop below on purpose: the indexer, which fetches from the internet,
-- has no business with it. The database is a cache (ADR 0025): losing this
-- table only hands out a fresh day's budget, and the provider's own limit is
-- the hard stop.
CREATE TABLE IF NOT EXISTS public.llm_usage (
  day    date    NOT NULL,
  who    text    NOT NULL CHECK (char_length(who) BETWEEN 1 AND 64),
  tokens bigint  NOT NULL DEFAULT 0 CHECK (tokens >= 0),
  calls  integer NOT NULL DEFAULT 0 CHECK (calls >= 0),
  PRIMARY KEY (day, who)
);

-- Tables made before the indexer role existed (or by the admin by hand)
-- belong to the indexer from now on, so it can keep writing them. Not the
-- ledger.
SELECT format('ALTER TABLE public.%I OWNER TO %I', tablename, :'indexer_user')
FROM pg_tables
WHERE schemaname = 'public' AND tableowner <> :'indexer_user'
  AND tablename <> 'llm_usage' \gexec

-- What the app may do with tables, stated in full every time so a grant added
-- by hand is taken away on the next sync. In one transaction, so the app never
-- sees a moment with fewer rights than it should have.
--   - read every table the indexer has made or will make;
--   - the ledger: also insert and update (an upsert needs both), never delete.
-- Nothing is granted on the schema beyond USAGE (above), so it cannot create
-- tables.
BEGIN;
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM :"app_user";
REVOKE ALL ON public.llm_usage FROM PUBLIC, :"indexer_user";
GRANT SELECT ON ALL TABLES IN SCHEMA public TO :"app_user";
GRANT INSERT, UPDATE ON public.llm_usage TO :"app_user";
COMMIT;
ALTER DEFAULT PRIVILEGES FOR ROLE :"indexer_user" IN SCHEMA public
  GRANT SELECT ON TABLES TO :"app_user";
