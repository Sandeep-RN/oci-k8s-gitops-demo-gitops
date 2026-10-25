-- The backend's own Postgres role (ADR 0018): not a superuser, owns only the
-- tables the app creates. Run by the postgres-app-role Job as the admin role
-- (POSTGRES_USER) on every ArgoCD sync, so it must be safe to run again:
-- on a fresh database, on an existing one, and after a password change.
-- Values come from the environment, never from the command line (where other
-- processes could read them) and never pasted into SQL by hand.
\set ON_ERROR_STOP on
\getenv app_user APP_PGUSER
\getenv app_password APP_PGPASSWORD
\getenv db PGDATABASE

SELECT format('CREATE ROLE %I LOGIN', :'app_user')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'app_user') \gexec

-- Stated in full every time, so a role changed by hand is put back. Setting the
-- password here is also how it rotates: re-seal the Secret, sync.
ALTER ROLE :"app_user" WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE
  NOREPLICATION NOBYPASSRLS PASSWORD :'app_password';

GRANT CONNECT ON DATABASE :"db" TO :"app_user";
-- CREATE on the schema: the app creates its table on first use (ADR 0016).
-- Postgres checks this even for CREATE TABLE IF NOT EXISTS on an existing table.
GRANT USAGE, CREATE ON SCHEMA public TO :"app_user";

-- Tables made before this role existed (or restored by the admin) belong to the
-- admin; hand them over. On a fresh database the app creates them as itself.
SELECT format('ALTER TABLE public.links OWNER TO %I', :'app_user')
WHERE to_regclass('public.links') IS NOT NULL \gexec
