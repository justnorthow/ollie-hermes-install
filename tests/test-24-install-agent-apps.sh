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
  "agent": {
    "display_name": "Emma Ellis",
    "subtitle": "Real Estate Assistant",
    "color": "#0e7c86"
  },
  "apps": [
    {
      "name": "popbys",
      "stack": { "kong_port": 8030, "email_enabled": "false" },
      "server": { "app_port": 8130, "container_port": 8080, "health_path": "/api/health" },
      "tile": {
        "label": "Pop Bys",
        "icon": "M15 10.5a3 3 0 11-6 0 3 3 0 016 0z M19.5 10.5c0 7.142-7.5 11.25-7.5 11.25S4.5 17.642 4.5 10.5a7.5 7.5 0 1115 0z",
        "description": "Pop-by planning: contacts, cadence, routes, calendar",
        "order": 10
      }
    }
  ]
}
JSON

# ---- fixture stacks dir (SUB20 stub writes popbys/.env here) ----
export STACKS_DIR="$T/stacks"; mkdir -p "$STACKS_DIR"

# ---- fixture orchestrator env file (HIA_SSO_SECRET present: happy path) ----
mkdir -p "$T/hermes-stack"
cat > "$T/hermes-stack/.env" <<'EOF'
ORCHESTRATOR_KEY=orch-key-1==
HIA_SSO_SECRET=sso-secret-1
EOF

# ---- fixture orchestrator env file WITHOUT HIA_SSO_SECRET (warn-and-continue case) ----
mkdir -p "$T/hermes-stack-nosso"
cat > "$T/hermes-stack-nosso/.env" <<'EOF'
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
SERVICE_ROLE_KEY=stub-service-role
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

# ---- fake curl: logs full argv + the -d payload; CURL_FAIL_FILE (if present)
# simulates a total curl outage (fake curl exits nonzero on EVERY call, like a
# down/unreachable orchestrator). CURL_FAIL_URL_PATTERN (if present) is a
# narrower, URL-selective failure: only argv tokens matching the pattern fail
# — everything else behaves normally. This lets a test fail just the tile
# -registration POST without also tripping the preflight's GET/POST, which
# now runs earlier in the same invocation.
#
# 24 now also verifies agent creation with GET /v1/agents/<profile> (polled,
# since creation is async) and reads the http status via -o <file> -w
# '%{http_code}'. The fake curl models this:
#   - GET  .../v1/agents            -> writes AGENTS_JSON_FILE to -o (or
#                                       stdout if no -o), status 200 (or
#                                       AGENTS_LIST_STATUS_FILE's contents, for
#                                       the broken-orchestrator tests).
#   - POST .../v1/agents            -> "creates" the agent: records its name
#                                       in CREATED_AGENTS_FILE (so the verify
#                                       GET below finds it) UNLESS
#                                       AGENT_NEVER_APPEARS_FILE exists, which
#                                       simulates the real bug this branch
#                                       exists to catch (202 ACCEPTED, SSE
#                                       error body, agent never actually
#                                       created). Status 202.
#   - GET  .../v1/agents/<profile>  -> 200 if <profile> is in AGENTS_JSON_FILE
#                                       or CREATED_AGENTS_FILE, else 404.
#   - POST .../v1/agents/<id>/apps  -> tile registration, status 200. ----
export CURL_LOG="$T/curl.log"
export CURL_FAIL_FILE="$T/curl-fail"
export CURL_FAIL_URL_PATTERN=""
# ---- fixture agents list (drives the fake curl's GET /v1/agents and GET
# /v1/agents/<id> responses; the preflight in 24 reads this to decide whether
# PROFILE already exists) ----
export AGENTS_JSON_FILE="$T/agents.json"
printf '{"agents":[{"id":"default","displayName":"Ollie"}]}' > "$AGENTS_JSON_FILE"
export AGENTS_LIST_STATUS_FILE="$T/agents-list-status"
rm -f "$AGENTS_LIST_STATUS_FILE"
# ---- marker of agents "created" by a POST .../v1/agents in this test run
# (the fake orchestrator doesn't persist state into AGENTS_JSON_FILE, so this
# is what the verify GET checks after a create) ----
export CREATED_AGENTS_FILE="$T/created-agents"
: > "$CREATED_AGENTS_FILE"
# ---- when present, a POST .../v1/agents is accepted (202) but the agent it
# claims to create is NEVER recorded as created — models the orchestrator's
# real failure mode (202 ACCEPTED + SSE `event: error`, agent never exists) ----
export AGENT_NEVER_APPEARS_FILE="$T/agent-never-appears"
rm -f "$AGENT_NEVER_APPEARS_FILE"
cat > "$T/bin/curl" <<'SH'
#!/usr/bin/env bash
echo "curl $*" >> "${CURL_LOG}"

METHOD="GET"
URL=""
OUTFILE=""
WANT_CODE=""
DATA=""
prev=""
for a in "$@"; do
  if [[ "${prev}" == "-d" ]]; then
    DATA="$a"
    printf '%s' "$a" > "${CURL_LOG}.payload"
  fi
  [[ "${prev}" == "-X" ]] && METHOD="$a"
  [[ "${prev}" == "-o" ]] && OUTFILE="$a"
  case "$a" in
    http://*|https://*) URL="$a" ;;
    *%{http_code}*) WANT_CODE=1 ;;
  esac
  prev="$a"
done

write_out() { # BODY
  if [[ -n "${OUTFILE}" ]]; then printf '%s' "$1" > "${OUTFILE}"; else printf '%s' "$1"; fi
}
emit_status() { # STATUS
  [[ -n "${WANT_CODE}" ]] && printf '%s' "$1"
}

if [[ -f "${CURL_FAIL_FILE}" ]]; then
  echo "curl: fake failure" >&2
  emit_status "000"
  exit 22
fi
if [[ -n "${CURL_FAIL_URL_PATTERN:-}" && "${URL}" == *"${CURL_FAIL_URL_PATTERN}"* ]]; then
  echo "curl: fake failure (matched ${CURL_FAIL_URL_PATTERN})" >&2
  emit_status "000"
  exit 22
fi

case "${URL}" in
  */v1/agents)
    if [[ "${METHOD}" == "POST" ]]; then
      if [[ ! -f "${AGENT_NEVER_APPEARS_FILE:-/nonexistent}" ]]; then
        NAME_FROM_PAYLOAD="$(printf '%s' "${DATA}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('name',''))" 2>/dev/null || true)"
        [[ -n "${NAME_FROM_PAYLOAD}" ]] && echo "${NAME_FROM_PAYLOAD}" >> "${CREATED_AGENTS_FILE:-/dev/null}"
      fi
      write_out ""
      emit_status "202"
    else
      LIST_STATUS="200"
      [[ -f "${AGENTS_LIST_STATUS_FILE:-/nonexistent}" ]] && LIST_STATUS="$(cat "${AGENTS_LIST_STATUS_FILE}")"
      if [[ "${LIST_STATUS}" != "200" ]]; then
        write_out ""
        emit_status "${LIST_STATUS}"
      else
        write_out "$(cat "${AGENTS_JSON_FILE:-/dev/null}" 2>/dev/null || printf '{"agents":[]}')"
        emit_status "200"
      fi
    fi
    exit 0
    ;;
  */v1/agents/*/apps)
    write_out ""
    emit_status "200"
    exit 0
    ;;
  */v1/agents/*)
    LOOKUP="${URL##*/v1/agents/}"
    FOUND="$(python3 -c "
import json
try:
    d = json.load(open('${AGENTS_JSON_FILE}'))
except Exception:
    d = {}
if not isinstance(d, dict):
    d = {}
print('1' if any(a.get('id') == '${LOOKUP}' for a in (d.get('agents') or [])) else '')
" 2>/dev/null || true)"
    if [[ -z "${FOUND}" ]] && grep -qxF "${LOOKUP}" "${CREATED_AGENTS_FILE:-/dev/null}" 2>/dev/null; then
      FOUND=1
    fi
    if [[ -n "${FOUND}" ]]; then
      write_out '{}'
      emit_status "200"
    else
      write_out ""
      emit_status "404"
    fi
    exit 0
    ;;
esac
write_out ""
emit_status "200"
exit 0
SH
export CURL="$T/bin/curl"
chmod +x "$T/bin/curl"

# Keep the polling loop fast in tests: a few attempts, no sleep, instead of
# the real 10 attempts / 2s apart.
export AGENT_VERIFY_ATTEMPTS=3
export AGENT_VERIFY_INTERVAL=0

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
: > "$DOCKER_LOG"; : > "$SUB20_LOG"; : > "$SUB23_LOG"; : > "$CURL_LOG"
rm -f "$CURL_LOG.payload" "$CURL_FAIL_FILE"
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

# 2b. SUB23 gets the dashboard-SSO env: HIA_SSO_SECRET (from the orchestrator
# env file), SUPABASE_SERVICE_ROLE_KEY (from the stack .env SUB20 rendered),
# and APP_BASE_PATH (derived from the app name).
grep -q '^APP_ENV_HIA_SSO_SECRET=sso-secret-1$' "$SUB23_LOG" && ok "SUB23 got HIA_SSO_SECRET" || bad "SUB23 got HIA_SSO_SECRET"
grep -q '^APP_ENV_SUPABASE_SERVICE_ROLE_KEY=stub-service-role$' "$SUB23_LOG" && ok "SUB23 got SUPABASE_SERVICE_ROLE_KEY" || bad "SUB23 got SUPABASE_SERVICE_ROLE_KEY"
grep -q '^APP_ENV_APP_BASE_PATH=/apps/popbys$' "$SUB23_LOG" && ok "SUB23 got APP_BASE_PATH" || bad "SUB23 got APP_BASE_PATH"

# 2c. dashboard tile registration: manifest app has a "tile" key -> 24 POSTs
# the upsert payload to the orchestrator's app-registry endpoint.
grep -q "curl -fsS -X POST http://127.0.0.1:9123/v1/agents/real-estate/apps" "$CURL_LOG" \
  && ok "tile registration POST hit the registry endpoint" || bad "tile registration POST hit the registry endpoint"
grep -q "Authorization: Bearer orch-key-1==" "$CURL_LOG" && ok "tile registration POST carries the bearer" || bad "tile registration POST carries the bearer"
# python3 -c embeds the path in the source string, not as an argv token, so on
# MSYS bash + a native Windows python3.exe it needs the drive-letter form (see
# the MANIFEST_DIR/TW note above) — harmless no-op on real POSIX boxes.
PAYLOAD_FILE_NATIVE="$(cygpath -m "$CURL_LOG.payload" 2>/dev/null || printf '%s' "$CURL_LOG.payload")"
if [ -f "$CURL_LOG.payload" ] && python3 -c "
import json
d = json.load(open('$PAYLOAD_FILE_NATIVE'))
assert d['id'] == 'popbys', d
assert d['label'] == 'Pop Bys', d
assert d['description'] == 'Pop-by planning: contacts, cadence, routes, calendar', d
assert d['order'] == 10, d
assert d['componentType'] == 'ExternalWebApp', d
assert d['config']['url'] == '/apps/popbys/', d
assert d['config']['sso'] is True, d
" 2>"$T/payload-check.err"; then
  ok "tile registration payload shape correct"
else
  bad "tile registration payload shape correct"; cat "$T/payload-check.err" >&2
fi

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

# 5c. tile-bearing app (popbys has a "tile" key) -> also prints the bridge
# sudo command, right after the caddy line, so the dashboard container can
# reach the loopback-only app server.
grep -qE "sudo bash [^ ]*25-install-app-bridge\.sh popbys:8130" "$T/out.log" \
  && ok "prints copy-paste runnable bridge command (sudo bash) for tile app" \
  || bad "prints copy-paste runnable bridge command (sudo bash) for tile app"

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

# 8. missing HIA_SSO_SECRET (orchestrator env file has no key at all) -> WARN
# on stderr but the install still completes (SSO 503s gracefully; the rollout
# runbook is what actually creates the secret).
STDIN_NOSSO=(
  "APP_HOST=popbys.test"
  "SB_HOST=sb-popbys.test"
  "IMAGE_TARBALL=$T/img.tar"
  "ORCH_ENV_FILE=$T/hermes-stack-nosso/.env"
)
: > "$DOCKER_LOG"; : > "$SUB20_LOG"; : > "$SUB23_LOG"; : > "$CURL_LOG"
rm -f "$CURL_LOG.payload" "$CURL_FAIL_FILE"
rm -rf "$APPLY_LOG_DIR"; mkdir -p "$APPLY_LOG_DIR"; rm -f "$APPLY_COUNT_FILE"
run "real-estate" "${STDIN_NOSSO[@]}" && ok "missing HIA_SSO_SECRET still exits 0" || bad "missing HIA_SSO_SECRET still exits 0"
grep -q "WARN:.*HIA_SSO_SECRET" "$T/out.log" && ok "missing HIA_SSO_SECRET warns" || bad "missing HIA_SSO_SECRET warns"
grep -q '^APP_ENV_HIA_SSO_SECRET=' "$SUB23_LOG" && bad "no HIA_SSO_SECRET line when absent" || ok "no HIA_SSO_SECRET line when absent"
grep -q '^APP_ENV_SUPABASE_SERVICE_ROLE_KEY=stub-service-role$' "$SUB23_LOG" && ok "SERVICE_ROLE_KEY still passed without SSO secret" || bad "SERVICE_ROLE_KEY still passed without SSO secret"

# 9. missing SERVICE_ROLE_KEY in the stack .env -> fail loud (20 always
# renders it; its absence means the stack render never ran).
export SUB20_NOSRK_LOG="$T/sub20-nosrk.log"
cat > "$T/bin/sub20-nosrk.sh" <<'SH'
#!/usr/bin/env bash
set -eu
cat > "${SUB20_NOSRK_LOG}"
mkdir -p "${STACKS_DIR}/popbys"
cat > "${STACKS_DIR}/popbys/.env" <<ENVEOF
ANON_KEY=stub-anon
POSTGRES_PASSWORD=pw
SUPABASE_PUBLIC_URL=https://sb-popbys.test
SITE_URL=https://popbys.test
ENVEOF
SH
chmod +x "$T/bin/sub20-nosrk.sh"
: > "$DOCKER_LOG"; : > "$SUB23_LOG"; : > "$CURL_LOG"
rm -f "$CURL_LOG.payload" "$CURL_FAIL_FILE"
rm -rf "$APPLY_LOG_DIR"; mkdir -p "$APPLY_LOG_DIR"; rm -f "$APPLY_COUNT_FILE"
SUB20="$T/bin/sub20-nosrk.sh" run "real-estate" "${STDIN[@]}" && bad "missing SERVICE_ROLE_KEY refused" || ok "missing SERVICE_ROLE_KEY refused"
grep -q "^error:.*SERVICE_ROLE_KEY" "$T/out.log" && ok "missing SERVICE_ROLE_KEY error message" || bad "missing SERVICE_ROLE_KEY error message"
[ -s "$SUB23_LOG" ] && bad "no SUB23 invocation when SERVICE_ROLE_KEY missing" || ok "no SUB23 invocation when SERVICE_ROLE_KEY missing"

# 10. total orchestrator-API outage -> exit 1. Note: since the preflight
# (added for the auto-create-agent feature) is now the FIRST curl call 24
# makes, a total curl outage is now caught THERE — before any stack/app work
# — rather than at the later tile-registration POST. IMPORTANT 2 tightened
# this further: the preflight's GET /v1/agents no longer swallows a failed
# call as "agent absent" (that used to defer the failure to the create POST's
# "could not create agent" message) — it now checks the HTTP status itself
# and fails immediately with a message that correctly blames the orchestrator
# list call, not agent creation.
: > "$DOCKER_LOG"; : > "$SUB20_LOG"; : > "$SUB23_LOG"; : > "$CURL_LOG"
rm -f "$CURL_LOG.payload"; : > "$CURL_FAIL_FILE"
rm -rf "$APPLY_LOG_DIR"; mkdir -p "$APPLY_LOG_DIR"; rm -f "$APPLY_COUNT_FILE"
run "real-estate" "${STDIN[@]}" && bad "registry POST failure refused" || ok "registry POST failure refused"
grep -q "error: could not list agents from the orchestrator" "$T/out.log" && ok "registry POST failure error message (caught by the preflight's own GET, before agent creation)" || bad "registry POST failure error message (caught by the preflight's own GET, before agent creation)"
rm -f "$CURL_FAIL_FILE"

# 11. preflight: the agent named after the profile must exist before any
# install work runs, else the tile-registration POST 404s at the very end of
# a multi-minute install. 24 now GETs /v1/agents first and auto-creates from
# the manifest's "agent" block (authMethod=inherit — no secrets invented).

# Agent absent -> 24 creates it from the manifest block, with authMethod=inherit.
: > "$CURL_LOG"; printf '{"agents":[{"id":"default","displayName":"Ollie"}]}' > "$AGENTS_JSON_FILE"
run real-estate "${STDIN[@]}"
grep -q "curl .*-X POST http://127.0.0.1:9123/v1/agents " "$CURL_LOG" \
  && ok "preflight POSTs /v1/agents when the agent is missing" \
  || bad "preflight did not create the missing agent"
grep -q '"authMethod": *"inherit"' "$CURL_LOG" \
  && ok "agent created with authMethod=inherit" \
  || bad "agent payload missing authMethod=inherit"
grep -q '"name": *"real-estate"' "$CURL_LOG" \
  && ok "agent id == profile" || bad "agent name is not the profile id"

# Agent already present -> never touched.
: > "$CURL_LOG"
printf '{"agents":[{"id":"real-estate","displayName":"Renamed By Customer"}]}' > "$AGENTS_JSON_FILE"
run real-estate "${STDIN[@]}"
grep -q "curl .*-X POST http://127.0.0.1:9123/v1/agents " "$CURL_LOG" \
  && bad "existing agent was modified (must be idempotent)" \
  || ok "existing agent left untouched"

# Manifest with no agent block + agent absent -> fatal, with the documented message.
: > "$CURL_LOG"; printf '{"agents":[{"id":"default"}]}' > "$AGENTS_JSON_FILE"
python3 - "$MANIFEST_DIR/no-agent.json" <<'PY'
import json, sys
json.dump({"profile": "no-agent", "apps": [{"name": "x",
  "stack": {"kong_port": 8031, "email_enabled": "false"},
  "server": {"app_port": 8131, "container_port": 8080, "health_path": "/api/health"}}]},
  open(sys.argv[1], "w"))
PY
run no-agent "${STDIN[@]}"
grep -q "create it in Fleet's Agents tab first" "$T/out.log" \
  && ok "missing agent + no manifest defaults fails with guidance" \
  || bad "expected the documented no-agent error message"

# 12. tile-registration POST failure, in isolation from the preflight: the
# agent already exists (preflight no-ops, no POST at all -> nothing for a
# blanket CURL_FAIL_FILE to catch early), and CURL_FAIL_URL_PATTERN fails
# only the tile endpoint. This restores coverage for
# scripts/24-install-agent-apps.sh's "dashboard tile registration failed"
# error path, which a blanket curl outage can no longer reach now that the
# preflight's own GET/POST runs first (see test 10 above).
: > "$DOCKER_LOG"; : > "$SUB20_LOG"; : > "$SUB23_LOG"; : > "$CURL_LOG"
rm -f "$CURL_LOG.payload"
printf '{"agents":[{"id":"real-estate","displayName":"Emma Ellis"}]}' > "$AGENTS_JSON_FILE"
rm -rf "$APPLY_LOG_DIR"; mkdir -p "$APPLY_LOG_DIR"; rm -f "$APPLY_COUNT_FILE"
export CURL_FAIL_URL_PATTERN="/v1/agents/real-estate/apps"
run "real-estate" "${STDIN[@]}" && bad "tile registration POST failure refused" || ok "tile registration POST failure refused"
grep -q "error: dashboard tile registration failed" "$T/out.log" \
  && ok "tile registration POST failure error message" \
  || bad "tile registration POST failure error message"
export CURL_FAIL_URL_PATTERN=""

# 13. A tile app must get <NAME>_BASE_URL written into the STACK env (not the
# orchestrator env), pointing at host.docker.internal:<app_port>. STACK_ENV_FILE
# and ORCH_ENV_FILE are DELIBERATELY DIFFERENT paths in this test — a
# regression that swapped the two variables would be invisible if both pointed
# at the same file. The stack dir needs its own docker-compose.yml fixture
# (24's pre-check skips the whole block otherwise — see test 14).
: > "$CURL_LOG"
printf '{"agents":[{"id":"real-estate"}]}' > "$AGENTS_JSON_FILE"
cat > "$T/hermes-stack/.env" <<'EOF'
ORCHESTRATOR_KEY=orch-key-1==
HIA_SSO_SECRET=sso-secret-1
EOF
mkdir -p "$T/stack-env"
cat > "$T/stack-env/docker-compose.yml" <<'EOF'
services:
  dashboard:
    environment:
      POPBYS_BASE_URL: ${POPBYS_BASE_URL}
EOF
cat > "$T/stack-env/.env" <<'EOF'
POPBYS_BASE_URL=
EOF
run real-estate "${STDIN[@]}" "STACK_ENV_FILE=$T/stack-env/.env"
grep -q '^POPBYS_BASE_URL=http://host.docker.internal:8130$' "$T/stack-env/.env" \
  && ok "POPBYS_BASE_URL written to the STACK env" \
  || bad "POPBYS_BASE_URL not set in the STACK env"
grep -q '^POPBYS_BASE_URL=' "$T/hermes-stack/.env" \
  && bad "POPBYS_BASE_URL leaked into the ORCHESTRATOR env (STACK_ENV_FILE/ORCH_ENV_FILE must stay separate)" \
  || ok "POPBYS_BASE_URL absent from the ORCHESTRATOR env (STACK_ENV_FILE/ORCH_ENV_FILE stay separate)"
grep -q "^✓ agent-apps for profile 'real-estate' installed" "$T/out.log" \
  && ok "zero-warning run prints the ✓ banner" \
  || bad "zero-warning run should print the ✓ banner"

# 14. skip path: STACK_ENV_FILE points somewhere with no docker-compose.yml —
# i.e. the Hermes stack was never installed there (06-install-stack.sh creates
# it). 24 must warn with the SPECIFIC cause and skip, never fabricating the
# directory or writing an orphan .env that nothing reads.
: > "$CURL_LOG"
printf '{"agents":[{"id":"real-estate"}]}' > "$AGENTS_JSON_FILE"
NO_STACK_DIR="$T/no-such-stack"
rm -rf "$NO_STACK_DIR"
run real-estate "${STDIN[@]}" "STACK_ENV_FILE=$NO_STACK_DIR/.env"
grep -q "WARNING: no docker-compose.yml at .*no-such-stack" "$T/out.log" \
  && ok "warns with the specific missing-stack cause" \
  || bad "did not warn about the missing docker-compose.yml"
grep -q "Skipping POPBYS_BASE_URL update" "$T/out.log" \
  && ok "warning names the skipped key" \
  || bad "warning does not name the skipped key"
[ -e "$NO_STACK_DIR" ] \
  && bad "fabricated the missing stack directory/.env instead of skipping" \
  || ok "did not fabricate the missing stack directory/.env"
grep -q "^⚠ agent-apps for profile 'real-estate' installed with 1 warning" "$T/out.log" \
  && ok "warn-path run prints the ⚠ banner (not ✓)" \
  || bad "warn-path run should print the ⚠ banner"
grep -q "^✓ agent-apps" "$T/out.log" \
  && bad "warn-path run must NOT also print the ✓ banner" \
  || ok "warn-path run does not print the ✓ banner"

# 15. CRITICAL: compose file exists but does NOT reference the app's
# <NAME>_BASE_URL key at all — the box predates the 2026-07-23 passthrough
# (or was never wired for it). 24 must NOT write the key or recreate the
# dashboard (both would be no-ops / worse than doing nothing), must warn with
# specific remediation, and must NOT print the ✓ banner.
: > "$CURL_LOG"; : > "$DOCKER_LOG"
printf '{"agents":[{"id":"real-estate"}]}' > "$AGENTS_JSON_FILE"
mkdir -p "$T/stack-env-nopassthrough"
cat > "$T/stack-env-nopassthrough/docker-compose.yml" <<'EOF'
services:
  dashboard:
    environment:
      SOME_OTHER_VAR: fixed-value
EOF
cat > "$T/stack-env-nopassthrough/.env" <<'EOF'
SOME_OTHER_VAR=fixed-value
EOF
run real-estate "${STDIN[@]}" "STACK_ENV_FILE=$T/stack-env-nopassthrough/.env"
grep -q "WARNING:.*stack-env-nopassthrough.*docker-compose\.yml does not pass POPBYS_BASE_URL to the dashboard" "$T/out.log" \
  && ok "warns when compose file doesn't pass BASE_KEY to the dashboard" \
  || bad "did not warn about the missing BASE_KEY passthrough in compose"
grep -q "Re-run 06-install-stack.sh" "$T/out.log" \
  && ok "warning gives specific remediation (re-run 06)" \
  || bad "warning missing remediation guidance"
grep -q '^POPBYS_BASE_URL=' "$T/stack-env-nopassthrough/.env" \
  && bad "wrote POPBYS_BASE_URL even though compose doesn't reference it (silent no-op)" \
  || ok "did not write POPBYS_BASE_URL when compose doesn't reference it"
grep -q "up -d dashboard" "$DOCKER_LOG" \
  && bad "attempted to recreate the dashboard despite skipping the BASE_URL write" \
  || ok "did not attempt to recreate the dashboard when the write was skipped"
grep -q "^⚠ agent-apps for profile 'real-estate' installed with 1 warning" "$T/out.log" \
  && ok "missing-passthrough run prints the ⚠ banner" \
  || bad "missing-passthrough run should print the ⚠ banner"
grep -q "^✓ agent-apps" "$T/out.log" \
  && bad "missing-passthrough run must not print the ✓ banner" \
  || ok "missing-passthrough run correctly suppresses the ✓ banner"

# 16. MINOR: compose file DOES reference the BASE_KEY, but the stack .env
# itself is missing (partial/broken install) — 24 must not create an orphan
# one-line .env and must not attempt the recreate; must warn with the
# specific cause.
: > "$CURL_LOG"; : > "$DOCKER_LOG"
printf '{"agents":[{"id":"real-estate"}]}' > "$AGENTS_JSON_FILE"
mkdir -p "$T/stack-env-noenv"
cat > "$T/stack-env-noenv/docker-compose.yml" <<'EOF'
services:
  dashboard:
    environment:
      POPBYS_BASE_URL: ${POPBYS_BASE_URL}
EOF
rm -f "$T/stack-env-noenv/.env"
run real-estate "${STDIN[@]}" "STACK_ENV_FILE=$T/stack-env-noenv/.env"
grep -q "WARNING: no .*stack-env-noenv/\.env" "$T/out.log" \
  && ok "warns when docker-compose.yml exists but .env does not" \
  || bad "did not warn about the missing stack .env"
[ -e "$T/stack-env-noenv/.env" ] \
  && bad "fabricated an orphan .env instead of warning and skipping" \
  || ok "did not fabricate an orphan .env"
grep -q "^⚠ agent-apps" "$T/out.log" \
  && ok "missing-.env run prints the ⚠ banner" \
  || bad "missing-.env run should print the ⚠ banner"

# 17. CRITICAL: agent-create "succeeds" (the POST exits 0 / 202 ACCEPTED) but
# the orchestrator never actually creates the agent — the SSE error-body
# failure mode this branch exists to catch. The verify GET must keep 404ing,
# the run must FAIL with the documented message, and the misleading
# "created" success line must NEVER be printed.
: > "$CURL_LOG"; : > "$DOCKER_LOG"; : > "$SUB20_LOG"; : > "$SUB23_LOG"
printf '{"agents":[{"id":"default"}]}' > "$AGENTS_JSON_FILE"   # profile absent
: > "$CREATED_AGENTS_FILE"                                      # clear any stale marker
: > "$AGENT_NEVER_APPEARS_FILE"                                 # POST accepted, agent never appears
run real-estate "${STDIN[@]}" && bad "undetected creation failure refused" || ok "undetected creation failure refused"
grep -q "error: agent 'real-estate' was not created (the orchestrator accepted the request but the agent does not exist" "$T/out.log" \
  && ok "undetected creation failure prints the documented message" \
  || bad "missing the documented undetected-creation-failure message"
grep -q "created from manifest defaults" "$T/out.log" \
  && bad "printed the misleading 'created' success line despite the agent never existing" \
  || ok "did not print the 'created' line when verification never passed"
[ -s "$SUB20_LOG" ] \
  && bad "install work (SUB20) ran despite the agent never being verified" \
  || ok "no install work ran before the undetected creation failure was caught"
rm -f "$AGENT_NEVER_APPEARS_FILE"

echo; echo "${pass} passed, ${fail} failed"; [ "$fail" -eq 0 ]
