#!/usr/bin/env bash
# 11-install-supabase.sh — apply per-instance Supabase config to the orchestrator
# and verify the project is provision-ready.
#
# Run as: the service user (ollie by default)
# Idempotent: safe to re-run; same creds = no-op apart from the restart.
#
# Input (stdin, KEY=VALUE lines — stdin so the secret never appears in argv):
#   SUPABASE_URL=https://<ref>.supabase.co
#   SUPABASE_SERVICE_ROLE_KEY=<service role key>
# Or: --verify-only  (no stdin; verify existing config, SKIP cleanly if none)
#
# The project must already be provision-ready per
# docs/runbooks/supabase-ollie-core-provisioning.md (runbook SQL + JWT hook +
# Google provider). PostgREST cannot run DDL, so this script VERIFIES the
# schema — it does not create it.
#
# verify-only semantics are intentionally non-fatal: a --verify-only invocation
# (e.g. from the done-done gate) must never wedge an otherwise-healthy update.
# If the schema probe comes back non-200 in verify-only mode, that means
# Supabase is unreachable or not provision-ready — we print a WARNING and
# exit 0 rather than failing the caller. Step 3 (orchestrator restart +
# healthz) is skipped entirely in verify-only mode, since nothing changed and
# there is nothing to restart for. Apply mode is unchanged: a non-200 probe
# is a hard failure (exit 1) with the runbook pointer, and step 3 always runs
# after a successful apply.
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
[[ "${1:-}" == "--verify-only" ]] && MODE="verify"

if [[ "${MODE}" == "apply" ]]; then
  SUPABASE_URL="" ; SUPABASE_SERVICE_ROLE_KEY=""
  while IFS='=' read -r k v || [[ -n "${k:-}" ]]; do
    case "${k}" in
      SUPABASE_URL) SUPABASE_URL="${v}" ;;
      SUPABASE_SERVICE_ROLE_KEY) SUPABASE_SERVICE_ROLE_KEY="${v}" ;;
    esac
  done
  supabase_validate_inputs "${SUPABASE_URL}" "${SUPABASE_SERVICE_ROLE_KEY}"
else
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
