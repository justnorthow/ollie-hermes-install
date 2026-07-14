#!/usr/bin/env bash
# 21-migrate-app.sh — migrate ONE hosted Supabase project (whole public
# schema + data + auth users + storage + realtime publication) into ONE local
# app stack deployed by 20-install-app-stack.sh. The HOSTED side is only ever
# read. Idempotent: schema restore is additive-or-noop on re-runs (objects
# exist), data copy is truncate-first, storage sync is upsert.
#
# Input (stdin, KEY=VALUE lines — secrets never in argv):
#   STACK_NAME=<stack deployed under ~/stacks/<name>>
#   HOSTED_DB_URL=postgresql://postgres.<ref>:<pass>@…pooler.supabase.com:5432/postgres
#   HOSTED_SUPABASE_URL=https://<ref>.supabase.co
#   HOSTED_SERVICE_ROLE_KEY=<service role key>
set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  echo "error: run as the service user, not root" >&2; exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/lib/supabase-env.sh"
. "${SCRIPT_DIR}/lib/supabase-app-env.sh"
. "${SCRIPT_DIR}/lib/supabase-migrate.sh"
. "${SCRIPT_DIR}/lib/supabase-app-migrate.sh"

MIGRATE_PG_IMAGE="${MIGRATE_PG_IMAGE:-postgres:17-alpine}"
AUTH_TABLES=(users identities)

STACK_NAME="" ; HOSTED_DB_URL="" ; HOSTED_SUPABASE_URL="" ; HOSTED_SERVICE_ROLE_KEY=""
while IFS='=' read -r k v || [[ -n "${k:-}" ]]; do
  case "${k}" in
    STACK_NAME) STACK_NAME="${v}" ;;
    HOSTED_DB_URL) HOSTED_DB_URL="${v}" ;;
    HOSTED_SUPABASE_URL) HOSTED_SUPABASE_URL="${v}" ;;
    HOSTED_SERVICE_ROLE_KEY) HOSTED_SERVICE_ROLE_KEY="${v}" ;;
  esac
done
MISSING=""
[[ -z "${STACK_NAME}" ]] && MISSING="${MISSING} STACK_NAME"
[[ -z "${HOSTED_DB_URL}" ]] && MISSING="${MISSING} HOSTED_DB_URL"
[[ -z "${HOSTED_SUPABASE_URL}" ]] && MISSING="${MISSING} HOSTED_SUPABASE_URL"
[[ -z "${HOSTED_SERVICE_ROLE_KEY}" ]] && MISSING="${MISSING} HOSTED_SERVICE_ROLE_KEY"
if [[ -n "${MISSING}" ]]; then
  echo "error: missing required stdin key(s):${MISSING}" >&2; exit 1
fi
export HOSTED_DB_URL

SB_DIR="${SB_DIR:-$HOME/stacks/${STACK_NAME}}"
echo "==> app-migrate 1: preflight (${SB_DIR})"
if [[ ! -f "${SB_DIR}/.env" ]]; then
  echo "error: ${SB_DIR}/.env not found — deploy first: 20-install-app-stack.sh" >&2; exit 1
fi
KONG_PORT="$(supabase_app_env_val "${SB_DIR}/.env" KONG_PORT)"
LOCAL_PUBLIC_URL="$(supabase_app_env_val "${SB_DIR}/.env" SUPABASE_PUBLIC_URL)"
LOCAL_ANON_KEY="$(supabase_app_env_val "${SB_DIR}/.env" ANON_KEY)"
LOCAL_SERVICE_KEY="$(supabase_app_env_val "${SB_DIR}/.env" SERVICE_ROLE_KEY)"
LOCAL_PGPASS="$(supabase_app_env_val "${SB_DIR}/.env" POSTGRES_PASSWORD)"
for v in KONG_PORT LOCAL_PUBLIC_URL LOCAL_ANON_KEY LOCAL_SERVICE_KEY LOCAL_PGPASS; do
  if [[ -z "${!v}" ]]; then echo "error: ${v} empty in ${SB_DIR}/.env" >&2; exit 1; fi
done
if [[ "${MIGRATE_PREFLIGHT_ONLY:-0}" == "1" ]]; then echo "    preflight OK"; exit 0; fi

migrate_src_psql() {
  docker run --rm -i --network host -e HOSTED_DB_URL "${MIGRATE_PG_IMAGE}" \
    sh -c 'exec psql "$HOSTED_DB_URL" -v ON_ERROR_STOP=1 "$@"' -- "$@"
}
migrate_src_pgdump() {
  docker run --rm -i --network host -e HOSTED_DB_URL "${MIGRATE_PG_IMAGE}" \
    sh -c 'exec pg_dump "$HOSTED_DB_URL" "$@"' -- "$@"
}
migrate_dst_psql() {
  docker compose -p "${STACK_NAME}" -f "${SB_DIR}/docker-compose.yml" --env-file "${SB_DIR}/.env" \
    exec -T -e PGPASSWORD="${LOCAL_PGPASS}" db \
    psql -h 127.0.0.1 -U supabase_admin -d postgres -v ON_ERROR_STOP=1 "$@" </dev/stdin
}

echo "==> app-migrate 2: connectivity"
SRC_VER="$(migrate_src_psql -tAc 'show server_version' </dev/null)" \
  || { echo "error: cannot reach hosted DB — check HOSTED_DB_URL (Session pooler string; project must be RESTORED if paused)" >&2; exit 1; }
echo "    hosted postgres ${SRC_VER} ✓"
migrate_dst_psql -tAc 'select 1' </dev/null >/dev/null \
  || { echo "error: local ${STACK_NAME} db not reachable" >&2; exit 1; }

echo "==> app-migrate 3: restore public schema (pg_dump --schema-only)"
sb_app_dump_schema

echo "==> app-migrate 4: copy auth (UUID-preserving)"
for t in "${AUTH_TABLES[@]}"; do sb_copy_table auth "$t"; sb_fix_sequences auth "$t"; done

echo "==> app-migrate 5: copy public data (FK-order-free, count-verified)"
TABLES="$(sb_app_list_tables | tr '\n' ' ')"
echo "    tables: ${TABLES}"
sb_app_copy_data "${TABLES}"

echo "==> app-migrate 6: storage (buckets + objects + RLS policies)"
sb_app_port_storage "${HOSTED_SUPABASE_URL}" "${HOSTED_SERVICE_ROLE_KEY}" \
  "http://127.0.0.1:${KONG_PORT}" "${LOCAL_SERVICE_KEY}"

echo "==> app-migrate 7: realtime publication + replica identity"
sb_app_port_realtime_publication

echo "==> app-migrate 8: verify"
CODE="$(curl -s -o /dev/null -w '%{http_code}' -m 15 \
  -H "apikey: ${LOCAL_SERVICE_KEY}" -H "Authorization: Bearer ${LOCAL_SERVICE_KEY}" \
  "http://127.0.0.1:${KONG_PORT}/rest/v1/?limit=1" || echo 000)"
[[ "${CODE}" == "200" ]] || { echo "error: local REST probe HTTP ${CODE}" >&2; exit 1; }
USERS_N="$(migrate_dst_psql -tAc 'select count(*) from auth.users' </dev/null)"
echo "    auth.users rows: ${USERS_N}"

echo
echo "✓ '${STACK_NAME}' migrated from ${HOSTED_SUPABASE_URL}."
echo "  Now point the app at it:"
echo "  NEXT_PUBLIC_SUPABASE_URL=${LOCAL_PUBLIC_URL}"
echo "  NEXT_PUBLIC_SUPABASE_ANON_KEY=${LOCAL_ANON_KEY}"
echo "  SUPABASE_SERVICE_ROLE_KEY=${LOCAL_SERVICE_KEY}"
echo "  Rollback = point the app back at ${HOSTED_SUPABASE_URL} (hosted project stays PAUSED, not deleted, until soak passes)."
