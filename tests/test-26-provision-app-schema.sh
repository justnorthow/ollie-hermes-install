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

# A compose file that consumes PGRST_DB_SCHEMAS from .env, as the current
# template does. The script REFUSES a compose file without that reference
# (an empty `touch`ed file included) — a hardcoded literal there makes the
# whole .env registration a silent no-op. Quoted heredoc: ${...} stays literal.
write_compose() { # DIR
  cat > "$1/docker-compose.yml" <<'YMLEOF'
services:
  rest:
    environment:
      - PGRST_DB_SCHEMAS=${PGRST_DB_SCHEMAS:-public}
YMLEOF
}

# a core stack dir that looks real
CORE="$HOME/supabase-stack"; mkdir -p "$CORE"
cat > "$CORE/.env" <<'ENVEOF'
JWT_SECRET=ec3ca9f92d1de0f79e03897b324c9ec100ec647e
ANON_KEY=stub-anon
SERVICE_ROLE_KEY=stub-service
POSTGRES_PASSWORD=pw
PGRST_DB_SCHEMAS=public
ENVEOF
write_compose "$CORE"

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
# The connecting role must be made a MEMBER of the owner role before anything is
# created AUTHORIZATION-ed to it. Supabase's `postgres` is NOT a superuser and on
# PG15 creating a role grants the creator no membership, so
# CREATE SCHEMA ... AUTHORIZATION <owner> fails with `must be member of role`.
# Caught on the dev box 2026-07-30; every existing test passed because the harness
# only logs SQL text and never executes it against a real Postgres.
grep -qE "GRANT popbys_owner TO (CURRENT_USER|postgres)" "$PSQL_SQL_LOG" \
  && ok "grants the owner role to the connecting role" \
  || bad "grants the owner role to the connecting role"

# ...and it must precede CREATE SCHEMA, or the CREATE still fails.
awk '/GRANT popbys_owner TO (CURRENT_USER|postgres)/{g=NR} /CREATE SCHEMA IF NOT EXISTS popbys/{c=NR} END{exit !(g && c && g < c)}' "$PSQL_SQL_LOG" \
  && ok "the membership grant precedes CREATE SCHEMA" \
  || bad "the membership grant precedes CREATE SCHEMA"

# The grantee must be the LITERAL role. `GRANT <role> TO CURRENT_USER` SEGFAULTS
# the backend on PostgreSQL 15.8 (signal 11), killing every other connection and
# forcing database-wide recovery — observed on the dev box 2026-07-30 while
# fixing the membership bug above. Never reintroduce the CURRENT_USER form.
grep -q "GRANT popbys_owner TO CURRENT_USER" "$PSQL_SQL_LOG" \
  && bad "grantee is a literal role, not CURRENT_USER (segfaults PG 15.8)" \
  || ok "grantee is a literal role, not CURRENT_USER (segfaults PG 15.8)"

# Schema `auth` is owned by supabase_admin, and `postgres` holds USAGE WITHOUT
# GRANT OPTION. Granting from postgres emits `WARNING: no privileges were
# granted for "auth"` and returns success — ON_ERROR_STOP=1 does not catch
# warnings, so the script exited 0 while an app's FK to auth.users would later
# die with `permission denied for schema auth`. The cross-schema grants must be
# issued by the schema owner. Found on the dev box 2026-07-30.
grep -q "supabase_admin" "$DOCKER_LOG" \
  && ok "cross-schema grants are issued as supabase_admin" \
  || bad "cross-schema grants are issued as supabase_admin"

# Belt and braces: because that failure mode is a WARNING rather than an error,
# the script must PROVE the privileges landed instead of trusting the exit code.
grep -qE "has_schema_privilege\('popbys_owner', *'auth'" "$PSQL_SQL_LOG" \
  && ok "verifies the auth grants actually landed" \
  || bad "verifies the auth grants actually landed"

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
# Closed whitelist over every statement that names the `auth` schema. A
# case-insensitive grep for "TRIGGER" was wrong in both directions: it would
# PASS on `GRANT ALL ON auth.users` (which implies TRIGGER), and it would
# false-fail the moment a legitimate CREATE TRIGGER appears in an app's own
# schema. Asserting the exact set instead catches GRANT ALL, catches any added
# privilege, and stops depending on the word "trigger" appearing anywhere.
# \bauth\b matches `auth.users` / `SCHEMA auth` but not authenticator/authenticated;
# -- comment lines are stripped first.
# Scoped to PRIVILEGE-CHANGING statements, which is what this assertion is
# actually about: the script must grant nothing on auth beyond these two. It
# previously matched ANY line mentioning auth, which also caught read-only
# checks — the has_schema_privilege/has_table_privilege verification that
# proves the grants landed is not a privilege change and must not trip it.
AUTH_STMTS="$(grep -vE '^[[:space:]]*--' "$PSQL_SQL_LOG" | grep -E '\bauth\b' \
  | grep -E '^[[:space:]]*(GRANT|REVOKE|ALTER[[:space:]]+DEFAULT[[:space:]]+PRIVILEGES)\b' \
  | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | sort -u)"
# sorted, since AUTH_STMTS is `sort -u`d
AUTH_STMTS_EXPECTED='GRANT REFERENCES ON TABLE auth.users TO popbys_owner;
GRANT USAGE ON SCHEMA auth TO popbys_owner;'
if [[ "$AUTH_STMTS" == "$AUTH_STMTS_EXPECTED" ]]; then
  ok "auth statements are exactly USAGE ON SCHEMA auth + REFERENCES ON auth.users"
else
  bad "auth statements are exactly USAGE ON SCHEMA auth + REFERENCES ON auth.users"
  echo "     got:      ${AUTH_STMTS//$'\n'/ | }"
  echo "     expected: ${AUTH_STMTS_EXPECTED//$'\n'/ | }"
fi

# The owner role must reach `extensions`. Supabase installs uuid-ossp, pgcrypto
# and friends there, and a migration calling uuid_generate_v4() UNQUALIFIED
# cannot be relocated into the app schema — it resolves through search_path.
# Putting the schema on the search_path is not enough: without USAGE the role
# cannot see anything in it. Hit live cutting HIA over — its first migration
# died on "function uuid_generate_v4() does not exist" with the search_path
# already set. USAGE only: the role gets to CALL extension functions, not to
# create anything there.
grep -q "GRANT USAGE ON SCHEMA extensions TO popbys_owner" "$PSQL_SQL_LOG" \
  && ok "grants USAGE on extensions to the owner role" \
  || bad "no USAGE on extensions — unqualified extension calls will fail"
grep -qE "has_schema_privilege\('popbys_owner', *'extensions'" "$PSQL_SQL_LOG" \
  && ok "verifies the extensions grant actually landed" \
  || bad "does not verify the extensions grant landed"
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
write_compose "$CORE2"

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
grep -v '^PGRST_DB_SCHEMAS=' "$CORE/.env" > "$CORE3/.env"; write_compose "$CORE3"
reset_logs
run "APP_NAME=popbys" "CORE_STACK_DIR=$CORE3" >/dev/null 2>&1
grep -q "^PGRST_DB_SCHEMAS=public,popbys$" "$CORE3/.env" \
  && ok "absent key is created with public first" || bad "absent key is created with public first"

# regression: sed-special characters in PGRST_DB_SCHEMAS must not corrupt the file
# (ampersand is a sed replacement metachar; backslash and pipe are also special)
CORE4="$HOME/core4"; mkdir -p "$CORE4"
cat > "$CORE4/.env" <<'ENVEOF'
JWT_SECRET=ec3ca9f92d1de0f79e03897b324c9ec100ec647e
ANON_KEY=stub-anon
SERVICE_ROLE_KEY=stub-service
POSTGRES_PASSWORD=pw
PGRST_DB_SCHEMAS=public,weird&name
ENVEOF
write_compose "$CORE4"
reset_logs
run "APP_NAME=popbys" "CORE_STACK_DIR=$CORE4" >/dev/null 2>&1
grep -q "^PGRST_DB_SCHEMAS=public,weird&name,popbys$" "$CORE4/.env" \
  && ok "sed-special chars in PGRST_DB_SCHEMAS do not corrupt the file" || bad "sed-special chars in PGRST_DB_SCHEMAS do not corrupt the file"

# a compose file that hardcodes the schema list must be REFUSED, not "succeeded"
# past. `rest` has no env_file:, and --env-file only expands ${VAR} references,
# so with the old literal the .env write reaches nothing and the schema 404s.
CORE6="$HOME/core6"; mkdir -p "$CORE6"
cat > "$CORE6/.env" <<'ENVEOF'
JWT_SECRET=ec3ca9f92d1de0f79e03897b324c9ec100ec647e
ANON_KEY=stub-anon
SERVICE_ROLE_KEY=stub-service
POSTGRES_PASSWORD=pw
PGRST_DB_SCHEMAS=public
ENVEOF
cat > "$CORE6/docker-compose.yml" <<'YMLEOF'
services:
  rest:
    environment:
      - PGRST_DB_SCHEMAS=public
YMLEOF
reset_logs
out="$(run "APP_NAME=popbys" "CORE_STACK_DIR=$CORE6" 2>&1)" \
  && bad "unparameterised compose file refused" || ok "unparameterised compose file refused"
# `error.*` and not a bare PGRST_DB_SCHEMAS match: the happy-path progress line
# also prints the key name, so a bare grep would pass with the guard removed.
grep -qE "error.*PGRST_DB_SCHEMAS" <<<"$out" \
  && ok "error names PGRST_DB_SCHEMAS" || bad "error names PGRST_DB_SCHEMAS"
grep -q "^PGRST_DB_SCHEMAS=public$" "$CORE6/.env" \
  && ok "refusal leaves .env unmodified" || bad "refusal leaves .env unmodified"
[[ ! -s "$PSQL_SQL_LOG" ]] \
  && ok "refusal happens before any SQL is issued" || bad "refusal happens before any SQL is issued"

# ---- owner JWT ----
reset_logs
run "APP_NAME=popbys" "CORE_STACK_DIR=$CORE" >/dev/null 2>&1
KEYFILE="$CORE/app-keys/popbys.jwt"
[[ -f "$KEYFILE" ]] && ok "owner JWT written" || bad "owner JWT written"
[[ "$(cat "$KEYFILE" 2>/dev/null | tr -cd '.' | wc -c)" == "2" ]] \
  && ok "JWT has three segments" || bad "JWT has three segments"
python3 - "$KEYFILE" <<'PY' && ok "JWT role claim is popbys_owner" || bad "JWT role claim is popbys_owner"
import base64, json, sys
tok = open(sys.argv[1]).read().strip().split(".")[1]
tok += "=" * (-len(tok) % 4)
sys.exit(0 if json.loads(base64.urlsafe_b64decode(tok))["role"] == "popbys_owner" else 1)
PY
# Exercises script 26's grep/cut extraction of JWT_SECRET and the stdin pipe
# into gen-supabase-keys.py — not just mint_hs256_jwt() in isolation — against
# the known secret already in $CORE/.env (JWT_SECRET=ec3ca9f92d1de0f79e03897b324c9ec100ec647e).
python3 - "$KEYFILE" <<'PY' && ok "JWT signature verifies against the core secret" || bad "JWT signature verifies against the core secret"
import base64, hashlib, hmac, sys
secret = "ec3ca9f92d1de0f79e03897b324c9ec100ec647e"
header, payload, sig = open(sys.argv[1]).read().strip().split(".")
sig += "=" * (-len(sig) % 4)
expected = hmac.new(secret.encode(), f"{header}.{payload}".encode(), hashlib.sha256).digest()
sys.exit(0 if base64.urlsafe_b64decode(sig) == expected else 1)
PY

# a missing JWT_SECRET fails with a message naming it, instead of aborting
# silently under `set -euo pipefail` when the grep in the extraction finds
# nothing (regression: line 90's PGRST_DB_SCHEMAS extraction already guards
# with `|| true` for exactly this; the JWT_SECRET extraction must match it)
CORE5="$HOME/core5"; mkdir -p "$CORE5"
grep -v '^JWT_SECRET=' "$CORE/.env" > "$CORE5/.env"; write_compose "$CORE5"
reset_logs
out="$(run "APP_NAME=popbys" "CORE_STACK_DIR=$CORE5" 2>&1)"
rc=$?
[[ $rc -ne 0 ]] && ok "missing JWT_SECRET fails" || bad "missing JWT_SECRET fails"
grep -qi "JWT_SECRET" <<<"$out" && ok "error names JWT_SECRET" || bad "error names JWT_SECRET"

echo; echo "passed=$pass failed=$fail"
[[ $fail -eq 0 ]]
