#!/usr/bin/env bash
# 20-install-app-stack.sh — stand up ONE parameterized app Supabase stack
# (templates/supabase-app) at ~/stacks/<STACK_NAME>. Multi-stack-per-host safe:
# compose project = STACK_NAME, containers <STACK_NAME>-*, kong on
# 127.0.0.1:<KONG_PORT>. NO orchestrator/dashboard coupling (that's the Ollie
# stack's 11-install-supabase.sh). Schema/data arrive later via
# 21-migrate-app.sh — or via 24-install-agent-apps.sh (image-bundled
# migrations) for manifest apps.
#
# Run as: the service user. Idempotent — re-runs preserve secrets, restamp pins.
# Input (stdin, KEY=VALUE lines):
#   STACK_NAME=<^[a-z][a-z0-9-]*$, required>
#   KONG_PORT=<numeric, required first run>
#   SUPABASE_PUBLIC_URL=<https origin, required first run>
#   SITE_URL=<https origin, required first run>
#   REALTIME=1            (optional; enables the realtime service profile)
# Re-runs may pass only STACK_NAME — everything else carries forward from .env.
set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  echo "error: run as the service user, not root" >&2; exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/lib/supabase-env.sh"
. "${SCRIPT_DIR}/lib/supabase-app-env.sh"
TEMPLATES="${SCRIPT_DIR}/../templates/supabase-app"

STACK_NAME="" ; KONG_PORT="" ; SUPABASE_PUBLIC_URL="" ; SITE_URL="" ; REALTIME=""
GOOGLE_CLIENT_ID="" ; GOOGLE_CLIENT_SECRET="" ; EMAIL_ENABLED=""
while IFS='=' read -r k v || [[ -n "${k:-}" ]]; do
  case "${k}" in
    STACK_NAME) STACK_NAME="${v}" ;;
    KONG_PORT) KONG_PORT="${v}" ;;
    SUPABASE_PUBLIC_URL) SUPABASE_PUBLIC_URL="${v}" ;;
    SITE_URL) SITE_URL="${v}" ;;
    REALTIME) REALTIME="${v}" ;;
    GOOGLE_CLIENT_ID) GOOGLE_CLIENT_ID="${v}" ;;
    GOOGLE_CLIENT_SECRET) GOOGLE_CLIENT_SECRET="${v}" ;;
    EMAIL_ENABLED) EMAIL_ENABLED="${v}" ;;
  esac
done
if [[ ! "${STACK_NAME}" =~ ^[a-z][a-z0-9-]*$ ]]; then
  echo "error: STACK_NAME required, ^[a-z][a-z0-9-]*$ (got: '${STACK_NAME}')" >&2; exit 1
fi
SB_DIR="${SB_DIR:-$HOME/stacks/${STACK_NAME}}"
# carry-forward
[[ -z "${KONG_PORT}" ]] && KONG_PORT="$(supabase_app_env_val "${SB_DIR}/.env" KONG_PORT)"
[[ -z "${SUPABASE_PUBLIC_URL}" ]] && SUPABASE_PUBLIC_URL="$(supabase_app_env_val "${SB_DIR}/.env" SUPABASE_PUBLIC_URL)"
[[ -z "${SITE_URL}" ]] && SITE_URL="$(supabase_app_env_val "${SB_DIR}/.env" SITE_URL)"
if [[ ! "${KONG_PORT}" =~ ^[0-9]+$ ]]; then
  echo "error: KONG_PORT required (numeric), got '${KONG_PORT}'" >&2; exit 1
fi
supabase_validate_inputs "${SUPABASE_PUBLIC_URL}" "placeholder-key-not-validated-here" || exit 1
supabase_validate_inputs "${SITE_URL}" "placeholder-key-not-validated-here" || exit 1

PROFILE_ARGS=()
[[ "${REALTIME}" == "1" ]] && PROFILE_ARGS=(--profile realtime)
# carry realtime choice forward: once enabled, keep enabling on re-runs
if [[ -z "${REALTIME}" && -f "${SB_DIR}/.realtime" ]]; then PROFILE_ARGS=(--profile realtime); fi

echo "==> app-stack 1: stage ${SB_DIR}"
mkdir -p "${SB_DIR}"
chmod 700 "${SB_DIR}"
cp "${TEMPLATES}/docker-compose.yml" "${SB_DIR}/docker-compose.yml"
ENV_OLD=""
if [[ -f "${SB_DIR}/.env" ]]; then ENV_OLD="$(mktemp)"; cp "${SB_DIR}/.env" "${ENV_OLD}"; fi
export STACK_NAME KONG_PORT SUPABASE_PUBLIC_URL SITE_URL GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET EMAIL_ENABLED
render_supabase_app_env "${SB_DIR}/.env" "${ENV_OLD}"
[[ -n "${ENV_OLD}" ]] && rm -f "${ENV_OLD}"
[[ "${REALTIME}" == "1" ]] && touch "${SB_DIR}/.realtime"
# Re-read the Google creds from the rendered .env and re-export. On a
# carry-forward re-run (creds omitted from stdin) the exports above are EMPTY
# strings, and docker compose gives the process environment PRECEDENCE over
# --env-file — so the empty exports would recreate auth with a blank Google
# client and every login 400s at /authorize (hit live on the Ollie sandbox
# cutover, 2026-07-11). The rendered .env always holds the preserved values.
GOOGLE_CLIENT_ID="$(supabase_app_env_val "${SB_DIR}/.env" GOOGLE_CLIENT_ID)"
GOOGLE_CLIENT_SECRET="$(supabase_app_env_val "${SB_DIR}/.env" GOOGLE_CLIENT_SECRET)"
GOOGLE_ENABLED="$(supabase_app_env_val "${SB_DIR}/.env" GOOGLE_ENABLED)"
EMAIL_ENABLED="$(supabase_app_env_val "${SB_DIR}/.env" EMAIL_ENABLED)"
export GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET GOOGLE_ENABLED EMAIL_ENABLED
ANON_KEY="$(supabase_app_env_val "${SB_DIR}/.env" ANON_KEY)"
SERVICE_ROLE_KEY="$(supabase_app_env_val "${SB_DIR}/.env" SERVICE_ROLE_KEY)"
supabase_render_kong "${TEMPLATES}/kong.yml" "${SB_DIR}/kong.yml" "${ANON_KEY}" "${SERVICE_ROLE_KEY}"

COMPOSE=(docker compose -p "${STACK_NAME}" -f "${SB_DIR}/docker-compose.yml" --env-file "${SB_DIR}/.env" "${PROFILE_ARGS[@]}")

echo "==> app-stack 2: docker compose up -d (project ${STACK_NAME})"
"${COMPOSE[@]}" pull --quiet
"${COMPOSE[@]}" up -d

echo "==> app-stack 3: sync internal role passwords"
SB_PGPASS="$(supabase_app_env_val "${SB_DIR}/.env" POSTGRES_PASSWORD)"
"${COMPOSE[@]}" exec -T -e PGPASSWORD="${SB_PGPASS}" db psql -h 127.0.0.1 -U supabase_admin -d postgres \
  -c "ALTER USER supabase_auth_admin WITH PASSWORD '${SB_PGPASS}';" \
  -c "ALTER USER authenticator WITH PASSWORD '${SB_PGPASS}';" \
  -c "ALTER USER supabase_storage_admin WITH PASSWORD '${SB_PGPASS}';"

# Realtime's Ecto migrations run in the _realtime schema, whose search_path is
# preset by DB_AFTER_CONNECT_QUERY. On a fresh db that schema does not exist
# yet, so the very first migration fails with 3F000 (no schema selected) and
# the container crash-loops. Pre-create it, then restart realtime so it picks
# up a clean slate. Idempotent (IF NOT EXISTS); no-op when realtime is off.
if [[ "${PROFILE_ARGS[*]}" == *"realtime"* ]]; then
  echo "==> app-stack 3b: ensure _realtime schema + restart realtime"
  "${COMPOSE[@]}" exec -T -e PGPASSWORD="${SB_PGPASS}" db psql -h 127.0.0.1 -U supabase_admin -d postgres \
    -c "CREATE SCHEMA IF NOT EXISTS _realtime AUTHORIZATION supabase_admin;"
  "${COMPOSE[@]}" restart realtime
fi

echo "==> app-stack 4: wait for auth healthy via kong :${KONG_PORT}"
set +e
CODE=""
for i in $(seq 1 30); do
  CODE="$(curl -s -o /dev/null -w '%{http_code}' -m 5 \
    -H "apikey: ${ANON_KEY}" "http://127.0.0.1:${KONG_PORT}/auth/v1/health")"
  [[ "${CODE}" == "200" ]] && break
  sleep 2
done
set -e
if [[ "${CODE:-}" != "200" ]]; then
  echo "error: auth /health did not come up (last HTTP ${CODE:-none}) — check: docker compose -p ${STACK_NAME} -f ${SB_DIR}/docker-compose.yml logs auth kong" >&2
  exit 1
fi
echo "    auth /health → 200 ✓"

echo
echo "✓ app stack '${STACK_NAME}' up (kong 127.0.0.1:${KONG_PORT})."
echo "  App env values (set on Railway/compose after 21-migrate-app.sh):"
echo "  NEXT_PUBLIC_SUPABASE_URL=${SUPABASE_PUBLIC_URL}"
echo "  NEXT_PUBLIC_SUPABASE_ANON_KEY=${ANON_KEY}"
echo "  SUPABASE_SERVICE_ROLE_KEY=${SERVICE_ROLE_KEY}"
echo "  Next: schema+data via 21-migrate-app.sh; public TLS via 22-install-caddy-vhosts.sh."
