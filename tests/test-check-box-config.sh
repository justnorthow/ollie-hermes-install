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

test_dashboard_bind_gate() {
  local d rc out

  # 0.0.0.0 with no ALLOW_PUBLIC_BIND -> fail, named FAIL
  d="$(setup_healthy)"; printf 'DASHBOARD_BIND=0.0.0.0\n' >> "$d/stack.env"
  out="$(run_gate "$d")"; rc=$?
  assert_eq "DASHBOARD_BIND=0.0.0.0 exit 1" "$rc" "1"
  assert_eq "DASHBOARD_BIND=0.0.0.0 named FAIL" \
    "$(echo "$out" | grep -c 'FAIL: stack DASHBOARD_BIND=0.0.0.0 (public :3000 bind)')" "1"

  # 0.0.0.0 with ALLOW_PUBLIC_BIND=1 -> passes
  d="$(setup_healthy)"; printf 'DASHBOARD_BIND=0.0.0.0\n' >> "$d/stack.env"
  out="$(ORCH_ENV="$d/orch.env" STACK_ENV_FILE="$d/stack.env" SYSTEMD_USER_DIR="$d/units" \
    HERMES_ENV_FILE="$d/hermes.env" PROFILES_DIR="$d/profiles" \
    OPERATOR_EMAIL=jb@example.com CHECK_SKIP_LIVE=1 ALLOW_PUBLIC_BIND=1 bash "$GATE")"; rc=$?
  assert_eq "DASHBOARD_BIND=0.0.0.0 + ALLOW_PUBLIC_BIND=1 exit 0" "$rc" "0"

  # 127.0.0.1 -> passes
  d="$(setup_healthy)"; printf 'DASHBOARD_BIND=127.0.0.1\n' >> "$d/stack.env"
  out="$(run_gate "$d")"; rc=$?
  assert_eq "DASHBOARD_BIND=127.0.0.1 exit 0" "$rc" "0"

  # absent -> passes
  d="$(setup_healthy)"
  out="$(run_gate "$d")"; rc=$?
  assert_eq "DASHBOARD_BIND absent exit 0" "$rc" "0"
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

test_agent_apps_gate() {
  local d rc out manifest_dir

  # ---- fixture manifest (mirrors tests/test-24-install-agent-apps.sh) ----
  # 24's mf()-style python3 -c embeds the manifest path directly in the
  # python source string. On MSYS bash + a native Windows python3.exe, MSYS
  # only rewrites POSIX paths that are argv tokens, not ones embedded inside
  # a larger string argument — so a plain mktemp path 404s from python3's
  # perspective even though bash can see it fine. Use a Windows-native
  # (drive-letter, forward-slash) path for the manifest dir; harmless no-op
  # on real POSIX boxes where cygpath doesn't exist.
  d="$(setup_healthy)"
  mkdir -p "$d/apps" "$d/manifests"
  manifest_dir="$(cygpath -m "$d/manifests" 2>/dev/null || printf '%s' "$d/manifests")"
  cat > "$d/manifests/real-estate.json" <<'JSON'
{
  "profile": "real-estate",
  "apps": [
    {
      "name": "popbys",
      "stack": { "kong_port": 8030, "email_enabled": "false" },
      "server": { "app_port": 8130, "container_port": 8080, "health_path": "/api/health" }
    }
  ]
}
JSON

  # (a) profile installed, manifest present, app .env missing -> FAIL + GAPS>=1
  mkdir -p "$d/profiles/real-estate"
  out="$(MANIFEST_DIR="$manifest_dir" APPS_DIR="$d/apps" \
    ORCH_ENV="$d/orch.env" STACK_ENV_FILE="$d/stack.env" SYSTEMD_USER_DIR="$d/units" \
    HERMES_ENV_FILE="$d/hermes.env" PROFILES_DIR="$d/profiles" \
    OPERATOR_EMAIL=jb@example.com CHECK_SKIP_LIVE=1 bash "$GATE")"; rc=$?
  assert_eq "missing app .env exit 1" "$rc" "1"
  assert_eq "missing app .env named FAIL" \
    "$(echo "$out" | grep -c 'FAIL: agent app popbys')" "1"

  # (b) app .env present + CHECK_SKIP_LIVE=1 -> PASS, healthy overall
  mkdir -p "$d/apps/popbys"; : > "$d/apps/popbys/.env"
  out="$(MANIFEST_DIR="$manifest_dir" APPS_DIR="$d/apps" \
    ORCH_ENV="$d/orch.env" STACK_ENV_FILE="$d/stack.env" SYSTEMD_USER_DIR="$d/units" \
    HERMES_ENV_FILE="$d/hermes.env" PROFILES_DIR="$d/profiles" \
    OPERATOR_EMAIL=jb@example.com CHECK_SKIP_LIVE=1 bash "$GATE")"; rc=$?
  assert_eq "app .env present + skip-live exit 0" "$rc" "0"
  assert_eq "app .env present named PASS" \
    "$(echo "$out" | grep -c 'PASS: agent app popbys: .env present')" "1"

  # (c) profile NOT installed (no ~/.hermes/profiles/<profile> dir) -> no
  # agent-apps check lines emitted at all, even though the manifest exists
  # and the .env is missing.
  d="$(setup_healthy)"
  mkdir -p "$d/apps" "$d/manifests"
  manifest_dir="$(cygpath -m "$d/manifests" 2>/dev/null || printf '%s' "$d/manifests")"
  cat > "$d/manifests/real-estate.json" <<'JSON'
{
  "profile": "real-estate",
  "apps": [
    {
      "name": "popbys",
      "stack": { "kong_port": 8030, "email_enabled": "false" },
      "server": { "app_port": 8130, "container_port": 8080, "health_path": "/api/health" }
    }
  ]
}
JSON
  out="$(MANIFEST_DIR="$manifest_dir" APPS_DIR="$d/apps" \
    ORCH_ENV="$d/orch.env" STACK_ENV_FILE="$d/stack.env" SYSTEMD_USER_DIR="$d/units" \
    HERMES_ENV_FILE="$d/hermes.env" PROFILES_DIR="$d/profiles" \
    OPERATOR_EMAIL=jb@example.com CHECK_SKIP_LIVE=1 bash "$GATE")"; rc=$?
  assert_eq "uninstalled profile exit 0" "$rc" "0"
  assert_eq "uninstalled profile emits no agent-apps lines" \
    "$(echo "$out" | grep -c 'agent app')" "0"
}

test_agent_apps_malformed_manifest() {
  local d rc out manifest_dir

  # Malformed manifest JSON (syntactically broken) whose profile dir IS
  # installed and whose app .env is missing. Before the fix, mf() silently
  # returns an empty string on the json.load() failure; the empty $profile
  # then makes `[[ -d "${PROFILES_DIR}/${profile}" ]]` test PROFILES_DIR
  # itself (which exists), so the loop takes the "not installed, skip"
  # branch instead of failing loud — a false done-done. This must reproduce
  # that bug (RED) before the fix lands.
  d="$(setup_healthy)"
  mkdir -p "$d/apps" "$d/manifests" "$d/profiles/real-estate"
  manifest_dir="$(cygpath -m "$d/manifests" 2>/dev/null || printf '%s' "$d/manifests")"
  cat > "$d/manifests/real-estate.json" <<'JSON'
{
  "profile": "real-estate",
  "apps": [
JSON

  out="$(MANIFEST_DIR="$manifest_dir" APPS_DIR="$d/apps" \
    ORCH_ENV="$d/orch.env" STACK_ENV_FILE="$d/stack.env" SYSTEMD_USER_DIR="$d/units" \
    HERMES_ENV_FILE="$d/hermes.env" PROFILES_DIR="$d/profiles" \
    OPERATOR_EMAIL=jb@example.com CHECK_SKIP_LIVE=1 bash "$GATE")"; rc=$?
  assert_eq "malformed manifest exit 1" "$rc" "1"
  assert_eq "malformed manifest named FAIL" \
    "$(echo "$out" | grep -c 'FAIL: agent apps: unreadable manifest')" "1"
  assert_eq "malformed manifest GAPS>=1" "$(echo "$out" | grep -qE '^GAPS: [1-9]' && echo yes || echo no)" "yes"
}

test_agent_apps_wrong_shape_manifest() {
  local d rc out manifest_dir

  # Valid JSON that survives json.load() but is missing the apps/server
  # structure the gate's checks depend on (F5). Before the fix, a bare
  # {"profile": "..."} with no "apps" key passes the plain json.load() probe,
  # profile resolves non-empty, but `['apps'].__len__()` blows up inside mf()
  # with no error handling — or worse, an manifest with "apps" present but an
  # app missing "server" silently emits zero checks for that entry. Either
  # way this is a false done-done: the gate must fail loud instead.
  d="$(setup_healthy)"
  mkdir -p "$d/apps" "$d/manifests" "$d/profiles/real-estate"
  manifest_dir="$(cygpath -m "$d/manifests" 2>/dev/null || printf '%s' "$d/manifests")"
  cat > "$d/manifests/real-estate.json" <<'JSON'
{
  "profile": "real-estate"
}
JSON

  out="$(MANIFEST_DIR="$manifest_dir" APPS_DIR="$d/apps" \
    ORCH_ENV="$d/orch.env" STACK_ENV_FILE="$d/stack.env" SYSTEMD_USER_DIR="$d/units" \
    HERMES_ENV_FILE="$d/hermes.env" PROFILES_DIR="$d/profiles" \
    OPERATOR_EMAIL=jb@example.com CHECK_SKIP_LIVE=1 bash "$GATE")"; rc=$?
  assert_eq "wrong-shape manifest exit 1" "$rc" "1"
  assert_eq "wrong-shape manifest named FAIL" \
    "$(echo "$out" | grep -c 'FAIL: agent apps: unreadable manifest')" "1"
  assert_eq "wrong-shape manifest GAPS>=1" "$(echo "$out" | grep -qE '^GAPS: [1-9]' && echo yes || echo no)" "yes"
}

test_healthy_box_passes
test_each_gap_flagged
test_detection_failure_fails_loudly
test_dashboard_bind_gate
test_token_dot_exact_match
test_agent_apps_gate
test_agent_apps_malformed_manifest
test_agent_apps_wrong_shape_manifest
finish
