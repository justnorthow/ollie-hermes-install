#!/usr/bin/env bash
# check-box-config.sh — "done done" parity gate. Report-only: prints PASS/FAIL
# per check, exit 0 when the box has the full healthy config set, exit 1 with
# GAPS: <n> otherwise. Never mutates anything.
#
# Run as: the service user.  Env: OPERATOR_EMAIL (required unless CHECK_SKIP_LIVE=1),
# CHECK_SKIP_LIVE=1 (config-file checks only), plus the usual overridable roots.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/lib/detect-agents.sh"

ORCH_ENV="${ORCH_ENV:-$HOME/.config/ollie-orchestrator/.env}"
STACK_ENV_FILE="${STACK_ENV_FILE:-$HOME/hermes-stack/.env}"
UNIT_DIR="${SYSTEMD_USER_DIR:-$HOME/.config/systemd/user}"
SKIP_LIVE="${CHECK_SKIP_LIVE:-0}"

gaps=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; gaps=$((gaps+1)); }

orch_val() { grep "^$1=" "${ORCH_ENV}" 2>/dev/null | tail -1 | cut -d= -f2-; }
stack_val() { grep "^$1=" "${STACK_ENV_FILE}" 2>/dev/null | tail -1 | cut -d= -f2-; }

# 1. orchestrator .env required keys
for k in INSTANCE_ID SUPABASE_URL SUPABASE_SERVICE_ROLE_KEY HERMES_DASHBOARD_TOKEN; do
  if [[ -n "$(orch_val "$k")" ]]; then pass "$k set"; else fail "$k missing/empty in orchestrator .env"; fi
done

# 2. proxy maps cover every detected agent
DETECTED="$(detect_agents 2>/dev/null || echo '[]')"
for k in HERMES_GATEWAY_URLS HERMES_DASHBOARD_URLS; do
  MAP="$(orch_val "$k")"
  if MISSING="$(DETECTED="${DETECTED}" MAP="${MAP}" python3 - <<'PY'
import json, os, sys
try:
    ids = {a["id"] for a in json.loads(os.environ["DETECTED"])}
    m = json.loads(os.environ["MAP"] or "null")
    missing = sorted(ids - set(m.keys())) if isinstance(m, dict) else sorted(ids)
except Exception:
    missing = ["<unparseable>"]
print(",".join(missing)); sys.exit(1 if missing else 0)
PY
)"; then pass "$k covers all agents"; else fail "$k incomplete (missing: ${MISSING})"; fi
done

# 3. session-token drop-in per dashboard unit, matching the orchestrator token
TOKEN="$(orch_val HERMES_DASHBOARD_TOKEN)"
shopt -s nullglob
for unit in "${UNIT_DIR}"/hermes-dashboard*.service; do
  name="$(basename "${unit}")"
  conf="${UNIT_DIR}/${name}.d/session-token.conf"
  if [[ -f "${conf}" ]] && grep -q "HERMES_DASHBOARD_SESSION_TOKEN=${TOKEN}$" "${conf}"; then
    pass "session-token drop-in matches (${name})"
  else
    fail "session-token drop-in missing/mismatched (${name})"
  fi
  if grep -qE '^ExecStart=.*--host 0\.0\.0\.0' "${unit}"; then
    fail "stale --host 0.0.0.0 in ${name}"
  else
    pass "loopback bind (${name})"
  fi
done

# 4. stack .env login-gate keys
for k in SUPABASE_URL SUPABASE_ANON_KEY; do
  if [[ -n "$(stack_val "$k")" ]]; then pass "stack ${k} set"; else fail "stack ${k} missing (login gate will render empty)"; fi
done

# 5. live checks
if [[ "${SKIP_LIVE}" != "1" ]]; then
  for u in ollie-orchestrator hermes-gateway hermes-dashboard; do
    if systemctl --user is-active --quiet "${u}"; then pass "${u} active"; else fail "${u} not active"; fi
  done
  for c in cortex ollie-dashboard; do
    if docker ps --format '{{.Names}}' | grep -qx "${c}"; then pass "container ${c} running"; else fail "container ${c} not running"; fi
  done
  if [[ -z "${OPERATOR_EMAIL:-}" ]]; then
    fail "OPERATOR_EMAIL not provided — cannot run whoami probe"
  else
    UID_OUT="$(python3 "${SCRIPT_DIR}/lib/seed-operator-role.py" --email "${OPERATOR_EMAIL}" --instance-id unused --print-uid 2>/dev/null || true)"
    WHOAMI="$(curl -s -m 10 -H "X-Auth-User-Id: ${UID_OUT}" http://127.0.0.1:9123/v1/whoami || echo "")"
    if [[ -n "${UID_OUT}" ]] && REACH="$(WHOAMI="${WHOAMI}" python3 - <<'PY'
import json, os, sys
try:
    w = json.loads(os.environ["WHOAMI"])
    ok = bool(w.get("tier")) and bool(w.get("reachableAgentIds"))
except Exception:
    ok = False
sys.exit(0 if ok else 1)
PY
)"; then
      pass "whoami: operator has tier + reachable agents"
    else
      fail "whoami probe failed (uid='${UID_OUT}', response='${WHOAMI:0:120}')"
    fi
  fi
fi

echo
if [[ ${gaps} -eq 0 ]]; then
  echo "OK: box config is done-done"
  exit 0
fi
echo "GAPS: ${gaps}"
exit 1
