#!/usr/bin/env bash
# 11-install-supabase.sh — deploy/apply per-instance Supabase config to the
# orchestrator and verify the project is provision-ready.
#
# Run as: the service user (ollie by default)
# Idempotent: safe to re-run; same creds = no-op apart from the restart.
#
# Three modes:
#   (default, apply)  Input (stdin, KEY=VALUE lines — stdin so the secret
#                      never appears in argv):
#                        SUPABASE_URL=https://<ref>.supabase.co
#                        SUPABASE_SERVICE_ROLE_KEY=<service role key>
#   --verify-only      (no stdin; verify existing config, SKIP cleanly if none)
#   --deploy           Stand up the local self-hosted Supabase stack, apply
#                       ollie-core migrations, point the dashboard at it, then
#                       fall through to the same verify/apply tail below.
#                       Input (stdin, KEY=VALUE lines):
#                         SUPABASE_PUBLIC_URL=<https origin, required>
#                         SITE_URL=<https origin, required — browser-facing
#                           dashboard origin, e.g. https://ollie.jnow.io>
#                         GOOGLE_CLIENT_ID=<optional>
#                         GOOGLE_CLIENT_SECRET=<optional>
#                       Re-runs may omit any of these — unset values are
#                       carried forward from the existing ~/supabase-stack/.env.
#
# The project must already be provision-ready per
# docs/runbooks/supabase-ollie-core-provisioning.md (runbook SQL + JWT hook +
# Google provider) — UNLESS --deploy is used, which applies the ollie-core
# migrations itself. PostgREST cannot run DDL, so apply/verify modes VERIFY
# the schema — they do not create it.
#
# verify-only semantics are intentionally non-fatal: a --verify-only invocation
# (e.g. from the done-done gate) must never wedge an otherwise-healthy update.
# If the schema probe comes back non-200 in verify-only mode, that means
# Supabase is unreachable or not provision-ready — we print a WARNING and
# exit 0 rather than failing the caller. Step 3 (orchestrator restart +
# healthz) is skipped entirely in verify-only mode, since nothing changed and
# there is nothing to restart for. Apply mode is unchanged: a non-200 probe
# is a hard failure (exit 1) with the runbook pointer, and step 3 always runs
# after a successful apply. Deploy mode reuses apply's tail once the local
# stack is up and migrated.
set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  echo "error: run as the service user, not root" >&2
  exit 1
fi
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/lib/supabase-env.sh"
ORCH_ENV="${ORCH_ENV:-$HOME/.config/ollie-orchestrator/.env}"

MODE="apply"
case "${1:-}" in
  --verify-only) MODE="verify" ;;
  --deploy)      MODE="deploy" ;;
esac

SUPABASE_URL="" ; SUPABASE_SERVICE_ROLE_KEY=""

if [[ "${MODE}" == "deploy" ]]; then
  . "${SCRIPT_DIR}/lib/supabase-stack-env.sh"
  SB_DIR="${SB_DIR:-$HOME/supabase-stack}"
  TEMPLATES="${SCRIPT_DIR}/../templates/supabase"

  # stdin: SUPABASE_PUBLIC_URL + SITE_URL (required), GOOGLE_CLIENT_ID/SECRET (optional).
  SUPABASE_PUBLIC_URL="" ; SITE_URL="" ; GOOGLE_CLIENT_ID="" ; GOOGLE_CLIENT_SECRET=""
  while IFS='=' read -r k v || [[ -n "${k:-}" ]]; do
    case "${k}" in
      SUPABASE_PUBLIC_URL) SUPABASE_PUBLIC_URL="${v}" ;;
      SITE_URL) SITE_URL="${v}" ;;
      GOOGLE_CLIENT_ID) GOOGLE_CLIENT_ID="${v}" ;;
      GOOGLE_CLIENT_SECRET) GOOGLE_CLIENT_SECRET="${v}" ;;
    esac
  done
  # Re-runs may omit the URLs — carry them forward from the existing .env.
  [[ -z "${SUPABASE_PUBLIC_URL}" ]] && \
    SUPABASE_PUBLIC_URL="$(supabase_stack_env_val "${SB_DIR}/.env" SUPABASE_PUBLIC_URL)"
  [[ -z "${SITE_URL}" ]] && \
    SITE_URL="$(supabase_stack_env_val "${SB_DIR}/.env" SITE_URL)"
  supabase_validate_inputs "${SUPABASE_PUBLIC_URL}" "placeholder-key-not-validated-here" || exit 1
  supabase_validate_inputs "${SITE_URL}" "placeholder-key-not-validated-here" || exit 1

  echo "==> deploy 1: stage ${SB_DIR} (compose + env + kong)"
  mkdir -p "${SB_DIR}"
  cp "${TEMPLATES}/docker-compose.yml" "${SB_DIR}/docker-compose.yml"
  ENV_OLD=""
  if [[ -f "${SB_DIR}/.env" ]]; then ENV_OLD="$(mktemp)"; cp "${SB_DIR}/.env" "${ENV_OLD}"; fi
  export SUPABASE_PUBLIC_URL SITE_URL GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET
  render_supabase_stack_env "${SB_DIR}/.env" "${ENV_OLD}"
  [[ -n "${ENV_OLD}" ]] && rm -f "${ENV_OLD}"
  ANON_KEY="$(supabase_stack_env_val "${SB_DIR}/.env" ANON_KEY)"
  SERVICE_ROLE_KEY="$(supabase_stack_env_val "${SB_DIR}/.env" SERVICE_ROLE_KEY)"
  supabase_render_kong "${TEMPLATES}/kong.yml" "${SB_DIR}/kong.yml" \
    "${ANON_KEY}" "${SERVICE_ROLE_KEY}"

  echo "==> deploy 2: docker compose up -d"
  docker compose -f "${SB_DIR}/docker-compose.yml" --env-file "${SB_DIR}/.env" pull --quiet
  docker compose -f "${SB_DIR}/docker-compose.yml" --env-file "${SB_DIR}/.env" up -d

  echo "==> deploy 3: wait for auth healthy via kong"
  set +e
  for i in $(seq 1 30); do
    CODE="$(curl -s -o /dev/null -w '%{http_code}' -m 5 \
      -H "apikey: ${ANON_KEY}" http://127.0.0.1:8000/auth/v1/health)"
    [[ "${CODE}" == "200" ]] && break
    sleep 2
  done
  set -e
  if [[ "${CODE:-}" != "200" ]]; then
    echo "error: auth /health did not come up (last HTTP ${CODE:-none}) — check: docker compose -f ${SB_DIR}/docker-compose.yml logs auth kong" >&2
    exit 1
  fi
  echo "    auth /health → 200 ✓"

  echo "==> deploy 4: apply ollie-core migrations (idempotent)"
  for f in "${SCRIPT_DIR}/../supabase/ollie-core/"[0-9]*.sql; do
    echo "    psql < $(basename "$f")"
    docker compose -f "${SB_DIR}/docker-compose.yml" --env-file "${SB_DIR}/.env" \
      exec -T db psql -U postgres -d postgres -v ON_ERROR_STOP=1 < "$f"
  done

  echo "==> deploy 5: point the dashboard at the local stack"
  STACK_ENV="${STACK_ENV:-$HOME/hermes-stack/.env}"
  if supabase_write_stack_dashboard_env "${STACK_ENV}" "${SUPABASE_PUBLIC_URL}" "${ANON_KEY}"; then
    docker compose -f "$(dirname "${STACK_ENV}")/docker-compose.yml" up -d dashboard
  else
    echo "    note: ${STACK_ENV} missing — run 06-install-stack.sh, then re-run --deploy"
  fi

  # Fall through to the shared verify/apply tail with the local creds.
  SUPABASE_URL="${SUPABASE_PUBLIC_URL}"
  SUPABASE_SERVICE_ROLE_KEY="${SERVICE_ROLE_KEY}"
  MODE="apply"
  echo
  echo "    local stack deployed — keys for Fleet (store via provision flow):"
  echo "    SUPABASE_URL=${SUPABASE_URL}"
  echo "    SITE_URL=${SITE_URL}"
  echo "    SUPABASE_ANON_KEY=${ANON_KEY}"
  echo "    SERVICE_ROLE_KEY=${SERVICE_ROLE_KEY}"
fi

if [[ "${MODE}" == "apply" && -z "${SUPABASE_URL}" ]]; then
  while IFS='=' read -r k v || [[ -n "${k:-}" ]]; do
    case "${k}" in
      SUPABASE_URL) SUPABASE_URL="${v}" ;;
      SUPABASE_SERVICE_ROLE_KEY) SUPABASE_SERVICE_ROLE_KEY="${v}" ;;
    esac
  done
  supabase_validate_inputs "${SUPABASE_URL}" "${SUPABASE_SERVICE_ROLE_KEY}"
elif [[ "${MODE}" == "verify" ]]; then
  SUPABASE_URL="$(grep '^SUPABASE_URL=' "${ORCH_ENV}" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
  SUPABASE_SERVICE_ROLE_KEY="$(grep '^SUPABASE_SERVICE_ROLE_KEY=' "${ORCH_ENV}" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
  if [[ -z "${SUPABASE_URL}" || -z "${SUPABASE_SERVICE_ROLE_KEY}" ]]; then
    echo "SKIP: no Supabase config on this box (nothing to verify)"
    exit 0
  fi
fi

echo "==> step 1: verify the Supabase project is provision-ready"
PROBE_URL="$(supabase_schema_probe_url "${SUPABASE_URL}")"
CODE="$(curl -s -o /dev/null -w '%{http_code}' -m 15 \
  -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
  "${PROBE_URL}" || echo "000")"
if [[ "${CODE}" != "200" ]]; then
  if [[ "${MODE}" == "verify" ]]; then
    echo "WARNING: schema probe returned HTTP ${CODE} — Supabase unreachable or not provision-ready; continuing (verify-only is non-fatal)"
    exit 0
  fi
  echo "error: schema probe returned HTTP ${CODE} — the project is not provision-ready." >&2
  echo "       Run the runbook first: docs/runbooks/supabase-ollie-core-provisioning.md" >&2
  echo "       (SQL Editor: supabase/ollie-core/0001..0006 in order, then register the" >&2
  echo "        custom_access_token_hook and enable the Google provider.)" >&2
  exit 1
fi
echo "    schema probe → 200 ✓"

if [[ "${MODE}" == "apply" ]]; then
  echo "==> step 2: write SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY to orchestrator .env"
  supabase_write_orch_env "${SUPABASE_URL}" "${SUPABASE_SERVICE_ROLE_KEY}"

  echo "==> step 3: restart orchestrator + verify"
  systemctl --user restart ollie-orchestrator
  set +e
  for i in $(seq 1 10); do
    HEALTH=$(curl -s -m 5 http://localhost:9123/healthz || echo "")
    [[ "${HEALTH}" == *'"status":"ok"'* ]] && break
    sleep 2
  done
  set -e
  if [[ "${HEALTH:-}" != *'"status":"ok"'* ]]; then
    echo "error: orchestrator did not come back healthy after restart" >&2
    exit 1
  fi
  echo
  echo "✓ Supabase config applied + verified (orchestrator healthy)."
else
  echo
  echo "✓ Supabase config verified (verify-only, no changes made — orchestrator not restarted)."
fi
