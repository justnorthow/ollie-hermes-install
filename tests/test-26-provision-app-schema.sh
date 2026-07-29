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

echo; echo "passed=$pass failed=$fail"
[[ $fail -eq 0 ]]
