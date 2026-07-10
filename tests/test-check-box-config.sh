#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/assert.sh"
GATE="$HERE/../scripts/check-box-config.sh"

setup_healthy() {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/units/hermes-dashboard.service.d" "$d/profiles"
  printf 'API_SERVER_PORT=8642\n' > "$d/hermes.env"
  printf '[Service]\nExecStart=hermes dashboard --host 127.0.0.1 --port 9119\n' > "$d/units/hermes-dashboard.service"
  cat > "$d/orch.env" <<'EOF'
INSTANCE_ID=inst-1
SUPABASE_URL=https://abc.supabase.co
SUPABASE_SERVICE_ROLE_KEY=sk
HERMES_DASHBOARD_TOKEN=tok123
HERMES_GATEWAY_URLS={"default": "http://127.0.0.1:8642"}
HERMES_DASHBOARD_URLS={"default": "http://127.0.0.1:9119"}
EOF
  printf '[Service]\nEnvironment=HERMES_DASHBOARD_SESSION_TOKEN=tok123' > "$d/units/hermes-dashboard.service.d/session-token.conf"
  printf 'SUPABASE_URL=https://abc.supabase.co\nSUPABASE_ANON_KEY=anon\n' > "$d/stack.env"
  echo "$d"
}

run_gate() {
  local d="$1"
  ORCH_ENV="$d/orch.env" STACK_ENV_FILE="$d/stack.env" SYSTEMD_USER_DIR="$d/units" \
    HERMES_ENV_FILE="$d/hermes.env" PROFILES_DIR="$d/profiles" \
    OPERATOR_EMAIL=jb@example.com CHECK_SKIP_LIVE=1 bash "$GATE"
}

test_healthy_box_passes() {
  local d rc; d="$(setup_healthy)"
  run_gate "$d" >/dev/null; rc=$?
  assert_eq "healthy exit 0" "$rc" "0"
}

test_each_gap_flagged() {
  local d rc out
  d="$(setup_healthy)"; sed -i '/^INSTANCE_ID=/d' "$d/orch.env"
  out="$(run_gate "$d")"; rc=$?
  assert_eq "missing INSTANCE_ID exit 1" "$rc" "1"
  assert_eq "INSTANCE_ID named" "$(echo "$out" | grep -c 'FAIL: INSTANCE_ID')" "1"

  d="$(setup_healthy)"; sed -i 's|^HERMES_GATEWAY_URLS=.*|HERMES_GATEWAY_URLS={}|' "$d/orch.env"
  out="$(run_gate "$d")"; rc=$?
  assert_eq "incomplete map exit 1" "$rc" "1"
  assert_eq "map gap named" "$(echo "$out" | grep -c 'FAIL: HERMES_GATEWAY_URLS')" "1"

  d="$(setup_healthy)"; printf 'wrong' > "$d/units/hermes-dashboard.service.d/session-token.conf"
  out="$(run_gate "$d")"; rc=$?
  assert_eq "token mismatch exit 1" "$rc" "1"
  assert_eq "drop-in gap named" "$(echo "$out" | grep -c 'FAIL: session-token')" "1"

  d="$(setup_healthy)"; sed -i 's|--host 127.0.0.1|--host 0.0.0.0|' "$d/units/hermes-dashboard.service"
  out="$(run_gate "$d")"; rc=$?
  assert_eq "0.0.0.0 unit exit 1" "$rc" "1"

  d="$(setup_healthy)"; sed -i '/^SUPABASE_ANON_KEY=/d' "$d/stack.env"
  out="$(run_gate "$d")"; rc=$?
  assert_eq "stack anon gap exit 1" "$rc" "1"
}

test_detection_failure_fails_loudly() {
  local d rc out
  d="$(setup_healthy)"
  # Point HERMES_ENV_FILE at nonexistent path to trigger detection failure
  out="$(ORCH_ENV="$d/orch.env" STACK_ENV_FILE="$d/stack.env" SYSTEMD_USER_DIR="$d/units" \
    HERMES_ENV_FILE="/nonexistent/path/.env" PROFILES_DIR="$d/profiles" \
    OPERATOR_EMAIL=jb@example.com CHECK_SKIP_LIVE=1 bash "$GATE")"; rc=$?
  assert_eq "detection failure exit 1" "$rc" "1"
  assert_eq "detection error mentioned" "$(echo "$out" | grep -c 'could not detect agents')" "1"
  # Both map keys should emit coverage-unverifiable FAILs
  assert_eq "HERMES_GATEWAY_URLS unverifiable" "$(echo "$out" | grep -c 'FAIL: HERMES_GATEWAY_URLS coverage unverifiable')" "1"
  assert_eq "HERMES_DASHBOARD_URLS unverifiable" "$(echo "$out" | grep -c 'FAIL: HERMES_DASHBOARD_URLS coverage unverifiable')" "1"
}

test_token_dot_exact_match() {
  local d rc out TOKEN
  d="$(setup_healthy)"
  TOKEN="tok.123"
  # Update orch.env with token containing dot
  sed -i 's/HERMES_DASHBOARD_TOKEN=.*/HERMES_DASHBOARD_TOKEN='"$TOKEN"'/' "$d/orch.env"
  # Update drop-in to match
  printf '[Service]\nEnvironment=HERMES_DASHBOARD_SESSION_TOKEN=%s' "$TOKEN" > "$d/units/hermes-dashboard.service.d/session-token.conf"
  # Should pass with exact token match
  out="$(run_gate "$d")"; rc=$?
  assert_eq "token with dot match exit 0" "$rc" "0"

  # Now make drop-in differ by one char at dot position
  d="$(setup_healthy)"
  sed -i 's/HERMES_DASHBOARD_TOKEN=.*/HERMES_DASHBOARD_TOKEN='"$TOKEN"'/' "$d/orch.env"
  printf '[Service]\nEnvironment=HERMES_DASHBOARD_SESSION_TOKEN=tokX123' > "$d/units/hermes-dashboard.service.d/session-token.conf"
  # Should fail (old regex match would have false-passed)
  out="$(run_gate "$d")"; rc=$?
  assert_eq "token with dot mismatch exit 1" "$rc" "1"
  assert_eq "token mismatch error" "$(echo "$out" | grep -c 'FAIL: session-token')" "1"
}

test_healthy_box_passes
test_each_gap_flagged
test_detection_failure_fails_loudly
test_token_dot_exact_match
finish
