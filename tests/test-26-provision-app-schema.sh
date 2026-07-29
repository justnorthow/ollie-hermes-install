#!/usr/bin/env bash
# tests/test-26-provision-app-schema.sh — shim-based checks for app schema provisioning.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
mkdir -p "$T/bin"

# docker shim: log argv, and capture psql stdin (the SQL) for assertions.
cat > "$T/bin/docker" <<'SH'
#!/usr/bin/env bash
echo "docker $*" >> "${DOCKER_LOG}"
if [[ "$*" == *psql* ]]; then cat >> "${PSQL_SQL_LOG}"; fi
exit 0
SH
chmod +x "$T/bin/docker"
export PATH="$T/bin:$PATH" DOCKER_LOG="$T/docker.log" PSQL_SQL_LOG="$T/psql.sql"

# a core stack dir that looks real
CORE="$HOME/supabase-stack"; mkdir -p "$CORE"
cat > "$CORE/.env" <<'ENVEOF'
JWT_SECRET=ec3ca9f92d1de0f79e03897b324c9ec100ec647e
ANON_KEY=stub-anon
SERVICE_ROLE_KEY=stub-service
POSTGRES_PASSWORD=pw
PGRST_DB_SCHEMAS=public
ENVEOF
touch "$CORE/docker-compose.yml"

run() { printf '%s\n' "$@" | bash "${DIR}/scripts/26-provision-app-schema.sh"; }
reset_logs() { : > "$DOCKER_LOG"; : > "$PSQL_SQL_LOG"; }

# 1. missing APP_NAME refuses
reset_logs
run "CORE_STACK_DIR=$CORE" >/dev/null 2>&1 \
  && bad "missing APP_NAME refused" || ok "missing APP_NAME refused"

# 2. hyphens refused — not a valid unquoted Postgres identifier
reset_logs
run "APP_NAME=pop-bys" "CORE_STACK_DIR=$CORE" >/dev/null 2>&1 \
  && bad "hyphenated name refused" || ok "hyphenated name refused"

# 3. uppercase refused
reset_logs
run "APP_NAME=PopBys" "CORE_STACK_DIR=$CORE" >/dev/null 2>&1 \
  && bad "uppercase name refused" || ok "uppercase name refused"

# 4. missing core stack dir refuses with a useful message
reset_logs
out="$(run "APP_NAME=popbys" "CORE_STACK_DIR=$T/nope" 2>&1)" \
  && bad "missing core dir refused" || ok "missing core dir refused"
grep -qi "core stack" <<<"$out" && ok "error names the core stack dir" || bad "error names the core stack dir"

# 5. happy path exits 0
reset_logs
run "APP_NAME=popbys" "CORE_STACK_DIR=$CORE" >/dev/null 2>&1 \
  && ok "happy path exits 0" || bad "happy path exits 0"

# ---- SQL provisioning ----
reset_logs
run "APP_NAME=popbys" "CORE_STACK_DIR=$CORE" >/dev/null 2>&1

# positive: the things that must exist
grep -q "CREATE SCHEMA IF NOT EXISTS popbys" "$PSQL_SQL_LOG" \
  && ok "creates the schema" || bad "creates the schema"
grep -q "CREATE ROLE popbys_owner" "$PSQL_SQL_LOG" \
  && ok "creates the owner role" || bad "creates the owner role"
grep -q "ALTER SCHEMA popbys OWNER TO popbys_owner" "$PSQL_SQL_LOG" \
  && ok "role owns the schema" || bad "role owns the schema"
grep -qE "GRANT USAGE ON SCHEMA popbys TO anon, authenticated, service_role" "$PSQL_SQL_LOG" \
  && ok "PostgREST roles can reach the schema" || bad "PostgREST roles can reach the schema"
grep -q "GRANT popbys_owner TO authenticator" "$PSQL_SQL_LOG" \
  && ok "authenticator can switch into the owner role" || bad "authenticator can switch into the owner role"
grep -q "GRANT USAGE ON SCHEMA auth TO popbys_owner" "$PSQL_SQL_LOG" \
  && ok "owner may reference the auth schema" || bad "owner may reference the auth schema"
grep -q "GRANT REFERENCES ON TABLE auth.users TO popbys_owner" "$PSQL_SQL_LOG" \
  && ok "owner may FK to auth.users" || bad "owner may FK to auth.users"
grep -q "ALTER DEFAULT PRIVILEGES FOR ROLE popbys_owner IN SCHEMA popbys" "$PSQL_SQL_LOG" \
  && ok "future tables are reachable by PostgREST roles" || bad "future tables are reachable by PostgREST roles"

# NEGATIVE — these are the isolation guarantees the design rests on.
grep -qiE "GRANT .* ON SCHEMA public TO popbys_owner" "$PSQL_SQL_LOG" \
  && bad "must NOT grant on public" || ok "must NOT grant on public"
grep -qi "TRIGGER" "$PSQL_SQL_LOG" \
  && bad "must NOT grant TRIGGER on auth.users" || ok "must NOT grant TRIGGER on auth.users"
grep -q "REVOKE ALL ON SCHEMA public FROM popbys_owner" "$PSQL_SQL_LOG" \
  && ok "explicitly revokes public" || bad "explicitly revokes public"

# idempotency: a second run must not error and must not double-create
reset_logs
run "APP_NAME=popbys" "CORE_STACK_DIR=$CORE" >/dev/null 2>&1 \
  && ok "re-run exits 0" || bad "re-run exits 0"
[[ "$(grep -c 'CREATE SCHEMA IF NOT EXISTS popbys' "$PSQL_SQL_LOG")" == "1" ]] \
  && ok "re-run issues the schema create once" || bad "re-run issues the schema create once"

# ---- PostgREST registration ----
# Write CORE2 fresh rather than copying $CORE/.env — earlier happy-path runs
# already appended popbys to $CORE's PGRST_DB_SCHEMAS, so a copy would start
# from "public,popbys" and these assertions would be testing the wrong thing.
CORE2="$HOME/core2"; mkdir -p "$CORE2"
cat > "$CORE2/.env" <<'ENVEOF'
JWT_SECRET=ec3ca9f92d1de0f79e03897b324c9ec100ec647e
ANON_KEY=stub-anon
SERVICE_ROLE_KEY=stub-service
POSTGRES_PASSWORD=pw
PGRST_DB_SCHEMAS=public
ENVEOF
touch "$CORE2/docker-compose.yml"

reset_logs
run "APP_NAME=popbys" "CORE_STACK_DIR=$CORE2" >/dev/null 2>&1
grep -q "^PGRST_DB_SCHEMAS=public,popbys$" "$CORE2/.env" \
  && ok "schema appended to PGRST_DB_SCHEMAS" || bad "schema appended to PGRST_DB_SCHEMAS"
grep -q "force-recreate rest" "$DOCKER_LOG" \
  && ok "rest recreated so the schema is served" || bad "rest recreated so the schema is served"

# idempotent: re-run must not append twice
reset_logs
run "APP_NAME=popbys" "CORE_STACK_DIR=$CORE2" >/dev/null 2>&1
grep -q "^PGRST_DB_SCHEMAS=public,popbys$" "$CORE2/.env" \
  && ok "re-run leaves PGRST_DB_SCHEMAS unchanged" || bad "re-run leaves PGRST_DB_SCHEMAS unchanged"

# a second app appends rather than replaces
reset_logs
run "APP_NAME=hia" "CORE_STACK_DIR=$CORE2" >/dev/null 2>&1
grep -q "^PGRST_DB_SCHEMAS=public,popbys,hia$" "$CORE2/.env" \
  && ok "second app appends" || bad "second app appends"

# a missing key is created rather than silently skipped
CORE3="$HOME/core3"; mkdir -p "$CORE3"
grep -v '^PGRST_DB_SCHEMAS=' "$CORE/.env" > "$CORE3/.env"; touch "$CORE3/docker-compose.yml"
reset_logs
run "APP_NAME=popbys" "CORE_STACK_DIR=$CORE3" >/dev/null 2>&1
grep -q "^PGRST_DB_SCHEMAS=public,popbys$" "$CORE3/.env" \
  && ok "absent key is created with public first" || bad "absent key is created with public first"

echo; echo "passed=$pass failed=$fail"
[[ $fail -eq 0 ]]
