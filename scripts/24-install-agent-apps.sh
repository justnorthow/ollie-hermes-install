#!/usr/bin/env bash
# 24-install-agent-apps.sh <profile> — install every app the manifest
# (apps/<profile>.json) bundles with an agent profile: 26 (app schema + owner
# role) -> app migrations (extracted from the app image; applied into the
# core database as the app's owner role, tracked in <name>._migrations) ->
# 23 (app server) -> dashboard tile registration (manifest apps with a "tile"
# key are upserted into the orchestrator's per-profile app registry). Caddy
# (22) needs root, so this prints the exact command —
# REMINDER: 22 renders from ONLY its args; pass the box's FULL vhost set.
# Box-derived config is resolved here (core anon key, orchestrator loopback);
# operator secrets arrive on stdin and flow through, never argv.
# Input (stdin): APP_HOST, SB_HOST (both req first run — SB_HOST is read and
#   still enforced below even though the app's OWN Supabase identity now
#   comes from the core stack, not a per-app one; retiring this requirement
#   is a later task's scope, not this one's), IMAGE_TARBALL (req first
#   run), GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, ORCH_ENV_FILE, ORCH_PORT,
#   STACK_ENV_FILE, APP_ENV_<KEY>... passthrough.
# STACK_ENV_FILE (default ${HOME}/hermes-stack/.env) is the dashboard's OWN
# stack env — distinct from ORCH_ENV_FILE, which may point elsewhere (e.g.
# ~/.config/ollie-orchestrator/.env). Tile apps get <NAME>_BASE_URL written
# here so generate-nginx.sh proxies /apps/<name>/ instead of rendering blank.
# ORCH_ENV_FILE also supplies ORCHESTRATOR_KEY (used both as
# APP_ENV_OLLIE_ORCHESTRATOR_KEY and as the bearer for the tile-registry POST).
# The app's Supabase identity comes entirely from the CORE stack: its public
# URL and ANON_KEY (from CORE_STACK_DIR/.env), and its runtime key — a JWT
# claiming role=<name>_owner, minted by 26 into CORE_STACK_DIR/app-keys/<name>.jwt
# — passed through as APP_ENV_SUPABASE_APP_KEY. This REPLACES service_role for
# the app; core's SERVICE_ROLE_KEY must never reach an app container, so it is
# never read here.
set -euo pipefail
if [[ "$(id -u)" -eq 0 ]]; then
  echo "error: run as the service user, not root" >&2; exit 1
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/lib/supabase-app-env.sh"
. "${SCRIPT_DIR}/lib/app-server-env.sh"
. "${SCRIPT_DIR}/lib/app-migrations.sh"
PROFILE="${1:-}"
MANIFEST="${MANIFEST_DIR:-${SCRIPT_DIR}/../apps}/${PROFILE}.json"
[[ -n "${PROFILE}" && -f "${MANIFEST}" ]] || { echo "error: no manifest for profile '${PROFILE}'" >&2; exit 1; }
SUB20="${SUB20:-${SCRIPT_DIR}/20-install-app-stack.sh}"
SUB23="${SUB23:-${SCRIPT_DIR}/23-install-app-server.sh}"
SUB26="${SUB26:-${SCRIPT_DIR}/26-provision-app-schema.sh}"
CORE_DIR="${CORE_STACK_DIR:-$HOME/supabase-stack}"
STACKS="${STACKS_DIR:-$HOME/stacks}"
# The CORE stack's kong port is fixed (compose publishes 127.0.0.1:8000) and is
# the only Supabase a consolidated app talks to. Kept as one constant so the
# value written to APP_ENV_SUPABASE_INTERNAL_URL and the value the bridge probe
# checks can never drift apart — they did, and the probe spent that time
# reporting a failure for a per-app kong the app never used.
CORE_KONG_PORT=8000

APP_HOST="" ; SB_HOST="" ; IMAGE_TARBALL="" ; GOOGLE_CLIENT_ID="" ; GOOGLE_CLIENT_SECRET=""
ORCH_ENV_FILE="" ; ORCH_PORT="" ; STACK_ENV_FILE=""
declare -a PASSTHRU=()
while IFS='=' read -r k v || [[ -n "${k:-}" ]]; do
  case "${k}" in
    APP_HOST) APP_HOST="${v}" ;;
    SB_HOST) SB_HOST="${v}" ;;
    IMAGE_TARBALL) IMAGE_TARBALL="${v}" ;;
    GOOGLE_CLIENT_ID) GOOGLE_CLIENT_ID="${v}" ;;
    GOOGLE_CLIENT_SECRET) GOOGLE_CLIENT_SECRET="${v}" ;;
    ORCH_ENV_FILE) ORCH_ENV_FILE="${v}" ;;
    ORCH_PORT) ORCH_PORT="${v}" ;;
    STACK_ENV_FILE) STACK_ENV_FILE="${v}" ;;
    APP_ENV_*) PASSTHRU+=("${k}=${v}") ;;
  esac
done
ORCH_ENV_FILE="${ORCH_ENV_FILE:-$HOME/hermes-stack/.env}"
ORCH_PORT="${ORCH_PORT:-9123}"
STACK_ENV_FILE="${STACK_ENV_FILE:-$HOME/hermes-stack/.env}"

mf() { # JQPATH — read a manifest value
  python3 -c "import json,sys; d=json.load(open('${MANIFEST}')); print(eval('d'+sys.argv[1]))" "$1"
}
APP_COUNT="$(mf "['apps'].__len__()")"
# Every app name is used three ways with three different character rules:
#   26-provision-app-schema.sh  ^[a-z][a-z0-9_]*$   Postgres identifier, no hyphens
#   23-install-app-server.sh    ^[a-z][a-z0-9-]*$   compose project, no underscores
#   25-install-app-bridge.sh    ^[a-z][a-z0-9-]*$   systemd unit, no underscores
# So a name with an underscore breaks the bridge and a name with a hyphen
# breaks the schema. Enforce the intersection here, before any install work,
# rather than half-installing and failing at whichever script runs first.
for i in $(seq 0 $((APP_COUNT-1))); do
  _n="$(mf "['apps'][${i}]['name']")"
  if [[ ! "${_n}" =~ ^[a-z][a-z0-9]*$ ]]; then
    echo "error: manifest app name '${_n}' is invalid — must match ^[a-z][a-z0-9]*\$ (the intersection of the Postgres identifier rule used by 26 and the systemd/compose unit rule used by 23 and 25)" >&2
    exit 1
  fi
done
unset _n
if [[ "${APP_COUNT}" -gt 1 ]]; then
  echo "error: multi-app manifests are not yet supported (APP_HOST/SB_HOST/IMAGE_TARBALL are single-app; add per-app host fields to the manifest schema first)" >&2
  exit 1
fi

ORCH_KEY="$(grep -E '^ORCHESTRATOR_KEY=' "${ORCH_ENV_FILE}" | tail -n1 | cut -d= -f2- || true)"
[[ -n "${ORCH_KEY}" ]] || {
  echo "error: no ORCHESTRATOR_KEY in ${ORCH_ENV_FILE} — pass ORCH_ENV_FILE=<path> (on many boxes the orchestrator reads ~/.config/ollie-orchestrator/.env, not ~/hermes-stack/.env)" >&2
  exit 1
}

# WARNINGS counts every non-fatal WARNING emitted below (an unreachable kong
# bridge probe, a BASE_URL skip/no-op, a failed dashboard recreate, ...). A non-zero count
# suppresses the final ✓ banner (see the end of this script) — the run still
# exits 0, but the operator gets an unmissable ⚠ instead of a false-positive
# success line.
WARNINGS=0

# Preflight: the orchestrator 404s the dashboard-tile POST (stage 4/5, below)
# if no agent with id == PROFILE exists yet — on a real box that kills the
# run after the Supabase stack and app server are already built. Confirm (or
# create) the agent FIRST so a missing agent fails before any install work.
echo "==> agent-apps: preflight — agent '${PROFILE}' must exist"
AGENTS_BODY="$(mktemp)"
AGENTS_STATUS="$(curl -sS -o "${AGENTS_BODY}" -w '%{http_code}' \
  -H "Authorization: Bearer ${ORCH_KEY}" \
  "http://127.0.0.1:${ORCH_PORT}/v1/agents")" || true
if [[ "${AGENTS_STATUS}" != "200" ]]; then
  # A 401/500/connection-refused must NOT collapse into "agent absent" — that
  # would misreport a broken orchestrator as a missing-agent condition and
  # send the operator chasing the wrong fix.
  echo "error: could not list agents from the orchestrator (http ${AGENTS_STATUS:-000}) — check ORCH_PORT/ORCH_ENV_FILE and that the orchestrator is reachable" >&2
  rm -f "${AGENTS_BODY}"
  exit 1
fi
AGENTS_JSON="$(cat "${AGENTS_BODY}")"
rm -f "${AGENTS_BODY}"
AGENT_PRESENT="$(printf '%s' "${AGENTS_JSON}" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
if not isinstance(d, dict):
    d = {}
print('1' if any(a.get('id') == '${PROFILE}' for a in (d.get('agents') or [])) else '')
")"
if [[ -z "${AGENT_PRESENT}" ]]; then
  HAS_AGENT_BLOCK="$(python3 -c "
import json
d = json.load(open('${MANIFEST}'))
print('1' if (d.get('agent') or {}) else '')
")"
  if [[ -z "${HAS_AGENT_BLOCK}" ]]; then
    echo "error: no agent '${PROFILE}' on this box and the manifest declares no agent defaults — create it in Fleet's Agents tab first" >&2
    exit 1
  fi
  AGENT_PAYLOAD="$(python3 -c "
import json
d = json.load(open('${MANIFEST}'))
a = d.get('agent') or {}
payload = {'name': d['profile'], 'authMethod': 'inherit'}
if a.get('display_name'): payload['displayName'] = a['display_name']
if a.get('subtitle'):     payload['subtitle']    = a['subtitle']
if a.get('color'):        payload['color']       = a['color']
print(json.dumps(payload))
")"
  curl -fsS -X POST "http://127.0.0.1:${ORCH_PORT}/v1/agents" \
    -H "Authorization: Bearer ${ORCH_KEY}" \
    -H 'Content-Type: application/json' \
    -d "${AGENT_PAYLOAD}" >/dev/null \
    || { echo "error: could not create agent '${PROFILE}'" >&2; exit 1; }
  # The create endpoint returns 202 ACCEPTED with a streaming (SSE) body —
  # creation failures show up as an `event: error` INSIDE that stream, not as
  # an HTTP error status, so the POST exiting 0 proves nothing. Creation is
  # asynchronous, so poll GET /v1/agents/<profile> (404 until it really
  # exists) with a short bounded retry before trusting it.
  AGENT_VERIFY_ATTEMPTS="${AGENT_VERIFY_ATTEMPTS:-10}"
  AGENT_VERIFY_INTERVAL="${AGENT_VERIFY_INTERVAL:-2}"
  AGENT_VERIFIED=""
  for _ in $(seq 1 "${AGENT_VERIFY_ATTEMPTS}"); do
    VERIFY_STATUS="$(curl -sS -o /dev/null -w '%{http_code}' \
      -H "Authorization: Bearer ${ORCH_KEY}" \
      "http://127.0.0.1:${ORCH_PORT}/v1/agents/${PROFILE}")" || true
    if [[ "${VERIFY_STATUS}" == "200" ]]; then AGENT_VERIFIED=1; break; fi
    sleep "${AGENT_VERIFY_INTERVAL}"
  done
  if [[ -z "${AGENT_VERIFIED}" ]]; then
    echo "error: agent '${PROFILE}' was not created (the orchestrator accepted the request but the agent does not exist — check the orchestrator logs)" >&2
    exit 1
  fi
  echo "    agent '${PROFILE}' created from manifest defaults (authMethod=inherit)"
else
  echo "    agent '${PROFILE}' already exists — leaving it untouched"
fi

for i in $(seq 0 $((APP_COUNT-1))); do
  NAME="$(mf "['apps'][${i}]['name']")"
  KONG_PORT="$(mf "['apps'][${i}]['stack']['kong_port']")"
  EMAIL_ENABLED="$(mf "['apps'][${i}]['stack']['email_enabled']")"
  APP_PORT="$(mf "['apps'][${i}]['server']['app_port']")"
  CONTAINER_PORT="$(mf "['apps'][${i}]['server']['container_port']")"
  HEALTH_PATH="$(mf "['apps'][${i}]['server']['health_path']")"
  SB_ENV="${STACKS}/${NAME}/.env"

  # carry-forward hosts from an existing stack .env on re-runs
  [[ -z "${SB_HOST}" && -f "${SB_ENV}" ]] && SB_HOST="$(supabase_app_env_val "${SB_ENV}" SUPABASE_PUBLIC_URL)" && SB_HOST="${SB_HOST#https://}"
  [[ -z "${APP_HOST}" && -f "${SB_ENV}" ]] && APP_HOST="$(supabase_app_env_val "${SB_ENV}" SITE_URL)" && APP_HOST="${APP_HOST#https://}"
  [[ -n "${APP_HOST}" && -n "${SB_HOST}" ]] || { echo "error: APP_HOST and SB_HOST required" >&2; exit 1; }

  echo "==> agent-apps [${NAME}] 1/5: app schema + owner role in the core stack"
  {
    echo "APP_NAME=${NAME}"
    echo "CORE_STACK_DIR=${CORE_DIR}"
  } | bash "${SUB26}"

  echo "==> agent-apps [${NAME}] 2/5: app migrations into schema '${NAME}'"
  if [[ -n "${IMAGE_TARBALL}" ]]; then
    LOAD_OUT="$(docker load -i "${IMAGE_TARBALL}")"
    if [[ "$(grep -c '^Loaded image' <<<"${LOAD_OUT}")" -ne 1 ]]; then
      echo "error: tarball must contain exactly one image (got: ${LOAD_OUT})" >&2; exit 1
    fi
    LOADED="$(tail -n1 <<<"${LOAD_OUT}")"; IMG="${LOADED##*: }"
  else
    IMG="$(app_image_from_env "${NAME}")"   # helper: APP_IMAGE from ~/apps/<name>/.env
  fi
  CORE_PGPASS="$(supabase_app_env_val "${CORE_DIR}/.env" POSTGRES_PASSWORD)"
  [[ -n "${CORE_PGPASS}" ]] || { echo "error: POSTGRES_PASSWORD missing from ${CORE_DIR}/.env" >&2; exit 1; }
  core_psql() {
    # ${NAME}_owner is NOLOGIN by design (26 CREATEs it that way and only
    # GRANTs it to authenticator, for PostgREST's role-switching — it was
    # never meant to be connected to directly). Postgres rejects a NOLOGIN
    # role at connection time, before authentication is even consulted, so
    # connecting with `-U ${NAME}_owner` fails outright regardless of
    # PGPASSWORD/pg_hba. Connect as postgres instead and switch the SESSION
    # role via PGOPTIONS. Objects created under that session role are still
    # OWNED BY ${NAME}_owner (ownership follows the session/current role, not
    # the login role), so they still inherit the default privileges 26
    # installed for the PostgREST roles — the ownership requirement this
    # comment used to describe is preserved; only the connection mechanism
    # changed. Do not "simplify" this back to `-U ${NAME}_owner`.
    docker compose -f "${CORE_DIR}/docker-compose.yml" --env-file "${CORE_DIR}/.env" \
      exec -T -e PGPASSWORD="${CORE_PGPASS}" -e PGOPTIONS="-c role=${NAME}_owner" db \
      psql -h 127.0.0.1 -U postgres -d postgres -v ON_ERROR_STOP=1 -qtA "$@"
  }
  app_migrations_apply "${IMG}" core_psql "${NAME}._migrations" "${NAME}"

  echo "==> agent-apps [${NAME}] 3/5: app server (port ${APP_PORT})"
  # ORCH_KEY was already resolved above (before the preflight).
  CORE_URL="$(supabase_app_env_val "${CORE_DIR}/.env" SUPABASE_PUBLIC_URL)"
  ANON="$(supabase_app_env_val "${CORE_DIR}/.env" ANON_KEY)"
  [[ -n "${CORE_URL}" ]] || { echo "error: SUPABASE_PUBLIC_URL missing from ${CORE_DIR}/.env" >&2; exit 1; }
  [[ -n "${ANON}" ]] || { echo "error: ANON_KEY missing from ${CORE_DIR}/.env" >&2; exit 1; }
  # The app's runtime key: a JWT claiming role=<name>_owner, minted by 26.
  # This REPLACES service_role for the app. Core's service_role key bypasses
  # RLS and reaches every schema plus auth, so it must never reach a container.
  APP_KEY_FILE="${CORE_DIR}/app-keys/${NAME}.jwt"
  [[ -f "${APP_KEY_FILE}" ]] || { echo "error: ${APP_KEY_FILE} not found — 26 should have minted it in step 1/4" >&2; exit 1; }
  APP_KEY="$(cat "${APP_KEY_FILE}")"
  [[ -n "${APP_KEY}" ]] || { echo "error: ${APP_KEY_FILE} is empty" >&2; exit 1; }
  {
    echo "APP_NAME=${NAME}"
    echo "APP_PORT=${APP_PORT}"
    echo "CONTAINER_PORT=${CONTAINER_PORT}"
    echo "HEALTH_PATH=${HEALTH_PATH}"
    [[ -n "${IMAGE_TARBALL}" ]] && echo "IMAGE_TARBALL=${IMAGE_TARBALL}"
    echo "APP_ENV_SUPABASE_URL=${CORE_URL}"
    # Server-side callers must NOT use the public hostname: on a cloudflared
    # box it resolves to Cloudflare's edge, which bot-challenges non-browser
    # clients (HTTP 403) and breaks auth on every route. Core kong is
    # loopback-only, so reach it over the docker0 gateway bridge from 25.
    echo "APP_ENV_SUPABASE_INTERNAL_URL=http://172.17.0.1:${CORE_KONG_PORT}"
    echo "APP_ENV_SUPABASE_ANON_KEY=${ANON}"
    echo "APP_ENV_SUPABASE_APP_KEY=${APP_KEY}"
    echo "APP_ENV_SUPABASE_DB_SCHEMA=${NAME}"
    echo "APP_ENV_OLLIE_ENDPOINT=http://127.0.0.1:${ORCH_PORT}"
    echo "APP_ENV_OLLIE_AGENT=${PROFILE}"
    [[ -n "${ORCH_KEY}" ]] && echo "APP_ENV_OLLIE_ORCHESTRATOR_KEY=${ORCH_KEY}"
    echo "APP_ENV_APP_BASE_PATH=/apps/${NAME}"
    printf '%s\n' "${PASSTHRU[@]:-}" | grep -v '^$' || true
    true   # group's exit status must not hinge on the last optional/passthrough line (pipefail)
  } | bash "${SUB23}"

  echo "==> agent-apps [${NAME}] 4/5: dashboard tile registration"
  HAS_TILE="$(python3 -c "import json; d=json.load(open('${MANIFEST}')); print('1' if 'tile' in d['apps'][${i}] else '')")"
  if [[ -n "${HAS_TILE}" ]]; then
    # Build the whole JSON payload in python (json.dumps) so tile field
    # values never get bash-string-spliced into a JSON literal — they come
    # straight out of the committed manifest, read by python, not interpolated.
    #
    # sso is registered FALSE. ExternalWebApp.tsx treats a truthy sso as: fetch
    # an app-token, then load <base>sso?t=... That handoff signs into the app-s
    # OWN Supabase with a service-role client. A consolidated app has no
    # Supabase of its own and is handed no service-role key, so the handoff
    # cannot succeed and the tile shows an open-failure message. Its failure is
    # invisible to a health check: every failure path in the app-s /sso handler
    # returns HTTP 200 with an expired-link page. Falsy sso loads /apps/<name>/
    # directly on the first-party session cookie the same-origin proxy exists
    # to preserve.
    #
    # NOTE: the python below runs inside python3 -c with a DOUBLE-quoted shell
    # string, so double quotes, backticks and $ are consumed by bash before
    # python sees them. Keep prose out of that block — a comment with an
    # apostrophe or backtick in it silently corrupts the whole script.
    PAYLOAD="$(python3 -c "
import json
d = json.load(open('${MANIFEST}'))
app = d['apps'][${i}]
tile = app['tile']
payload = {
    'id': app['name'],
    'label': tile['label'],
    'icon': tile['icon'],
    'description': tile['description'],
    'order': tile['order'],
    'componentType': 'ExternalWebApp',
    'config': {'url': '/apps/' + app['name'] + '/', 'sso': False},
}
print(json.dumps(payload))
")"
    curl -fsS -X POST "http://127.0.0.1:${ORCH_PORT}/v1/agents/${PROFILE}/apps" \
      -H "Authorization: Bearer ${ORCH_KEY}" \
      -H 'Content-Type: application/json' \
      -d "${PAYLOAD}" >/dev/null \
      || { echo "error: dashboard tile registration failed for ${NAME}" >&2; exit 1; }
    echo "    tile registered (id=${NAME})"
    # The dashboard reaches a loopback-only app server through the docker0
    # gateway (host.docker.internal). generate-nginx.sh only adds the
    # /apps/<name>/ proxy when <NAME>_BASE_URL is set — without this the tile
    # registers fine and then renders blank.
    BASE_KEY="$(printf '%s' "${NAME}" | tr '[:lower:]-' '[:upper:]_')_BASE_URL"
    BASE_VAL="http://host.docker.internal:${APP_PORT}"
    STACK_DIR="$(dirname "${STACK_ENV_FILE}")"
    STACK_COMPOSE="${STACK_DIR}/docker-compose.yml"
    if [[ ! -f "${STACK_COMPOSE}" ]]; then
      # A missing docker-compose.yml here means the Hermes stack itself was
      # never installed at STACK_DIR (06-install-stack.sh creates it) — not a
      # transient gap to paper over. Fabricating the directory/.env would
      # write an orphan key nothing reads, then fail two steps later with a
      # generic compose error. Warn with the specific cause and skip instead.
      echo "    WARNING: no docker-compose.yml at ${STACK_DIR} — is the Hermes stack installed there? (run 06-install-stack.sh). Skipping ${BASE_KEY} update." >&2
      WARNINGS=$((WARNINGS+1))
    elif ! grep -qF "${BASE_KEY}" "${STACK_COMPOSE}" 2>/dev/null; then
      # The dashboard only receives <NAME>_BASE_URL if docker-compose.yml
      # references it under the dashboard service's `environment:` block. That
      # passthrough was added 2026-07-23 — boxes installed before that (and
      # this branch deliberately does not backfill them) have a compose file
      # that never reads this var, so writing it to .env would be a silent
      # no-op: the tile renders blank with no error anywhere.
      echo "    WARNING: ${STACK_COMPOSE} does not pass ${BASE_KEY} to the dashboard — the tile will render blank. Re-run 06-install-stack.sh to refresh the stack compose file." >&2
      WARNINGS=$((WARNINGS+1))
    elif [[ ! -f "${STACK_ENV_FILE}" ]]; then
      # docker-compose.yml can exist without .env (partial/broken install) —
      # writing an orphan one-line .env here would then fail the recreate
      # below with a generic compose error. Warn with the specific cause.
      echo "    WARNING: no ${STACK_ENV_FILE} — is the Hermes stack installed there? (run 06-install-stack.sh). Skipping ${BASE_KEY} update." >&2
      WARNINGS=$((WARNINGS+1))
    else
      if grep -q "^${BASE_KEY}=" "${STACK_ENV_FILE}" 2>/dev/null; then
        sed -i "s|^${BASE_KEY}=.*|${BASE_KEY}=${BASE_VAL}|" "${STACK_ENV_FILE}"
      else
        echo "${BASE_KEY}=${BASE_VAL}" >> "${STACK_ENV_FILE}"
      fi
      echo "    ${BASE_KEY}=${BASE_VAL} (recreate the dashboard to apply)"
      docker compose -f "${STACK_COMPOSE}" \
        --env-file "${STACK_ENV_FILE}" up -d dashboard >/dev/null 2>&1 \
        || { echo "    WARNING: could not recreate the dashboard — run it yourself to apply ${BASE_KEY}" >&2; WARNINGS=$((WARNINGS+1)); }
    fi
  else
    echo "    (no tile in manifest — skipping)"
  fi

  # /api/health does not touch Supabase, so a missing kong bridge leaves the
  # app "healthy" while every API call 403s. Announce it instead.
  #
  # Probes CORE kong (the fixed ${CORE_KONG_PORT}) — the same instance written
  # to APP_ENV_SUPABASE_INTERNAL_URL above — NOT the manifest's per-app
  # kong_port. A consolidated app is a schema in the core stack and never
  # talks to a per-app kong, so probing that port reported a failure for a
  # service the app does not use, while the genuinely missing core-kong bridge
  # went unmentioned. The bridge is shared by every app on the box, hence the
  # fixed `core-sb` name rather than a per-app one.
  if ! curl -fsS --max-time 10 "http://172.17.0.1:${CORE_KONG_PORT}/auth/v1/health" >/dev/null 2>&1; then
    echo "    WARNING: internal Supabase URL http://172.17.0.1:${CORE_KONG_PORT} is unreachable — the app will look healthy but every API call will fail. Install the bridge: sudo bash ${SCRIPT_DIR}/25-install-app-bridge.sh core-sb:${CORE_KONG_PORT}" >&2
    WARNINGS=$((WARNINGS+1))
  fi

  echo "==> agent-apps [${NAME}] 5/5: caddy (root step — run yourself)"
  # App vhost only. A consolidated app has no Supabase of its own, so there is
  # no sb-<app> hostname to serve; core's public hostname belongs to the core
  # stack's own setup, not to a per-app install.
  echo "    sudo bash ${SCRIPT_DIR}/22-install-caddy-vhosts.sh ${APP_HOST}:${APP_PORT}"
  echo "    WARNING: 22 renders the Caddyfile from ONLY its args — include EVERY vhost this box serves."
  echo "    NOTE: caddy-fronted boxes only. On a cloudflared box SKIP 22 and add a tunnel"
  echo "          public hostname instead (${APP_HOST} -> http://localhost:${APP_PORT})."
  echo "          Do NOT open :80/:443."
  if [[ -n "${HAS_TILE}" ]]; then
    # Tile apps are embedded in the dashboard, which reaches the host via
    # host.docker.internal = 172.17.0.1 (the docker0 gateway) — unreachable
    # for a loopback-only (127.0.0.1) app server. 25 installs a static socat
    # bridge (same fix 06-install-stack.sh hand-builds for the native Hermes
    # dashboard on 9119) so the tile doesn't 502.
    echo "    sudo bash ${SCRIPT_DIR}/25-install-app-bridge.sh ${NAME}:${APP_PORT} core-sb:${CORE_KONG_PORT}"
  fi
done
if [[ "${WARNINGS}" -eq 0 ]]; then
  echo "✓ agent-apps for profile '${PROFILE}' installed (caddy step printed above)"
else
  echo "⚠ agent-apps for profile '${PROFILE}' installed with ${WARNINGS} warning(s) — see above; the app is not fully functional until they are resolved"
fi
