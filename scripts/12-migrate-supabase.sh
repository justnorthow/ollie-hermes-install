#!/usr/bin/env bash
# 12-migrate-supabase.sh — migrate a hosted Supabase project's Ollie data into
# this box's LOCAL supabase stack, then repoint the dashboard + orchestrator.
#
# Run as: the service user. The local stack must already be deployed
# (11-install-supabase.sh --deploy). Idempotent: truncate-first copy, upsert
# storage sync, env writes overwrite the same keys. The HOSTED side is only
# ever read (SELECT / COPY TO STDOUT / REST GET).
#
# Input (stdin, KEY=VALUE lines — secrets never in argv):
#   HOSTED_DB_URL=postgresql://postgres.<ref>:<pass>@…pooler.supabase.com:5432/postgres
#   HOSTED_SUPABASE_URL=https://<ref>.supabase.co
#   HOSTED_SERVICE_ROLE_KEY=<service role key>
#
# Copies (UUID-preserving): auth.users, auth.identities, then public
# agent_sessions, run_owners, user_roles, role_labels, user_tags,
# governance_events; then syncs the profile-images storage bucket.
set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  echo "error: run as the service user, not root" >&2; exit 1
fi
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/lib/supabase-env.sh"
. "${SCRIPT_DIR}/lib/supabase-stack-env.sh"
. "${SCRIPT_DIR}/lib/supabase-migrate.sh"

SB_DIR="${SB_DIR:-$HOME/supabase-stack}"
STACK_ENV="${STACK_ENV:-$HOME/hermes-stack/.env}"
ORCH_ENV="${ORCH_ENV:-$HOME/.config/ollie-orchestrator/.env}"
MIGRATE_PG_IMAGE="${MIGRATE_PG_IMAGE:-postgres:17-alpine}"

AUTH_TABLES=(users identities)
PUBLIC_TABLES=(agent_sessions run_owners user_roles role_labels user_tags governance_events)
BUCKET="profile-images"

# ---- stdin ------------------------------------------------------------------
HOSTED_DB_URL="" ; HOSTED_SUPABASE_URL="" ; HOSTED_SERVICE_ROLE_KEY=""
while IFS='=' read -r k v || [[ -n "${k:-}" ]]; do
  case "${k}" in
    HOSTED_DB_URL) HOSTED_DB_URL="${v}" ;;
    HOSTED_SUPABASE_URL) HOSTED_SUPABASE_URL="${v}" ;;
    HOSTED_SERVICE_ROLE_KEY) HOSTED_SERVICE_ROLE_KEY="${v}" ;;
  esac
done
MISSING=""
[[ -z "${HOSTED_DB_URL}" ]] && MISSING="${MISSING} HOSTED_DB_URL"
[[ -z "${HOSTED_SUPABASE_URL}" ]] && MISSING="${MISSING} HOSTED_SUPABASE_URL"
[[ -z "${HOSTED_SERVICE_ROLE_KEY}" ]] && MISSING="${MISSING} HOSTED_SERVICE_ROLE_KEY"
if [[ -n "${MISSING}" ]]; then
  echo "error: missing required stdin key(s):${MISSING}" >&2; exit 1
fi

# Exported so the psql runner can receive it via docker -e (env forwarding),
# keeping the hosted password out of docker's argv (ps-visible).
export HOSTED_DB_URL

# ---- preflight ---------------------------------------------------------------
echo "==> migrate 1: preflight"
if [[ ! -f "${SB_DIR}/.env" ]]; then
  echo "error: ${SB_DIR}/.env not found — deploy the local stack first: bash ~/ollie-hermes-install/scripts/11-install-supabase.sh --deploy" >&2
  exit 1
fi
LOCAL_PUBLIC_URL="$(supabase_stack_env_val "${SB_DIR}/.env" SUPABASE_PUBLIC_URL)"
LOCAL_ANON_KEY="$(supabase_stack_env_val "${SB_DIR}/.env" ANON_KEY)"
LOCAL_SERVICE_KEY="$(supabase_stack_env_val "${SB_DIR}/.env" SERVICE_ROLE_KEY)"
LOCAL_PGPASS="$(supabase_stack_env_val "${SB_DIR}/.env" POSTGRES_PASSWORD)"
for v in LOCAL_PUBLIC_URL LOCAL_ANON_KEY LOCAL_SERVICE_KEY LOCAL_PGPASS; do
  if [[ -z "${!v}" ]]; then echo "error: ${v} empty in ${SB_DIR}/.env — stack env incomplete" >&2; exit 1; fi
done
echo "    preflight OK — local stack env present (${LOCAL_PUBLIC_URL})"
if [[ "${MIGRATE_PREFLIGHT_ONLY:-0}" == "1" ]]; then exit 0; fi

# psql runners for the lib. Hosted client must be >= hosted server version —
# use a modern client container. --network host: plain egress, no bridge DNS quirks.
migrate_src_psql() {
  docker run --rm -i --network host -e HOSTED_DB_URL "${MIGRATE_PG_IMAGE}" \
    sh -c 'exec psql "$HOSTED_DB_URL" -v ON_ERROR_STOP=1 "$@"' -- "$@"
}
migrate_dst_psql() {
  docker compose -f "${SB_DIR}/docker-compose.yml" --env-file "${SB_DIR}/.env" \
    exec -T -e PGPASSWORD="${LOCAL_PGPASS}" db \
    psql -h 127.0.0.1 -U supabase_admin -d postgres -v ON_ERROR_STOP=1 "$@" </dev/stdin
}

echo "==> migrate 2: connectivity checks"
SRC_VER="$(migrate_src_psql -tAc 'show server_version' </dev/null)" \
  || { echo "error: cannot reach hosted DB — check HOSTED_DB_URL (use the Session pooler string)" >&2; exit 1; }
echo "    hosted postgres ${SRC_VER} ✓"
migrate_dst_psql -tAc 'select 1' </dev/null >/dev/null \
  || { echo "error: local supabase db container not reachable" >&2; exit 1; }
LEDGER="$(migrate_dst_psql -tAc "select count(*) from public._ollie_core_migrations" </dev/null || echo 0)"
if [[ "${LEDGER}" -lt 6 ]]; then
  echo "error: ollie-core migrations not fully applied locally (ledger=${LEDGER}) — re-run 11-install-supabase.sh --deploy" >&2
  exit 1
fi
echo "    local stack ledger ${LEDGER} migrations ✓"

echo "==> migrate 3: backups"
TS="$(date +%Y%m%d-%H%M%S)"
for f in "${STACK_ENV}" "${ORCH_ENV}"; do
  if [[ -f "$f" ]]; then cp "$f" "${f}.bak-migrate-${TS}"; echo "    ${f}.bak-migrate-${TS}"; fi
done

echo "==> migrate 4: copy tables (truncate-first, UUID-preserving)"
for t in "${AUTH_TABLES[@]}"; do sb_copy_table auth "$t"; sb_fix_sequences auth "$t"; done
for t in "${PUBLIC_TABLES[@]}"; do sb_copy_table public "$t"; sb_fix_sequences public "$t"; done

echo "==> migrate 5: sync storage bucket ${BUCKET}"
sb_sync_bucket "${HOSTED_SUPABASE_URL}" "${HOSTED_SERVICE_ROLE_KEY}" \
  "http://127.0.0.1:8000" "${LOCAL_SERVICE_KEY}" "${BUCKET}"

echo "==> migrate 6: repoint dashboard + orchestrator at the local stack"
if supabase_write_stack_dashboard_env "${STACK_ENV}" "${LOCAL_PUBLIC_URL}" "${LOCAL_ANON_KEY}"; then
  docker compose -f "$(dirname "${STACK_ENV}")/docker-compose.yml" up -d dashboard
else
  echo "error: ${STACK_ENV} missing — is the hermes stack installed?" >&2; exit 1
fi
supabase_write_orch_env "http://127.0.0.1:8000" "${LOCAL_SERVICE_KEY}" "${LOCAL_PUBLIC_URL%/}/auth/v1"
systemctl --user restart ollie-orchestrator
set +e
for i in $(seq 1 10); do
  HEALTH=$(curl -s -m 5 http://localhost:9123/healthz || echo "")
  [[ "${HEALTH}" == *'"status":"ok"'* ]] && break
  sleep 2
done
set -e
if [[ "${HEALTH:-}" != *'"status":"ok"'* ]]; then
  echo "error: orchestrator did not come back healthy — rollback the repoint: restore ${ORCH_ENV}.bak-migrate-${TS} and ${STACK_ENV}.bak-migrate-${TS}, then docker compose -f $(dirname "${STACK_ENV}")/docker-compose.yml up -d dashboard && systemctl --user restart ollie-orchestrator (full back-to-hosted rollback: runbook §8.6 / .bak-prehosted-*)" >&2
  exit 1
fi

echo "==> migrate 7: verify local schema serves migrated data"
PROBE="$(supabase_schema_probe_url "http://127.0.0.1:8000")"
CODE="$(curl -s -o /dev/null -w '%{http_code}' -m 15 \
  -H "apikey: ${LOCAL_SERVICE_KEY}" -H "Authorization: Bearer ${LOCAL_SERVICE_KEY}" "${PROBE}" || echo 000)"
[[ "${CODE}" == "200" ]] || { echo "error: local schema probe HTTP ${CODE}" >&2; exit 1; }
ROLES_N="$(migrate_dst_psql -tAc 'select count(*) from public.user_roles' </dev/null)"
echo "    local user_roles rows: ${ROLES_N}"

echo
echo "✓ migration complete — box now runs on the local stack."
echo "  Next (operator):"
echo "   1. Browser Google login at the dashboard (existing users keep their UUIDs; everyone re-logs-in once)."
echo "   2. OPERATOR_EMAIL=<you> bash ~/ollie-hermes-install/scripts/check-box-config.sh"
echo "   3. If this box is enrolled in Fleet: update the instance's Access tab to"
echo "      ${LOCAL_PUBLIC_URL} + the local anon/service keys, then Apply."
echo "   4. PAUSE (do not delete) the hosted project — 2-week soak per the runbook."
echo "  Rollback to HOSTED: use the .bak-prehosted-* files from runbook §8.2 step 0"
echo "  (~/hermes-stack/.env.bak-prehosted-<ts> and ~/.config/ollie-orchestrator/.env.bak-prehosted-<ts>)."
echo "  The .bak-migrate-${TS} files just written (${STACK_ENV}.bak-migrate-${TS} and"
echo "  ${ORCH_ENV}.bak-migrate-${TS}) capture post-deploy LOCAL values, not hosted —"
echo "  restoring them only undoes this migrate step's repoint, not the cutover."
