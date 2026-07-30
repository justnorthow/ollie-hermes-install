#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/assert.sh"
GATE="$HERE/../scripts/check-box-config.sh"

setup_healthy() {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/units/hermes-dashboard.service.d" "$d/profiles" "$d/nginx"
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
  # Proxy artifacts a healthy box would have (Task 6): one nginx conf per
  # hermes-dashboard unit plus the auth drop-in matching
  # HERMES_DASHBOARD_TOKEN. Derived from current fixture state (not
  # hardcoded) so tests that mutate the token or the unit set can re-sync.
  sync_ui_fixtures "$d"
  echo "$d"
}

# Regenerate the proxy artifacts (nginx auth file + one hermes-ui-proxy-<agent>.conf
# per hermes-dashboard*.service unit) from the CURRENT state of the fixture
# dir. Call this after any mutation that changes HERMES_DASHBOARD_TOKEN or
# the set of dashboard units, so the fixtures stay self-consistent instead
# of drifting from a hardcoded token/agent pair.
sync_ui_fixtures() {
  local d="$1" token unit name agent line upstream re='--port[= ]+([0-9]+)'
  mkdir -p "$d/nginx"
  token=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      HERMES_DASHBOARD_TOKEN=*) token="${line#HERMES_DASHBOARD_TOKEN=}" ;;
    esac
  done < "$d/orch.env"
  printf 'proxy_set_header Authorization "Bearer %s";' "$token" > "$d/nginx/hermes-ui-auth.conf"
  rm -f "$d"/nginx/hermes-ui-proxy-*.conf
  shopt -s nullglob
  for unit in "$d"/units/hermes-dashboard*.service; do
    name="${unit##*/}"
    agent="${name#hermes-dashboard}"; agent="${agent%.service}"; agent="${agent#-}"
    [[ -z "${agent}" ]] && agent="default"
    # Derive the listen port from the unit exactly as ensure-hermes-ui-proxy.sh
    # does (upstream + 100) and include the auth file, so the fixture is what
    # the real renderer emits rather than a shape the gate can't distinguish
    # from a stale conf left over for a retired port.
    upstream=""
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" == ExecStart=* ]] || continue
      [[ "$line" =~ $re ]] && upstream="${BASH_REMATCH[1]}"
    done < "$unit"
    printf 'server {\n    listen 127.0.0.1:%s;\n    location / {\n        include %s;\n        proxy_pass http://127.0.0.1:%s;\n    }\n}\n' \
      "$(( upstream + 100 ))" "$d/nginx/hermes-ui-auth.conf" "$upstream" \
      > "$d/nginx/hermes-ui-proxy-${agent}.conf"
  done
  shopt -u nullglob
}

# run_gate DIR [EXTRA_ENV_ASSIGNMENT...] — invokes the gate against fixture
# DIR with the common env, plus any extra NAME=VALUE overrides/additions
# (e.g. MANIFEST_DIR=..., ALLOW_PUBLIC_BIND=1, HERMES_ENV_FILE=...) layered
# on top via `env`, so call sites needing test-specific env don't have to
# duplicate the whole common list.
run_gate() {
  local d="$1"; shift
  env ORCH_ENV="$d/orch.env" STACK_ENV_FILE="$d/stack.env" SYSTEMD_USER_DIR="$d/units" \
    HERMES_ENV_FILE="$d/hermes.env" PROFILES_DIR="$d/profiles" \
    NGINX_CONF_DIR="$d/nginx" NGINX_AUTH_FILE="$d/nginx/hermes-ui-auth.conf" \
    OPERATOR_EMAIL=jb@example.com CHECK_SKIP_LIVE=1 \
    "$@" bash "$GATE"
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
  out="$(run_gate "$d" HERMES_ENV_FILE=/nonexistent/path/.env)"; rc=$?
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
  out="$(run_gate "$d" ALLOW_PUBLIC_BIND=1)"; rc=$?
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
  # Re-sync the ui-proxy auth fixture to the new token so this remains a
  # healthy box (the mutation above only targets the session-token drop-in).
  sync_ui_fixtures "$d"
  # Should pass with exact token match
  out="$(run_gate "$d")"; rc=$?
  assert_eq "token with dot match exit 0" "$rc" "0"

  # Now make drop-in differ by one char at dot position
  d="$(setup_healthy)"
  sed -i 's/HERMES_DASHBOARD_TOKEN=.*/HERMES_DASHBOARD_TOKEN='"$TOKEN"'/' "$d/orch.env"
  sync_ui_fixtures "$d"
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
  out="$(run_gate "$d" MANIFEST_DIR="$manifest_dir" APPS_DIR="$d/apps")"; rc=$?
  assert_eq "missing app .env exit 1" "$rc" "1"
  assert_eq "missing app .env named FAIL" \
    "$(echo "$out" | grep -c 'FAIL: agent app popbys')" "1"

  # (b) app .env present + CHECK_SKIP_LIVE=1 -> PASS, healthy overall
  mkdir -p "$d/apps/popbys"; : > "$d/apps/popbys/.env"
  out="$(run_gate "$d" MANIFEST_DIR="$manifest_dir" APPS_DIR="$d/apps")"; rc=$?
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
  out="$(run_gate "$d" MANIFEST_DIR="$manifest_dir" APPS_DIR="$d/apps")"; rc=$?
  assert_eq "uninstalled profile exit 0" "$rc" "0"
  assert_eq "uninstalled profile emits no agent-apps lines" \
    "$(echo "$out" | grep -c 'agent app')" "0"
}

test_agent_apps_tile_gate() {
  local d rc out manifest_dir

  # ---- fixture manifest: app carries a "tile" key (Task 5) ----
  d="$(setup_healthy)"
  mkdir -p "$d/apps" "$d/manifests" "$d/profiles/real-estate"
  manifest_dir="$(cygpath -m "$d/manifests" 2>/dev/null || printf '%s' "$d/manifests")"
  cat > "$d/manifests/real-estate.json" <<'JSON'
{
  "profile": "real-estate",
  "apps": [
    {
      "name": "popbys",
      "stack": { "kong_port": 8030, "email_enabled": "false" },
      "server": { "app_port": 8130, "container_port": 8080, "health_path": "/api/health" },
      "tile": {
        "label": "Pop Bys",
        "icon": "M15",
        "description": "Pop-by planning: contacts, cadence, routes, calendar",
        "order": 10
      }
    }
  ]
}
JSON
  mkdir -p "$d/apps/popbys"; : > "$d/apps/popbys/.env"

  # (a) tile app missing from the profile's apps.json (never registered, or
  # apps.json absent entirely) -> FAIL + gap
  out="$(run_gate "$d" MANIFEST_DIR="$manifest_dir" APPS_DIR="$d/apps")"; rc=$?
  assert_eq "tile missing from apps.json exit 1" "$rc" "1"
  assert_eq "tile missing from apps.json named FAIL" \
    "$(echo "$out" | grep -c 'FAIL: agent app popbys: tile missing')" "1"

  # (b) apps.json exists but doesn't include this app's id -> still FAIL
  printf '[{"id":"someother-app","label":"Other"}]' > "$d/profiles/real-estate/apps.json"
  out="$(run_gate "$d" MANIFEST_DIR="$manifest_dir" APPS_DIR="$d/apps")"; rc=$?
  assert_eq "tile id absent from apps.json exit 1" "$rc" "1"
  assert_eq "tile id absent from apps.json named FAIL" \
    "$(echo "$out" | grep -c 'FAIL: agent app popbys: tile missing')" "1"

  # (c) apps.json includes this app's id -> PASS, healthy overall
  printf '[{"id":"popbys","label":"Pop Bys"}]' > "$d/profiles/real-estate/apps.json"
  out="$(run_gate "$d" MANIFEST_DIR="$manifest_dir" APPS_DIR="$d/apps")"; rc=$?
  assert_eq "tile registered exit 0" "$rc" "0"
  assert_eq "tile registered named PASS" \
    "$(echo "$out" | grep -c 'PASS: agent app popbys: tile registered')" "1"

  # (d) sanity: a manifest app with NO "tile" key emits no tile check at all
  # (dashboard-embedded tiles are opt-in per app; the existing non-tile fixture
  # in test_agent_apps_gate must not regress).
  d="$(setup_healthy)"
  mkdir -p "$d/apps" "$d/manifests" "$d/profiles/real-estate"
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
  mkdir -p "$d/apps/popbys"; : > "$d/apps/popbys/.env"
  out="$(run_gate "$d" MANIFEST_DIR="$manifest_dir" APPS_DIR="$d/apps")"; rc=$?
  assert_eq "no-tile app exit 0" "$rc" "0"
  assert_eq "no-tile app emits no tile check" \
    "$(echo "$out" | grep -c 'tile')" "0"
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

  out="$(run_gate "$d" MANIFEST_DIR="$manifest_dir" APPS_DIR="$d/apps")"; rc=$?
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

  out="$(run_gate "$d" MANIFEST_DIR="$manifest_dir" APPS_DIR="$d/apps")"; rc=$?
  assert_eq "wrong-shape manifest exit 1" "$rc" "1"
  assert_eq "wrong-shape manifest named FAIL" \
    "$(echo "$out" | grep -c 'FAIL: agent apps: unreadable manifest')" "1"
  assert_eq "wrong-shape manifest GAPS>=1" "$(echo "$out" | grep -qE '^GAPS: [1-9]' && echo yes || echo no)" "yes"
}

test_ui_proxy_gate_passes_when_healthy() {
  local d rc out
  d="$(setup_healthy)"
  out="$(run_gate "$d")"; rc=$?
  assert_eq "ui-proxy healthy exit 0" "$rc" "0"
  assert_eq "ui-proxy conf PASS" "$(echo "$out" | grep -c 'PASS: hermes-ui-proxy conf present (default)')" "1"
  assert_eq "ui-auth PASS" "$(echo "$out" | grep -c 'PASS: hermes-ui-auth matches orchestrator token')" "1"
}

test_ui_proxy_gate_fails_on_stale_token() {
  local d rc out
  d="$(setup_healthy)"
  printf 'proxy_set_header Authorization "Bearer STALE-TOKEN";' > "$d/nginx/hermes-ui-auth.conf"
  out="$(run_gate "$d")"; rc=$?
  assert_eq "stale token exit 1" "$rc" "1"
  assert_eq "stale token FAILs named" "$(echo "$out" | grep -c 'FAIL: hermes-ui-auth stale')" "1"
}

test_ui_proxy_gate_fails_on_missing_conf() {
  local d rc out
  d="$(setup_healthy)"
  rm -f "$d/nginx/hermes-ui-proxy-default.conf"
  out="$(run_gate "$d")"; rc=$?
  assert_eq "missing conf exit 1" "$rc" "1"
  assert_eq "missing conf FAIL named" "$(echo "$out" | grep -c 'FAIL: hermes-ui-proxy conf missing (default)')" "1"
}

test_ui_proxy_gate_fails_on_missing_auth_file() {
  local d rc out
  d="$(setup_healthy)"
  rm -f "$d/nginx/hermes-ui-auth.conf"
  out="$(run_gate "$d")"; rc=$?
  assert_eq "missing auth file exit 1" "$rc" "1"
  assert_eq "missing auth file FAIL named" \
    "$(echo "$out" | grep -c 'FAIL: hermes-ui-auth missing')" "1"
}

# On a real box ensure-hermes-ui-proxy.sh writes the auth file root-owned mode
# 600 while /etc/nginx stays 755, so `[[ -f ]]` succeeds for the service user
# but the READ is denied and yields "". The gate then compared "" against the
# expected header and reported "hermes-ui-auth stale" on a perfectly healthy
# box — the primary diagnostic in the runbook, permanently unconvergeable.
# NTFS has no modes and the fixtures are written by the test user, which is
# exactly why the bug was invisible here. Simulate it instead: leave the
# fixture file empty (what a denied read looks like to the gate) and put a
# `sudo` on PATH that serves the root-only shadow copy.
stub_sudo() { # $1=dir  $2=exit code for the privileged read (0 = it works)
  local d="$1" rc="$2"
  mkdir -p "$d/bin"
  cat > "$d/bin/sudo" <<SH
#!/usr/bin/env bash
args=(); for a in "\$@"; do [[ "\$a" == -n ]] && continue; args+=("\$a"); done
[[ $rc -eq 0 ]] || exit $rc
if [[ "\${args[0]}" == cat && -f "\${args[1]}.root" ]]; then exec cat "\${args[1]}.root"; fi
exec "\${args[@]}"
SH
  chmod +x "$d/bin/sudo"
}

test_ui_auth_read_uses_privileged_path() {
  local d rc out
  d="$(setup_healthy)"; stub_sudo "$d" 0
  mv "$d/nginx/hermes-ui-auth.conf" "$d/nginx/hermes-ui-auth.conf.root"
  : > "$d/nginx/hermes-ui-auth.conf"      # present, but unreadable-looking
  out="$(run_gate "$d" PATH="$d/bin:$PATH")"; rc=$?
  assert_eq "root-owned auth file still exits 0" "$rc" "0"
  assert_eq "matching content PASSes via the privileged read" \
    "$(echo "$out" | grep -c 'PASS: hermes-ui-auth matches orchestrator token')" "1"
  assert_eq "healthy box is never called stale" \
    "$(echo "$out" | grep -c 'hermes-ui-auth stale')" "0"
}

test_ui_auth_stale_still_fails_through_privileged_path() {
  # The fix must not turn every mismatch into "unreadable": a genuinely stale
  # root-owned file has to keep FAILing with the remedy message.
  local d rc out
  d="$(setup_healthy)"; stub_sudo "$d" 0
  printf 'proxy_set_header Authorization "Bearer STALE-TOKEN";' \
    > "$d/nginx/hermes-ui-auth.conf.root"
  : > "$d/nginx/hermes-ui-auth.conf"
  out="$(run_gate "$d" PATH="$d/bin:$PATH")"; rc=$?
  assert_eq "stale root-owned auth file exits 1" "$rc" "1"
  assert_eq "stale FAIL names the remedy" \
    "$(echo "$out" | grep -c 'FAIL: hermes-ui-auth stale')" "1"
}

test_ui_auth_unreadable_fails_explicitly() {
  # No privileged read available: the gate must say it could not read the file,
  # never silently compare an empty string and call it "stale".
  local d rc out
  d="$(setup_healthy)"; stub_sudo "$d" 1
  : > "$d/nginx/hermes-ui-auth.conf"
  out="$(run_gate "$d" PATH="$d/bin:$PATH")"; rc=$?
  assert_eq "unreadable auth file exits 1" "$rc" "1"
  assert_eq "unreadable FAIL is explicit" \
    "$(echo "$out" | grep -c 'FAIL: hermes-ui-auth could not be read')" "1"
  assert_eq "unreadable is not reported as stale" \
    "$(echo "$out" | grep -c 'hermes-ui-auth stale')" "0"
}

test_ui_proxy_conf_must_match_expected_port() {
  # Presence-only let a conf left behind for a retired upstream PASS.
  local d rc out
  d="$(setup_healthy)"
  sed -i 's|listen 127.0.0.1:9219;|listen 127.0.0.1:9999;|' \
    "$d/nginx/hermes-ui-proxy-default.conf"
  out="$(run_gate "$d")"; rc=$?
  assert_eq "wrong listen port exits 1" "$rc" "1"
  assert_eq "stale conf FAIL names the expected port" \
    "$(echo "$out" | grep -c "FAIL: hermes-ui-proxy conf stale (default: expected 'listen 127.0.0.1:9219;'")" "1"
}

test_ui_proxy_conf_must_include_auth_file() {
  # A conf without the auth include renders a proxy that 401s every request.
  local d rc out
  d="$(setup_healthy)"
  sed -i '/include /d' "$d/nginx/hermes-ui-proxy-default.conf"
  out="$(run_gate "$d")"; rc=$?
  assert_eq "missing auth include exits 1" "$rc" "1"
  assert_eq "missing include FAIL named" \
    "$(echo "$out" | grep -c 'FAIL: hermes-ui-proxy conf missing the auth include (default')" "1"
}

# --- liveness (CHECK_SKIP_LIVE=0) -------------------------------------------
# Correct files with a dead — or merely never-reloaded — nginx used to report
# PASS, which is the one thing this gate must never do. These runs stub the
# live probes; only the two ui-proxy liveness lines are asserted (the other
# section-5 checks legitimately fail against stubs).
stub_live() { # $1=dir  $2=nginx is-active rc  $3=http code the proxy answers
  local d="$1" nginx_rc="$2" code="$3"
  mkdir -p "$d/bin"
  cat > "$d/bin/systemctl" <<SH
#!/usr/bin/env bash
for a in "\$@"; do [[ "\$a" == nginx ]] && exit $nginx_rc; done
exit 3
SH
  cat > "$d/bin/docker" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$d/bin/curl" <<SH
#!/usr/bin/env bash
printf '%s' "$code"
SH
  chmod +x "$d/bin/systemctl" "$d/bin/docker" "$d/bin/curl"
}

test_ui_proxy_liveness_is_skipped_under_skip_live() {
  local d out
  d="$(setup_healthy)"
  out="$(run_gate "$d")"
  assert_eq "no nginx systemd probe under CHECK_SKIP_LIVE=1" \
    "$(echo "$out" | grep -cE '(PASS|FAIL): nginx (not )?active')" "0"
  assert_eq "no proxy http probe under CHECK_SKIP_LIVE=1" \
    "$(echo "$out" | grep -c 'hermes-ui-proxy answers')" "0"
}

test_ui_proxy_liveness_passes_when_live() {
  local d out
  d="$(setup_healthy)"; stub_live "$d" 0 200
  out="$(run_gate "$d" CHECK_SKIP_LIVE=0 PATH="$d/bin:$PATH")"
  assert_eq "nginx active PASS" "$(echo "$out" | grep -c 'PASS: nginx active')" "1"
  assert_eq "proxy answers 200 PASS" \
    "$(echo "$out" | grep -c 'PASS: hermes-ui-proxy answers 200 (default on 127.0.0.1:9219)')" "1"
}

test_ui_proxy_liveness_fails_on_dead_nginx() {
  local d rc out
  d="$(setup_healthy)"; stub_live "$d" 3 000
  out="$(run_gate "$d" CHECK_SKIP_LIVE=0 PATH="$d/bin:$PATH")"; rc=$?
  assert_eq "dead nginx exits 1" "$rc" "1"
  assert_eq "dead nginx FAIL named" "$(echo "$out" | grep -c 'FAIL: nginx not active')" "1"
}

test_ui_proxy_liveness_fails_when_proxy_does_not_answer() {
  # nginx up but never reloaded after a token rotation: the files are perfect
  # and the proxy 401s. Files alone must not PASS this box.
  local d rc out
  d="$(setup_healthy)"; stub_live "$d" 0 401
  out="$(run_gate "$d" CHECK_SKIP_LIVE=0 PATH="$d/bin:$PATH")"; rc=$?
  assert_eq "non-200 proxy exits 1" "$rc" "1"
  assert_eq "non-200 proxy FAIL named" \
    "$(echo "$out" | grep -c "FAIL: hermes-ui-proxy did not answer 200 (default on 127.0.0.1:9219 returned '401'")" "1"
}

# --- liveness probe hygiene -------------------------------------------------
# Both of these were found on the sandbox 2026-07-30 and neither was catchable
# with the stub above, which always exits 0 and ignores -o.

stub_live_recording() { # $1=dir  $2=curl exit code  $3=what curl prints
  local d="$1" curl_rc="$2" body="$3"
  mkdir -p "$d/bin"
  cat > "$d/bin/systemctl" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do [[ "$a" == nginx ]] && exit 0; done
exit 3
SH
  cat > "$d/bin/docker" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$d/bin/curl" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$d/curl-args.log"
printf '%s' "$body"
exit $curl_rc
SH
  chmod +x "$d/bin/systemctl" "$d/bin/docker" "$d/bin/curl"
  : > "$d/curl-args.log"
}

test_liveness_probe_discards_the_body_to_dev_null() {
  # The source had `-o \dev\null` with BACKSLASHES. bash unescapes that to
  # `-o devnull`, so curl wrote every response body into a file literally named
  # devnull in the working directory — it showed up as an untracked `devnull`
  # in ~/ollie-hermes-install after a gate run.
  local d; d="$(setup_healthy)"; stub_live_recording "$d" 0 200
  run_gate "$d" CHECK_SKIP_LIVE=0 PATH="$d/bin:$PATH" >/dev/null 2>&1
  # Scoped to the ui-proxy probe: other sections of the gate also call curl and
  # already pass a correct /dev/null, so an unscoped grep matches those and the
  # assertion silently proves nothing.
  assert_eq "ui-proxy probe discards the body to /dev/null" \
    "$(grep -- ':9219/api/files' "$d/curl-args.log" | grep -c -- '-o /dev/null')" "1"
  assert_eq "ui-proxy probe never writes a stray devnull file" \
    "$(grep -- ':9219/api/files' "$d/curl-args.log" | grep -c -- '-o devnull')" "0"
}

test_unreachable_proxy_reports_one_status_code() {
  # Real curl prints '000' via -w AND exits non-zero when the connection is
  # refused. The redundant `|| echo 000` then appended a SECOND one (no trailing
  # newline on -w), so operators saw the nonsense code '000000'.
  local d out; d="$(setup_healthy)"; stub_live_recording "$d" 7 000
  out="$(run_gate "$d" CHECK_SKIP_LIVE=0 PATH="$d/bin:$PATH" 2>&1)"
  assert_eq "reports a single 000" \
    "$(printf '%s' "$out" | grep -c "returned '000'")" "1"
  assert_eq "never reports a doubled 000000" \
    "$(printf '%s' "$out" | grep -c '000000')" "0"
}

test_healthy_box_passes
test_each_gap_flagged
test_detection_failure_fails_loudly
test_dashboard_bind_gate
test_token_dot_exact_match
test_agent_apps_gate
test_agent_apps_tile_gate
test_agent_apps_malformed_manifest
test_agent_apps_wrong_shape_manifest
test_ui_proxy_gate_passes_when_healthy
test_ui_proxy_gate_fails_on_stale_token
test_ui_proxy_gate_fails_on_missing_conf
test_ui_proxy_gate_fails_on_missing_auth_file
test_ui_auth_read_uses_privileged_path
test_ui_auth_stale_still_fails_through_privileged_path
test_ui_auth_unreadable_fails_explicitly
test_ui_proxy_conf_must_match_expected_port
test_ui_proxy_conf_must_include_auth_file
test_ui_proxy_liveness_is_skipped_under_skip_live
test_ui_proxy_liveness_passes_when_live
test_ui_proxy_liveness_fails_on_dead_nginx
test_ui_proxy_liveness_fails_when_proxy_does_not_answer
test_liveness_probe_discards_the_body_to_dev_null
test_unreachable_proxy_reports_one_status_code
finish
