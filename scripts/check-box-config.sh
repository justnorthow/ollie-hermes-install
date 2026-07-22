#!/usr/bin/env bash
# check-box-config.sh — "done done" parity gate. Report-only: prints PASS/FAIL
# per check, exit 0 when the box has the full healthy config set, exit 1 with
# GAPS: <n> otherwise. Never mutates anything.
#
# Run as: the service user.  Env: OPERATOR_EMAIL (required unless CHECK_SKIP_LIVE=1),
# CHECK_SKIP_LIVE=1 (config-file checks only), ALLOW_PUBLIC_BIND=1 (allow stack
# DASHBOARD_BIND=0.0.0.0 to PASS instead of FAIL — Fleet sets this for direct-mode
# boxes, where a public :3000 bind is the chosen access mode, not an accident),
# plus the usual overridable roots.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/lib/detect-agents.sh"

ORCH_ENV="${ORCH_ENV:-$HOME/.config/ollie-orchestrator/.env}"
STACK_ENV_FILE="${STACK_ENV_FILE:-$HOME/hermes-stack/.env}"
UNIT_DIR="${SYSTEMD_USER_DIR:-$HOME/.config/systemd/user}"
SKIP_LIVE="${CHECK_SKIP_LIVE:-0}"
PROFILES_DIR="${PROFILES_DIR:-$HOME/.hermes/profiles}"
MANIFEST_DIR="${MANIFEST_DIR:-${SCRIPT_DIR}/../apps}"
APPS_DIR="${APPS_DIR:-$HOME/apps}"

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
DETECTED="$(detect_agents 2>/dev/null || true)"
if ! DETECTED_OK="$(DETECTED="${DETECTED}" python3 - <<'PY'
import json, os, sys
try:
    agents = json.loads(os.environ.get("DETECTED") or "null")
    ok = isinstance(agents, list) and len(agents) >= 1 and all("id" in a for a in agents)
except Exception:
    ok = False
sys.exit(0 if ok else 1)
PY
)"; then
  fail "could not detect agents (hermes env/profiles unreadable) — proxy-map coverage cannot be verified"
  DETECTED=""
fi

for k in HERMES_GATEWAY_URLS HERMES_DASHBOARD_URLS; do
  if [[ -z "${DETECTED}" ]]; then
    fail "$k coverage unverifiable (agent detection failed)"
  else
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
  fi
done

# 3. session-token drop-in per dashboard unit, matching the orchestrator token
TOKEN="$(orch_val HERMES_DASHBOARD_TOKEN)"
shopt -s nullglob
for unit in "${UNIT_DIR}"/hermes-dashboard*.service; do
  name="$(basename "${unit}")"
  conf="${UNIT_DIR}/${name}.d/session-token.conf"
  if [[ -f "${conf}" ]] && [[ "$(cat "${conf}")" == "$(printf '[Service]\nEnvironment=HERMES_DASHBOARD_SESSION_TOKEN=%s' "${TOKEN}")" ]]; then
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

# 4b. stack DASHBOARD_BIND — public bind is only OK when it's a deliberate choice.
# ALLOW_PUBLIC_BIND=1 is passed by Fleet's provisioner for direct-mode boxes,
# where a public :3000 bind is the chosen access mode.
DASHBOARD_BIND_VAL="$(stack_val DASHBOARD_BIND)"
if [[ -z "${DASHBOARD_BIND_VAL}" || "${DASHBOARD_BIND_VAL}" == "127.0.0.1" ]]; then
  pass "stack DASHBOARD_BIND loopback/unset"
elif [[ "${DASHBOARD_BIND_VAL}" == "0.0.0.0" && "${ALLOW_PUBLIC_BIND:-0}" != "1" ]]; then
  fail "stack DASHBOARD_BIND=0.0.0.0 (public :3000 bind)"
else
  pass "stack DASHBOARD_BIND=${DASHBOARD_BIND_VAL} (public bind allowed via ALLOW_PUBLIC_BIND=1)"
fi

# 5. live checks
if [[ "${SKIP_LIVE}" != "1" ]]; then
  for u in ollie-orchestrator hermes-gateway hermes-dashboard; do
    if systemctl --user is-active --quiet "${u}"; then pass "${u} active"; else fail "${u} not active"; fi
  done
  for c in cortex ollie-dashboard; do
    if docker ps --format '{{.Names}}' | grep -qx "${c}"; then pass "container ${c} running"; else fail "container ${c} not running"; fi
  done
  # whoami sits behind the orchestrator's bearer auth (require_bearer) — the
  # X-Auth-User-Id header alone gets a 401 {"detail":"unauthorized"}.
  ORCH_KEY="$(orch_val ORCHESTRATOR_KEY)"
  if [[ -z "${OPERATOR_EMAIL:-}" ]]; then
    fail "OPERATOR_EMAIL not provided — cannot run whoami probe"
  elif [[ -z "${ORCH_KEY}" ]]; then
    fail "ORCHESTRATOR_KEY missing/empty in orchestrator .env — cannot run whoami probe"
  else
    UID_OUT="$(python3 "${SCRIPT_DIR}/lib/seed-operator-role.py" --email "${OPERATOR_EMAIL}" --instance-id unused --print-uid 2>/dev/null || true)"
    WHOAMI="$(curl -s -m 10 -H "Authorization: Bearer ${ORCH_KEY}" -H "X-Auth-User-Id: ${UID_OUT}" http://127.0.0.1:9123/v1/whoami || echo "")"
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

# 6. agent apps — manifest parity for installed profiles (apps/<profile>.json,
# Task 5). A profile is "installed" when ~/.hermes/profiles/<profile> exists;
# manifests whose profile is NOT installed emit no checks at all. mf() mirrors
# scripts/24-install-agent-apps.sh's manifest-reader style: the manifest path
# is embedded directly in the python source (like 24's ${MANIFEST}), and only
# fixed literal jq-path expressions are eval'd — never manifest-derived data.
# native_path: passes through unchanged on real POSIX boxes (cygpath doesn't
# exist there); on MSYS bash + a native Windows python3.exe, rewrites a POSIX
# path to drive-letter form so open() embedded inside a python -c string
# argument resolves it (MSYS only auto-rewrites paths that are argv tokens).
native_path() { cygpath -m "$1" 2>/dev/null || printf '%s' "$1"; }
mf() { # MANIFEST JQPATH — read a manifest value
  local m; m="$(native_path "$1")"
  python3 -c "import json,sys; d=json.load(open('${m}')); print(eval('d'+sys.argv[1]))" "$2"
}
for manifest in "${MANIFEST_DIR}"/*.json; do
  [[ -f "${manifest}" ]] || continue
  manifest_native="$(native_path "${manifest}")"
  # Beyond parsing: require the shape every check below assumes (profile is
  # a string, apps is a list, each app has name/server/app_port/health_path)
  # — valid-but-wrong-shape JSON must fail loud here instead of silently
  # emitting zero checks (a false done-done).
  if ! python3 -c "
import json, sys
d = json.load(open('${manifest_native}'))
assert isinstance(d.get('profile'), str) and isinstance(d.get('apps'), list)
[(a['name'], a['server']['app_port'], a['server']['health_path']) for a in d['apps']]
" >/dev/null 2>&1; then
    fail "agent apps: unreadable manifest $(basename "${manifest}")"
    continue
  fi
  profile="$(mf "${manifest}" "['profile']")"
  if [[ -z "${profile}" ]]; then
    fail "agent apps: unreadable manifest $(basename "${manifest}")"
    continue
  fi
  [[ -d "${PROFILES_DIR}/${profile}" ]] || continue
  app_count="$(mf "${manifest}" "['apps'].__len__()")"
  for i in $(seq 0 $((app_count-1))); do
    name="$(mf "${manifest}" "['apps'][${i}]['name']")"
    env_file="${APPS_DIR}/${name}/.env"
    if [[ ! -f "${env_file}" ]]; then
      fail "agent app ${name}: .env missing (${env_file})"
      continue
    fi
    pass "agent app ${name}: .env present"
    if [[ "${SKIP_LIVE}" != "1" ]]; then
      if docker ps --format '{{.Names}}' | grep -q "^${name}-app"; then
        pass "agent app ${name}: container running"
      else
        fail "agent app ${name}: no container named ${name}-app*"
      fi
      app_port="$(mf "${manifest}" "['apps'][${i}]['server']['app_port']")"
      health_path="$(mf "${manifest}" "['apps'][${i}]['server']['health_path']")"
      if curl -fsS -m 10 "127.0.0.1:${app_port}${health_path}" >/dev/null 2>&1; then
        pass "agent app ${name}: health check ok"
      else
        fail "agent app ${name}: health check failed (127.0.0.1:${app_port}${health_path})"
      fi
    fi
  done
done

echo
if [[ ${gaps} -eq 0 ]]; then
  echo "OK: box config is done-done"
  exit 0
fi
echo "GAPS: ${gaps}"
exit 1
