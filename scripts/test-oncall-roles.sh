#!/usr/bin/env bash
# Run the assistant's role SQL on a REAL pgvector Postgres and prove what each role may do
# (demo #207, ADR 0003, ADR 0025). Needs docker; run it from anywhere in the repo:
#
#   scripts/test-oncall-roles.sh
#
# What it proves, by trying it:
#   - roles.sql runs on a fresh database, again once the indexer has made its tables, and a third
#     time: the second and third runs change nothing (it must be safe on every ArgoCD sync).
#   - the app role reads the index tables but cannot write them, not even inside an explicit
#     READ WRITE transaction, and cannot create or delete anything;
#   - the app role may write ONE table, llm_usage (the daily LLM budget's ledger), and only inside
#     an explicit `SET TRANSACTION READ WRITE`: a plain write is refused, and the permission does
#     not leak into the next transaction on the same connection (a pooled connection is reused);
#   - the ledger has no DELETE, rejects negative counts, and the indexer cannot even read it;
#   - a grant added by hand is taken away on the next run.
#
# The server is a throwaway container with trust authentication and made-up passwords: it proves
# permissions, not password handling. Nothing here is a real credential.
set -euo pipefail

repo=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
sql="${repo}/apps/oncall-assistant/base/sql/roles.sql"
job="${repo}/apps/oncall-assistant/base/db-roles-job.yaml"
# The same image (pinned by digest) the cluster runs, read from the Job so the two cannot drift.
image=$(grep -oE 'docker\.io/pgvector/pgvector:[^[:space:]]+' "$job" | head -1)
[ -n "$image" ] || { echo "no pgvector image found in ${job}" >&2; exit 1; }
[ -f "$sql" ] || { echo "missing ${sql}" >&2; exit 1; }
command -v docker >/dev/null || { echo "docker not found" >&2; exit 1; }

name="oncall-roles-test-$$"
cleanup() { docker rm -f "$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT
docker run -d --name "$name" -e POSTGRES_USER=oncall_admin -e POSTGRES_DB=oncall \
  -e POSTGRES_HOST_AUTH_METHOD=trust "$image" >/dev/null

# The image starts a temporary server on a unix socket to run initdb, stops it, then starts the
# real one. A TCP connection only works once the real one is up.
ready=false
for _ in $(seq 1 60); do
  if docker exec "$name" psql -X -q -h 127.0.0.1 -U oncall_admin -d oncall -c 'select 1' >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 1
done
[ "$ready" = true ] || { echo "Postgres did not start; last log lines:" >&2; docker logs --tail 15 "$name" >&2; exit 1; }

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

# psql as a named role over TCP. Extra arguments are passed to psql; SQL comes from -c or stdin.
as() {
  local role=$1
  shift
  docker exec -i "$name" psql -X -q -t -A -h 127.0.0.1 -U "$role" -d oncall "$@"
}
admin() { as oncall_admin -v ON_ERROR_STOP=1 "$@"; }

# What the role Job does: the script, as the admin, with its values in the environment.
run_roles() {
  docker exec -i -e PGUSER=oncall_admin -e PGDATABASE=oncall \
    -e INDEXER_PGUSER=oncall_indexer -e INDEXER_PGPASSWORD=made-up-indexer-pw \
    -e APP_PGUSER=oncall_app -e APP_PGPASSWORD=made-up-app-pw \
    "$name" psql -X --quiet -f - <"$sql"
}

allowed() { # description role sql
  local out
  out=$(as "$2" -v ON_ERROR_STOP=1 -c "$3" 2>&1) || fail "$1: refused, but must be allowed: ${out}"
  ok "$1"
}
denied() { # description role expected-message sql
  local out
  if out=$(as "$2" -v ON_ERROR_STOP=1 -c "$4" 2>&1); then
    fail "$1: succeeded, but must be refused"
  fi
  grep -qiF -- "$3" <<<"$out" || fail "$1: refused with the wrong message (wanted '${3}'): ${out}"
  ok "$1"
}
snapshot() { # the parts of the catalog the script is responsible for
  admin -c "SELECT c.relname, pg_get_userbyid(c.relowner), coalesce(c.relacl::text, '')
            FROM pg_class c WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'r' ORDER BY 1"
  admin -c "SELECT rolname, rolsuper, rolcanlogin, rolconnlimit, coalesce(array_to_string(rolconfig, ','), '')
            FROM pg_roles WHERE rolname LIKE 'oncall_%' ORDER BY 1"
  admin -c "SELECT pg_get_userbyid(defaclrole), defaclobjtype, defaclacl FROM pg_default_acl ORDER BY 1, 2"
}

echo "image: ${image##*/}"

# --- run 1: a fresh database, no tables yet (the very first ArgoCD sync) -----------------------
run_roles || fail "roles.sql failed on a fresh database"
ok "roles.sql runs on a fresh database"
[ "$(admin -c "SELECT to_regclass('public.llm_usage') IS NOT NULL")" = "t" ] || fail "the first run did not create llm_usage"
ok "the first run creates the usage ledger"

# --- the indexer makes its tables, as the index code does (shape reduced: only names matter) ---
as oncall_indexer -v ON_ERROR_STOP=1 -c "
  CREATE TABLE index_meta (key text PRIMARY KEY, value text NOT NULL);
  CREATE TABLE documents (repo text NOT NULL, path text NOT NULL, PRIMARY KEY (repo, path));
  CREATE TABLE passages (id text PRIMARY KEY, repo text NOT NULL, path text NOT NULL,
    embedding vector(3) NOT NULL, FOREIGN KEY (repo, path) REFERENCES documents (repo, path));
  INSERT INTO documents VALUES ('r', 'a.md');
  INSERT INTO passages VALUES ('p1', 'r', 'a.md', '[1,2,3]');" >/dev/null || fail "the indexer could not create its tables"
ok "the indexer creates and fills its tables"

# --- run 2 and run 3: idempotent ---------------------------------------------------------------
run_roles || fail "roles.sql failed once the tables exist"
second=$(snapshot)
run_roles || fail "roles.sql failed on a third run"
third=$(snapshot)
[ "$second" = "$third" ] || { diff <(echo "$second") <(echo "$third") >&2 || true; fail "a third run changed the catalog"; }
ok "a repeated run changes nothing"
[ "$(admin -c "SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = 'public.llm_usage'::regclass")" = "oncall_admin" ] \
  || fail "llm_usage must stay owned by the admin (the indexer must have no rights on it)"
ok "the ledger is owned by the admin, not moved to the indexer"
[ "$(admin -c "SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = 'public.passages'::regclass")" = "oncall_indexer" ] \
  || fail "the index tables must belong to the indexer"
ok "the index tables still belong to the indexer"

# --- the app role -----------------------------------------------------------------------------
[ "$(admin -c "SELECT rolsuper OR rolcreatedb OR rolcreaterole FROM pg_roles WHERE rolname = 'oncall_app'")" = "f" ] || fail "the app role has too many attributes"
[ "$(admin -c "SELECT rolconfig::text FROM pg_roles WHERE rolname = 'oncall_app'")" = '{default_transaction_read_only=on}' ] \
  || fail "the app role must keep default_transaction_read_only = on"
ok "the app role is not privileged and stays read-only by default"

allowed "app reads the passages" oncall_app "SELECT count(*) FROM passages"
allowed "app reads the ledger" oncall_app "SELECT count(*) FROM llm_usage"
denied "app cannot write the passages" oncall_app "read-only transaction" "INSERT INTO passages VALUES ('x', 'r', 'a.md', '[1,2,3]')"
denied "app cannot write the passages even inside READ WRITE" oncall_app "permission denied" \
  "BEGIN; SET TRANSACTION READ WRITE; INSERT INTO passages VALUES ('x', 'r', 'a.md', '[1,2,3]'); COMMIT"
denied "app cannot update or delete the documents" oncall_app "permission denied" \
  "BEGIN; SET TRANSACTION READ WRITE; DELETE FROM documents; COMMIT"
denied "app cannot create tables" oncall_app "permission denied" \
  "BEGIN; SET TRANSACTION READ WRITE; CREATE TABLE evil (x int); COMMIT"

denied "a plain write to the ledger is refused" oncall_app "read-only transaction" \
  "INSERT INTO llm_usage (day, who, tokens, calls) VALUES ('2026-11-22', 'public', 10, 1)"
allowed "the ledger takes an explicit READ WRITE upsert" oncall_app "
  BEGIN; SET TRANSACTION READ WRITE;
  INSERT INTO llm_usage (day, who, tokens, calls) VALUES ('2026-11-22', 'public', 100, 1)
    ON CONFLICT (day, who) DO UPDATE SET tokens = llm_usage.tokens + EXCLUDED.tokens, calls = llm_usage.calls + EXCLUDED.calls;
  INSERT INTO llm_usage (day, who, tokens, calls) VALUES ('2026-11-22', 'public', 50, 1)
    ON CONFLICT (day, who) DO UPDATE SET tokens = llm_usage.tokens + EXCLUDED.tokens, calls = llm_usage.calls + EXCLUDED.calls;
  COMMIT"
[ "$(admin -c "SELECT tokens || '/' || calls FROM llm_usage WHERE who = 'public'")" = "150/2" ] || fail "the upserts did not add up to 150 tokens in 2 calls"
ok "two upserts add up (150 tokens, 2 calls)"

# One connection, several transactions: what a pooled connection does. The write permission lasts
# for ONE transaction; the next one on the same connection is read-only again.
out=$(as oncall_app -v ON_ERROR_STOP=0 2>&1 <<'SQL' || true
BEGIN; SET TRANSACTION READ WRITE; INSERT INTO llm_usage (day, who, tokens, calls) VALUES ('2026-11-23', 'public', 7, 1); COMMIT;
INSERT INTO llm_usage (day, who, tokens, calls) VALUES ('2026-11-23', 'leak', 7, 1);
SQL
)
grep -qF "read-only transaction" <<<"$out" || fail "the next transaction on the same connection was not read-only: ${out}"
[ "$(admin -c "SELECT count(*) FROM llm_usage WHERE day = '2026-11-23'")" = "1" ] || fail "the write that should have been refused went through"
ok "the write permission does not leak into the next transaction on the connection"

denied "the ledger has no DELETE" oncall_app "permission denied" \
  "BEGIN; SET TRANSACTION READ WRITE; DELETE FROM llm_usage; COMMIT"
denied "the ledger rejects a negative count" oncall_app "violates check constraint" \
  "BEGIN; SET TRANSACTION READ WRITE; INSERT INTO llm_usage (day, who, tokens, calls) VALUES ('2026-11-24', 'public', -5, 1); COMMIT"
denied "the ledger rejects an empty name" oncall_app "violates check constraint" \
  "BEGIN; SET TRANSACTION READ WRITE; INSERT INTO llm_usage (day, who, tokens, calls) VALUES ('2026-11-24', '', 5, 1); COMMIT"

# --- the indexer: unchanged, and no access to the ledger ---------------------------------------
allowed "the indexer still writes the index" oncall_indexer "INSERT INTO passages VALUES ('p2', 'r', 'a.md', '[3,2,1]')"
denied "the indexer cannot read the ledger" oncall_indexer "permission denied" "SELECT * FROM llm_usage"
denied "the indexer cannot write the ledger" oncall_indexer "permission denied" "INSERT INTO llm_usage (day, who, tokens, calls) VALUES ('2026-11-24', 'x', 1, 1)"

# --- self-healing: a role or grant changed by hand is put back on the next run ------------------
admin -c "GRANT DELETE ON llm_usage TO oncall_app; GRANT INSERT, UPDATE ON passages TO oncall_app; ALTER ROLE oncall_app RESET default_transaction_read_only" >/dev/null
run_roles || fail "roles.sql failed after a hand edit"
denied "a hand-added DELETE on the ledger is taken away" oncall_app "permission denied" \
  "BEGIN; SET TRANSACTION READ WRITE; DELETE FROM llm_usage; COMMIT"
denied "a hand-added write on the passages is taken away" oncall_app "permission denied" \
  "BEGIN; SET TRANSACTION READ WRITE; INSERT INTO passages VALUES ('y', 'r', 'a.md', '[1,2,3]'); COMMIT"
[ "$(admin -c "SELECT rolconfig::text FROM pg_roles WHERE rolname = 'oncall_app'")" = '{default_transaction_read_only=on}' ] \
  || fail "the read-only default was not put back"
ok "the read-only default is put back"

echo "all role checks passed"
