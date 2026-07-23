#!/usr/bin/env bash
# 24-install-agent-apps.sh <profile> — install every app the manifest
# (apps/<profile>.json) bundles with an agent profile: 20 (Supabase stack) ->
# app migrations (extracted from the app image; tracked in _app_migrations) ->
# 23 (app server) -> dashboard tile registration (manifest apps with a "tile"
# key are upserted into the orchestrator's per-profile app registry). Caddy
# (22) needs root, so this prints the exact command —
# REMINDER: 22 renders from ONLY its args; pass the box's FULL vhost set.
# Box-derived config is resolved here (stack anon key, orchestrator loopback);
# operator secrets arrive on stdin and flow through, never argv.
# Input (stdin): APP_HOST, SB_HOST (req first run), IMAGE_TARBALL (req first
#   run), GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, ORCH_ENV_FILE, ORCH_PORT,
#   APP_ENV_<KEY>... passthrough.
# ORCH_ENV_FILE also supplies HIA_SSO_SECRET (dashboard SSO signing secret,
# passed through as APP_ENV_HIA_SSO_SECRET; absent = WARN + continue, the
# rollout runbook creates it) and ORCHESTRATOR_KEY (used both as
# APP_ENV_OLLIE_ORCHESTRATOR_KEY and as the bearer for the tile-registry POST).
# SUPABASE_SERVICE_ROLE_KEY is read from the app's own stack .env (20 always
# renders it) and passed through as APP_ENV_SUPABASE_SERVICE_ROLE_KEY — its
# absence fails loud, since that means the stack render never ran.
set -euo pipefail
if [[ "$(id -u)" -eq 0 ]]; then
  echo "error: run as the service user, not root" >&2; exit 1
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/lib/supabase-app-env.sh"
. "${SCRIPT_DIR}/lib/app-server-env.sh"
PROFILE="${1:-}"
MANIFEST="${MANIFEST_DIR:-${SCRIPT_DIR}/../apps}/${PROFILE}.json"
[[ -n "${PROFILE}" && -f "${MANIFEST}" ]] || { echo "error: no manifest for profile '${PROFILE}'" >&2; exit 1; }
SUB20="${SUB20:-${SCRIPT_DIR}/20-install-app-stack.sh}"
SUB23="${SUB23:-${SCRIPT_DIR}/23-install-app-server.sh}"
STACKS="${STACKS_DIR:-$HOME/stacks}"

APP_HOST="" ; SB_HOST="" ; IMAGE_TARBALL="" ; GOOGLE_CLIENT_ID="" ; GOOGLE_CLIENT_SECRET=""
ORCH_ENV_FILE="" ; ORCH_PORT=""
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
    APP_ENV_*) PASSTHRU+=("${k}=${v}") ;;
  esac
done
ORCH_ENV_FILE="${ORCH_ENV_FILE:-$HOME/hermes-stack/.env}"
ORCH_PORT="${ORCH_PORT:-9123}"

mf() { # JQPATH — read a manifest value
  python3 -c "import json,sys; d=json.load(open('${MANIFEST}')); print(eval('d'+sys.argv[1]))" "$1"
}
APP_COUNT="$(mf "['apps'].__len__()")"
if [[ "${APP_COUNT}" -gt 1 ]]; then
  echo "error: multi-app manifests are not yet supported (APP_HOST/SB_HOST/IMAGE_TARBALL are single-app; add per-app host fields to the manifest schema first)" >&2
  exit 1
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

  echo "==> agent-apps [${NAME}] 1/5: supabase stack (kong ${KONG_PORT})"
  {
    echo "STACK_NAME=${NAME}"
    echo "KONG_PORT=${KONG_PORT}"
    echo "SUPABASE_PUBLIC_URL=https://${SB_HOST}"
    echo "SITE_URL=https://${APP_HOST}"
    echo "EMAIL_ENABLED=${EMAIL_ENABLED}"
    [[ -n "${GOOGLE_CLIENT_ID}" ]] && echo "GOOGLE_CLIENT_ID=${GOOGLE_CLIENT_ID}"
    [[ -n "${GOOGLE_CLIENT_SECRET}" ]] && echo "GOOGLE_CLIENT_SECRET=${GOOGLE_CLIENT_SECRET}"
    true   # group's exit status must not hinge on the last optional field being absent (pipefail)
  } | bash "${SUB20}"

  echo "==> agent-apps [${NAME}] 2/5: app migrations"
  if [[ -n "${IMAGE_TARBALL}" ]]; then
    LOAD_OUT="$(docker load -i "${IMAGE_TARBALL}")"
    if [[ "$(grep -c '^Loaded image' <<<"${LOAD_OUT}")" -ne 1 ]]; then
      echo "error: tarball must contain exactly one image (got: ${LOAD_OUT})" >&2; exit 1
    fi
    LOADED="$(tail -n1 <<<"${LOAD_OUT}")"; IMG="${LOADED##*: }"
  else
    IMG="$(app_image_from_env "${NAME}")"   # helper: APP_IMAGE from ~/apps/<name>/.env
  fi
  MIG_DIR="$(mktemp -d)"
  CTR="$(docker create "${IMG}")"
  docker cp "${CTR}:/app/supabase/migrations/." "${MIG_DIR}/"
  docker rm "${CTR}" >/dev/null
  PGPASS="$(supabase_app_env_val "${SB_ENV}" POSTGRES_PASSWORD)"
  PSQL=(docker compose -p "${NAME}" -f "${STACKS}/${NAME}/docker-compose.yml" --env-file "${SB_ENV}" \
        exec -T -e PGPASSWORD="${PGPASS}" db psql -h 127.0.0.1 -U supabase_admin -d postgres -v ON_ERROR_STOP=1 -qtA)
  "${PSQL[@]}" -c "create table if not exists public._app_migrations (name text primary key, applied_at timestamptz not null default now());"
  for f in $(ls "${MIG_DIR}"/*.sql | sort); do
    base="$(basename "$f")"
    applied="$("${PSQL[@]}" -c "select 1 from public._app_migrations where name='${base}';")"
    if [[ "${applied}" == "1" ]]; then echo "    skip ${base} (applied)"; continue; fi
    echo "    apply ${base}"
    # Single-transaction apply (-1 = --single-transaction): the migration
    # file and its tracker INSERT travel in ONE psql invocation, so a
    # mid-file failure rolls back everything — including the insert — and
    # re-runs stay clean (no partially-applied file left recorded as done,
    # and no successfully-applied file left unrecorded).
    { cat "$f"; printf "\ninsert into public._app_migrations (name) values ('%s');\n" "${base}"; } | "${PSQL[@]}" -1 -f -
  done
  rm -rf "${MIG_DIR}"

  echo "==> agent-apps [${NAME}] 3/5: app server (port ${APP_PORT})"
  ANON="$(supabase_app_env_val "${SB_ENV}" ANON_KEY)"
  ORCH_KEY="$(grep -E '^ORCHESTRATOR_KEY=' "${ORCH_ENV_FILE}" | tail -n1 | cut -d= -f2- || true)"
  # Dashboard SSO: HIA_SSO_SECRET signs/validates the orchestrator's app-token
  # (verified by the app's own /sso endpoint). Absent on a fresh box is
  # expected pre-rollout — SSO just 503s gracefully — so warn and continue
  # rather than fail the whole app install over it.
  HIA_SSO_SECRET="$(grep -E '^HIA_SSO_SECRET=' "${ORCH_ENV_FILE}" | tail -n1 | cut -d= -f2- || true)"
  [[ -n "${HIA_SSO_SECRET}" ]] || echo "WARN: HIA_SSO_SECRET missing from ${ORCH_ENV_FILE} — SSO will 503 until the rollout sets it" >&2
  # SERVICE_ROLE_KEY: the app stack's supabase-app-env.sh renders this as part
  # of the all-or-nothing 6-secret bundle every time (Step 1 above), so its
  # absence here means that render never happened — a real misconfiguration,
  # not a rollout gap. Fail loud instead of shipping an app that can never
  # mint an SSO session.
  SERVICE_ROLE_KEY="$(supabase_app_env_val "${SB_ENV}" SERVICE_ROLE_KEY)"
  [[ -n "${SERVICE_ROLE_KEY}" ]] || { echo "error: SERVICE_ROLE_KEY missing from ${SB_ENV} (stack .env should always have it)" >&2; exit 1; }
  {
    echo "APP_NAME=${NAME}"
    echo "APP_PORT=${APP_PORT}"
    echo "CONTAINER_PORT=${CONTAINER_PORT}"
    echo "HEALTH_PATH=${HEALTH_PATH}"
    [[ -n "${IMAGE_TARBALL}" ]] && echo "IMAGE_TARBALL=${IMAGE_TARBALL}"
    echo "APP_ENV_SUPABASE_URL=https://${SB_HOST}"
    echo "APP_ENV_SUPABASE_ANON_KEY=${ANON}"
    echo "APP_ENV_OLLIE_ENDPOINT=http://127.0.0.1:${ORCH_PORT}"
    echo "APP_ENV_OLLIE_AGENT=${PROFILE}"
    [[ -n "${ORCH_KEY}" ]] && echo "APP_ENV_OLLIE_ORCHESTRATOR_KEY=${ORCH_KEY}"
    [[ -n "${HIA_SSO_SECRET}" ]] && echo "APP_ENV_HIA_SSO_SECRET=${HIA_SSO_SECRET}"
    echo "APP_ENV_SUPABASE_SERVICE_ROLE_KEY=${SERVICE_ROLE_KEY}"
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
    'config': {'url': '/apps/' + app['name'] + '/', 'sso': True},
}
print(json.dumps(payload))
")"
    curl -fsS -X POST "http://127.0.0.1:${ORCH_PORT}/v1/agents/${PROFILE}/apps" \
      -H "Authorization: Bearer ${ORCH_KEY}" \
      -H 'Content-Type: application/json' \
      -d "${PAYLOAD}" >/dev/null \
      || { echo "error: dashboard tile registration failed for ${NAME}" >&2; exit 1; }
    echo "    tile registered (id=${NAME})"
  else
    echo "    (no tile in manifest — skipping)"
  fi

  echo "==> agent-apps [${NAME}] 5/5: caddy (root step — run yourself)"
  echo "    sudo bash ${SCRIPT_DIR}/22-install-caddy-vhosts.sh ${APP_HOST}:${APP_PORT} ${SB_HOST}:${KONG_PORT}"
  echo "    WARNING: 22 renders the Caddyfile from ONLY its args — include EVERY vhost this box serves."
  if [[ -n "${HAS_TILE}" ]]; then
    # Tile apps are embedded in the dashboard, which reaches the host via
    # host.docker.internal = 172.17.0.1 (the docker0 gateway) — unreachable
    # for a loopback-only (127.0.0.1) app server. 25 installs a static socat
    # bridge (same fix 06-install-stack.sh hand-builds for the native Hermes
    # dashboard on 9119) so the tile doesn't 502.
    echo "    sudo bash ${SCRIPT_DIR}/25-install-app-bridge.sh ${NAME}:${APP_PORT}"
  fi
done
echo "✓ agent-apps for profile '${PROFILE}' installed (caddy step printed above)"
