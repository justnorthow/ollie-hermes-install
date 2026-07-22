#!/usr/bin/env bash
# tests/test-24-install-agent-apps.sh — shim-based checks for the agent-apps
# orchestrator (manifest -> 20 -> app migrations -> 23 -> caddy reminder).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
mkdir -p "$T/bin"

# 24's mf() shells out to python3 -c with the manifest path embedded in the
# python source string. On MSYS bash + a native Windows python3.exe, MSYS
# only rewrites POSIX paths that are argv tokens, not ones embedded inside a
# larger string argument — so a plain mktemp path (/tmp/...) 404s from
# python3's perspective even though bash can see it fine. Use a
# Windows-native (drive-letter, forward-slash) path for the manifest dir so
# both bash and python3.exe resolve it; harmless no-op on real POSIX boxes
# where cygpath doesn't exist.
TW="$(cygpath -m "$T" 2>/dev/null || printf '%s' "$T")"

# ---- fixture manifest ----
export MANIFEST_DIR="$TW/apps"; mkdir -p "$MANIFEST_DIR"
cat > "$MANIFEST_DIR/real-estate.json" <<'JSON'
{
  "profile": "real-estate",
  "apps": [
    {
      "name": "popbys",
      "stack": { "kong_port": 8030, "email_enabled": "false" },
      "server": { "app_port": 8130, "container_port": 8080, "health_path": "/api/health" }
    }
  ]
}
JSON

# ---- fixture stacks dir (SUB20 stub writes popbys/.env here) ----
export STACKS_DIR="$T/stacks"; mkdir -p "$STACKS_DIR"

# ---- fixture orchestrator env file ----
mkdir -p "$T/hermes-stack"
cat > "$T/hermes-stack/.env" <<'EOF'
ORCHESTRATOR_KEY=orch-key-1==
EOF

# ---- fixture migrations (what the fake docker cp extracts from the image) ----
FIXTURE_MIG_DIR="$T/fixture-migrations"; mkdir -p "$FIXTURE_MIG_DIR"
cat > "$FIXTURE_MIG_DIR/0001_init.sql" <<'SQL'
select 1;
SQL
cat > "$FIXTURE_MIG_DIR/0002_second.sql" <<'SQL'
select 2;
SQL
export FIXTURE_MIG_DIR

# ---- migration-applied state (drives the fake psql's SELECT responses) ----
export MIGSTATE_FILE="$T/migstate"
: > "$MIGSTATE_FILE"

# ---- SUB20 stub: logs stdin; materializes the stack .env that 24 reads later ----
export SUB20_LOG="$T/sub20.log"
cat > "$T/bin/sub20.sh" <<'SH'
#!/usr/bin/env bash
set -eu
cat > "${SUB20_LOG}"
mkdir -p "${STACKS_DIR}/popbys"
cat > "${STACKS_DIR}/popbys/.env" <<ENVEOF
ANON_KEY=stub-anon
POSTGRES_PASSWORD=pw
SUPABASE_PUBLIC_URL=https://sb-popbys.test
SITE_URL=https://popbys.test
ENVEOF
SH
export SUB20="$T/bin/sub20.sh"
chmod +x "$SUB20"

# ---- SUB23 stub: logs stdin only ----
export SUB23_LOG="$T/sub23.log"
cat > "$T/bin/sub23.sh" <<'SH'
#!/usr/bin/env bash
set -eu
cat > "${SUB23_LOG}"
SH
export SUB23="$T/bin/sub23.sh"
chmod +x "$SUB23"

# ---- fake docker: logs full argv; simulates load/create/cp/rm and the
# compose-exec'd psql (create-table / SELECT-applied / single-transaction
# -1 -f - apply) ----
export DOCKER_LOG="$T/docker.log"
# Per-apply stdin capture: 24 now pipes {migration SQL + tracker INSERT} as
# ONE stream into a single `psql -1 -f -` (see F2 — transactional apply).
# Tee that stdin to a per-call file so the test can assert the INSERT
# travelled in the SAME call as the file content, not a separate -c.
export APPLY_LOG_DIR="$T/applies"; mkdir -p "$APPLY_LOG_DIR"
export APPLY_COUNT_FILE="$T/apply-count"
cat > "$T/bin/docker" <<'SH'
#!/usr/bin/env bash
echo "docker $*" >> "${DOCKER_LOG}"
case "$1" in
  load)
    # F4: multi.tar simulates a multi-image tarball (same convention as
    # tests/test-23-install-app-server.sh) so 24's single-image guard can be
    # exercised without a real docker daemon.
    if [[ "$3" == *"multi.tar"* ]]; then
      echo "Loaded image: image1:tag1"
      echo "Loaded image: image2:tag2"
    else
      echo "Loaded image: fake-app-image:local"
    fi
    ;;
  create)
    echo "ctr-fake-1"
    ;;
  cp)
    dest="$3"
    cp "${FIXTURE_MIG_DIR}"/*.sql "${dest}" 2>/dev/null || true
    ;;
  rm)
    : ;;
  compose)
    n=$#
    if [[ "$n" -ge 2 && "${!n}" == "-" && "${@: -2:1}" == "-f" ]]; then
      # single-transaction apply: stdin carries the migration SQL followed
      # by the tracker INSERT in one stream (mirrors real psql -1 -f -
      # committing both together).
      idx=0
      [[ -f "${APPLY_COUNT_FILE}" ]] && idx="$(cat "${APPLY_COUNT_FILE}")"
      idx=$((idx+1)); echo "${idx}" > "${APPLY_COUNT_FILE}"
      content="$(cat)"
      printf '%s' "${content}" > "${APPLY_LOG_DIR}/apply-${idx}.stdin"
      name="$(printf '%s' "${content}" | sed -nE "s/.*values \\('([^']+)'\\).*/\1/p" | tail -1)"
      [[ -n "${name}" ]] && echo "${name}" >> "${MIGSTATE_FILE}"
    else
      prev=""; cval=""
      for a in "$@"; do
        [[ "${prev}" == "-c" ]] && cval="${a}"
        prev="${a}"
      done
      case "${cval}" in
        *"create table if not exists"*) : ;;
        *"select 1 from public._app_migrations where name="*)
          name="$(echo "${cval}" | sed -E "s/.*name='([^']+)'.*/\1/")"
          if grep -qxF "${name}" "${MIGSTATE_FILE}" 2>/dev/null; then echo 1; fi
          ;;
      esac
    fi
    ;;
esac
exit 0
SH
chmod +x "$T/bin/docker"
export PATH="$T/bin:$PATH"

: > "$T/img.tar"

STDIN=(
  "APP_HOST=popbys.test"
  "SB_HOST=sb-popbys.test"
  "IMAGE_TARBALL=$T/img.tar"
  "GOOGLE_CLIENT_ID=gid"
  "ORCH_ENV_FILE=$T/hermes-stack/.env"
)

run() { # PROFILE KEY=VALUE...
  local profile="$1"; shift
  printf '%s\n' "$@" | bash "${DIR}/scripts/24-install-agent-apps.sh" "${profile}" > "$T/out.log" 2>&1
}

# 1. happy path: SUB20 gets the right stack params
: > "$DOCKER_LOG"; : > "$SUB20_LOG"; : > "$SUB23_LOG"
rm -rf "$APPLY_LOG_DIR"; mkdir -p "$APPLY_LOG_DIR"; rm -f "$APPLY_COUNT_FILE"
run "real-estate" "${STDIN[@]}" && ok "happy path exits 0" || bad "happy path exits 0"
grep -q '^STACK_NAME=popbys$' "$SUB20_LOG" && ok "SUB20 got STACK_NAME" || bad "SUB20 got STACK_NAME"
grep -q '^KONG_PORT=8030$' "$SUB20_LOG" && ok "SUB20 got KONG_PORT" || bad "SUB20 got KONG_PORT"
grep -q '^SUPABASE_PUBLIC_URL=https://sb-popbys.test$' "$SUB20_LOG" && ok "SUB20 got SUPABASE_PUBLIC_URL" || bad "SUB20 got SUPABASE_PUBLIC_URL"
grep -q '^SITE_URL=https://popbys.test$' "$SUB20_LOG" && ok "SUB20 got SITE_URL" || bad "SUB20 got SITE_URL"
grep -q '^EMAIL_ENABLED=false$' "$SUB20_LOG" && ok "SUB20 got EMAIL_ENABLED" || bad "SUB20 got EMAIL_ENABLED"
grep -q '^GOOGLE_CLIENT_ID=gid$' "$SUB20_LOG" && ok "SUB20 got GOOGLE_CLIENT_ID" || bad "SUB20 got GOOGLE_CLIENT_ID"

# 2. SUB23 gets app-server params, including the resolved anon key + ollie env
grep -q '^APP_NAME=popbys$' "$SUB23_LOG" && ok "SUB23 got APP_NAME" || bad "SUB23 got APP_NAME"
grep -q '^APP_PORT=8130$' "$SUB23_LOG" && ok "SUB23 got APP_PORT" || bad "SUB23 got APP_PORT"
grep -q '^APP_ENV_SUPABASE_URL=https://sb-popbys.test$' "$SUB23_LOG" && ok "SUB23 got SUPABASE_URL" || bad "SUB23 got SUPABASE_URL"
grep -q '^APP_ENV_SUPABASE_ANON_KEY=stub-anon$' "$SUB23_LOG" && ok "SUB23 got SUPABASE_ANON_KEY" || bad "SUB23 got SUPABASE_ANON_KEY"
grep -q '^APP_ENV_OLLIE_ENDPOINT=http://127.0.0.1:9123$' "$SUB23_LOG" && ok "SUB23 got OLLIE_ENDPOINT" || bad "SUB23 got OLLIE_ENDPOINT"
grep -q '^APP_ENV_OLLIE_AGENT=real-estate$' "$SUB23_LOG" && ok "SUB23 got OLLIE_AGENT" || bad "SUB23 got OLLIE_AGENT"
grep -q '^APP_ENV_OLLIE_ORCHESTRATOR_KEY=orch-key-1==$' "$SUB23_LOG" && ok "SUB23 got OLLIE_ORCHESTRATOR_KEY with = padding" || bad "SUB23 got OLLIE_ORCHESTRATOR_KEY with = padding"
grep -q "^IMAGE_TARBALL=$T/img.tar$" "$SUB23_LOG" && ok "SUB23 got IMAGE_TARBALL" || bad "SUB23 got IMAGE_TARBALL"

# 3. migration tracking: create-table + a SELECT per file + one
# single-transaction (-1 -f -) apply per file, with the tracker INSERT
# embedded in the SAME stdin as the migration SQL (not a separate -c call —
# see F2, a mid-file failure must roll back everything including the insert).
grep -q "create table if not exists public._app_migrations" "$DOCKER_LOG" && ok "migrations table ensured" || bad "migrations table ensured"
[ "$(grep -c "select 1 from public._app_migrations where name=" "$DOCKER_LOG")" = "2" ] && ok "one SELECT per fixture migration" || bad "one SELECT per fixture migration"
[ "$(grep -c -- ' -1 -f -$' "$DOCKER_LOG")" = "2" ] && ok "one single-transaction (-1) apply per fixture migration" || bad "one single-transaction (-1) apply per fixture migration"
[ "$(grep -c "insert into public._app_migrations" "$DOCKER_LOG")" = "0" ] && ok "INSERT is not a separate -c call" || bad "INSERT is not a separate -c call"
[ "$(grep -l "insert into public._app_migrations" "$APPLY_LOG_DIR"/apply-*.stdin 2>/dev/null | wc -l)" = "2" ] \
  && ok "INSERT embedded in the same stdin as each migration apply" \
  || bad "INSERT embedded in the same stdin as each migration apply"
grep -q "select 1;" "$APPLY_LOG_DIR/apply-1.stdin" 2>/dev/null && ok "first apply's stdin carries its migration SQL" || bad "first apply's stdin carries its migration SQL"
grep -q "insert into public._app_migrations (name) values ('0001_init.sql')" "$APPLY_LOG_DIR/apply-1.stdin" 2>/dev/null \
  && ok "first apply's stdin carries its tracker insert" || bad "first apply's stdin carries its tracker insert"
grep -q "select 2;" "$APPLY_LOG_DIR/apply-2.stdin" 2>/dev/null && ok "second apply's stdin carries its migration SQL" || bad "second apply's stdin carries its migration SQL"
grep -q "insert into public._app_migrations (name) values ('0002_second.sql')" "$APPLY_LOG_DIR/apply-2.stdin" 2>/dev/null \
  && ok "second apply's stdin carries its tracker insert" || bad "second apply's stdin carries its tracker insert"

# 4. re-run: both migrations already applied -> no -f applies this time
echo "0001_init.sql" >> "$MIGSTATE_FILE"
echo "0002_second.sql" >> "$MIGSTATE_FILE"
: > "$DOCKER_LOG"; : > "$SUB20_LOG"; : > "$SUB23_LOG"
rm -rf "$APPLY_LOG_DIR"; mkdir -p "$APPLY_LOG_DIR"; rm -f "$APPLY_COUNT_FILE"
run "real-estate" "${STDIN[@]}" && ok "re-run exits 0" || bad "re-run exits 0"
[ "$(grep -c -- ' -1 -f -$' "$DOCKER_LOG")" = "0" ] && ok "re-run applies no migrations" || bad "re-run applies no migrations"
[ "$(grep -c "select 1 from public._app_migrations where name=" "$DOCKER_LOG")" = "2" ] && ok "re-run still checks both migrations" || bad "re-run still checks both migrations"

# 5. prints the root caddy command with BOTH vhosts and the full-set warning
# every script in this repo is committed mode 644, so the printed command must
# invoke it via `bash` — direct execution would 403/Permission-denied on a
# fresh clone.
grep -qE "sudo bash [^ ]*22-install-caddy-vhosts\.sh" "$T/out.log" && ok "prints copy-paste runnable caddy command (sudo bash)" || bad "prints copy-paste runnable caddy command (sudo bash)"
grep -q "popbys.test:8130" "$T/out.log" && ok "caddy command has app vhost" || bad "caddy command has app vhost"
grep -q "sb-popbys.test:8030" "$T/out.log" && ok "caddy command has supabase vhost" || bad "caddy command has supabase vhost"
grep -q "EVERY vhost this box serves" "$T/out.log" && ok "warns to pass the FULL vhost set" || bad "warns to pass the FULL vhost set"

# 5b. multi-image tarball -> exit 1 before any docker create/cp (F4: apply
# the same single-image guard 23 uses, so migrations aren't extracted from
# an arbitrary image before a later multi-image rejection).
: > "$T/multi.tar"
: > "$DOCKER_LOG"; : > "$SUB20_LOG"; : > "$SUB23_LOG"
rm -rf "$APPLY_LOG_DIR"; mkdir -p "$APPLY_LOG_DIR"; rm -f "$APPLY_COUNT_FILE"
STDIN_MULTI=(
  "APP_HOST=popbys.test"
  "SB_HOST=sb-popbys.test"
  "IMAGE_TARBALL=$T/multi.tar"
  "ORCH_ENV_FILE=$T/hermes-stack/.env"
)
run "real-estate" "${STDIN_MULTI[@]}" && bad "multi-image tarball refused" || ok "multi-image tarball refused"
grep -q "^error:.*exactly one image" "$T/out.log" && ok "multi-image error message" || bad "multi-image error message"
grep -q "docker create" "$DOCKER_LOG" && bad "no docker create before multi-image rejection" || ok "no docker create before multi-image rejection"
grep -q "docker cp" "$DOCKER_LOG" && bad "no docker cp before multi-image rejection" || ok "no docker cp before multi-image rejection"

# 6. unknown profile -> exit 1
run "no-such-profile" "${STDIN[@]}" && bad "unknown profile refused" || ok "unknown profile refused"

# 6b. multi-app manifest -> fail loud (F3: APP_HOST/SB_HOST/IMAGE_TARBALL are
# single-app fields; a manifest with >1 app needs per-app host fields added
# to the schema before 24 can drive it, so refuse instead of silently
# clobbering one app's config with another's).
cat > "$MANIFEST_DIR/multi-app.json" <<'JSON'
{
  "profile": "multi-app",
  "apps": [
    {
      "name": "appone",
      "stack": { "kong_port": 8040, "email_enabled": "false" },
      "server": { "app_port": 8140, "container_port": 8080, "health_path": "/api/health" }
    },
    {
      "name": "apptwo",
      "stack": { "kong_port": 8041, "email_enabled": "false" },
      "server": { "app_port": 8141, "container_port": 8080, "health_path": "/api/health" }
    }
  ]
}
JSON
: > "$DOCKER_LOG"; : > "$SUB20_LOG"; : > "$SUB23_LOG"
run "multi-app" "${STDIN[@]}" && bad "multi-app manifest refused" || ok "multi-app manifest refused"
grep -q "multi-app manifests are not yet supported" "$T/out.log" && ok "multi-app error message" || bad "multi-app error message"
[ -s "$SUB20_LOG" ] && bad "no SUB20 invocation for multi-app manifest" || ok "no SUB20 invocation for multi-app manifest"

# 7. carry-forward test: re-run without APP_HOST/SB_HOST, derive from stack .env
STDIN_CARRY=(
  "IMAGE_TARBALL=$T/img.tar"
  "GOOGLE_CLIENT_ID=gid"
  "ORCH_ENV_FILE=$T/hermes-stack/.env"
)
: > "$DOCKER_LOG"; : > "$SUB20_LOG"; : > "$SUB23_LOG"
rm -rf "$APPLY_LOG_DIR"; mkdir -p "$APPLY_LOG_DIR"; rm -f "$APPLY_COUNT_FILE"
run "real-estate" "${STDIN_CARRY[@]}" && ok "carry-forward run exits 0" || bad "carry-forward run exits 0"
grep -q '^SUPABASE_PUBLIC_URL=https://sb-popbys.test$' "$SUB20_LOG" && ok "SUB20 got derived SUPABASE_PUBLIC_URL" || bad "SUB20 got derived SUPABASE_PUBLIC_URL"
grep -q '^SITE_URL=https://popbys.test$' "$SUB20_LOG" && ok "SUB20 got derived SITE_URL" || bad "SUB20 got derived SITE_URL"
grep -q '^APP_ENV_SUPABASE_URL=https://sb-popbys.test$' "$SUB23_LOG" && ok "SUB23 got derived SUPABASE_URL from carry-forward" || bad "SUB23 got derived SUPABASE_URL from carry-forward"

echo; echo "${pass} passed, ${fail} failed"; [ "$fail" -eq 0 ]
