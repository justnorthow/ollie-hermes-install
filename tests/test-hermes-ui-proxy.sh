#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/assert.sh"
ENSURE="$HERE/../scripts/lib/ensure-hermes-ui-proxy.sh"

setup_dir() {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/units" "$d/nginx"
  printf '[Service]\nExecStart=hermes dashboard --host 127.0.0.1 --port 9119\n' > "$d/units/hermes-dashboard.service"
  printf '[Service]\nExecStart=hermes -p real-estate dashboard --host 127.0.0.1 --port 9121\n' > "$d/units/hermes-dashboard-real-estate.service"
  printf '[Service]\nExecStart=hermes gateway\n' > "$d/units/hermes-gateway.service"
  printf 'HERMES_DASHBOARD_TOKEN=tok-abcdef0123456789\n' > "$d/orch.env"
  echo "$d"
}

run_ensure() {
  local d="$1"
  ORCH_ENV="$d/orch.env" SYSTEMD_USER_DIR="$d/units" \
  NGINX_CONF_DIR="$d/nginx" NGINX_AUTH_FILE="$d/nginx/hermes-ui-auth.conf" \
  ENSURE_UI_PROXY_NO_RELOAD=1 bash "$ENSURE" >/dev/null 2>&1
}

test_renders_both_agents_with_correct_ports() {
  local d; d="$(setup_dir)"; run_ensure "$d"
  assert_eq "default listens 9219" \
    "$(grep -c 'listen 127.0.0.1:9219;' "$d/nginx/hermes-ui-proxy-default.conf")" "1"
  assert_eq "default upstream 9119" \
    "$(grep -c 'proxy_pass http://127.0.0.1:9119;' "$d/nginx/hermes-ui-proxy-default.conf")" "1"
  assert_eq "real-estate listens 9221" \
    "$(grep -c 'listen 127.0.0.1:9221;' "$d/nginx/hermes-ui-proxy-real-estate.conf")" "1"
  assert_eq "real-estate upstream 9121" \
    "$(grep -c 'proxy_pass http://127.0.0.1:9121;' "$d/nginx/hermes-ui-proxy-real-estate.conf")" "1"
  assert_eq "gateway ignored" \
    "$([[ -f "$d/nginx/hermes-ui-proxy-gateway.conf" ]] && echo yes || echo no)" "no"
}

test_all_three_headers_present_per_agent() {
  local d; d="$(setup_dir)"; run_ensure "$d"
  assert_eq "auth file has bearer" \
    "$(cat "$d/nginx/hermes-ui-auth.conf")" \
    'proxy_set_header Authorization "Bearer tok-abcdef0123456789";'
  for a in default:9119 real-estate:9121; do
    n="${a%%:*}"; p="${a##*:}"
    assert_eq "$n includes auth file" \
      "$(grep -c 'include .*hermes-ui-auth.conf;' "$d/nginx/hermes-ui-proxy-$n.conf")" "1"
    assert_eq "$n rewrites Host" \
      "$(grep -c "proxy_set_header Host 127.0.0.1:$p;" "$d/nginx/hermes-ui-proxy-$n.conf")" "1"
    assert_eq "$n rewrites Origin" \
      "$(grep -c "proxy_set_header Origin http://127.0.0.1:$p;" "$d/nginx/hermes-ui-proxy-$n.conf")" "1"
  done
}

test_single_shared_map_no_duplicate_directive() {
  local d; d="$(setup_dir)"; run_ensure "$d"
  assert_eq "exactly one map file" \
    "$(grep -l 'map \$http_upgrade' "$d/nginx/"*.conf | wc -l | tr -d ' ')" "1"
  assert_eq "map lives in the shared file" \
    "$(grep -c 'map \$http_upgrade' "$d/nginx/hermes-ui-map.conf")" "1"
}

test_never_binds_public() {
  local d; d="$(setup_dir)"; run_ensure "$d"
  assert_eq "no 0.0.0.0 anywhere" \
    "$(grep -l '0\.0\.0\.0' "$d/nginx/"*.conf | wc -l | tr -d ' ')" "0"
}

test_idempotent_no_drift() {
  local d; d="$(setup_dir)"; run_ensure "$d"
  local a; a="$(cat "$d/nginx/"*.conf)"
  run_ensure "$d"
  assert_eq "second run identical" "$(cat "$d/nginx/"*.conf)" "$a"
}

test_auth_file_mode_600() {
  local d; d="$(setup_dir)"; run_ensure "$d"
  local probe; probe="$(mktemp)"; chmod 600 "$probe"
  if [[ "$(stat -c %a "$probe")" == "600" ]]; then
    assert_eq "auth file mode 600" "$(stat -c %a "$d/nginx/hermes-ui-auth.conf")" "600"
  else
    echo "SKIP: mode-600 assertion (filesystem does not enforce POSIX modes)"
  fi
  rm -f "$probe"
}

test_auth_file_mode_reasserted_on_drift() {
  local d; d="$(setup_dir)"; run_ensure "$d"
  local probe; probe="$(mktemp)"; chmod 600 "$probe"
  if [[ "$(stat -c %a "$probe")" == "600" ]]; then
    local before; before="$(cat "$d/nginx/hermes-ui-auth.conf")"
    chmod 644 "$d/nginx/hermes-ui-auth.conf"
    run_ensure "$d"
    assert_eq "auth file mode re-asserted to 600 after drift" \
      "$(stat -c %a "$d/nginx/hermes-ui-auth.conf")" "600"
    assert_eq "auth file content unchanged by mode-only fix" \
      "$(cat "$d/nginx/hermes-ui-auth.conf")" "$before"
  else
    echo "SKIP: mode-600 assertion (filesystem does not enforce POSIX modes)"
  fi
  rm -f "$probe"
}

test_missing_token_fails_loudly() {
  local d; d="$(setup_dir)"
  printf '\n' > "$d/orch.env"
  ORCH_ENV="$d/orch.env" SYSTEMD_USER_DIR="$d/units" \
  NGINX_CONF_DIR="$d/nginx" NGINX_AUTH_FILE="$d/nginx/hermes-ui-auth.conf" \
  ENSURE_UI_PROXY_NO_RELOAD=1 bash "$ENSURE" >/dev/null 2>&1
  assert_eq "nonzero exit on missing token" "$?" "1"
  assert_eq "no conf written" \
    "$([[ -f "$d/nginx/hermes-ui-proxy-default.conf" ]] && echo yes || echo no)" "no"
}

test_renders_both_agents_with_correct_ports
test_all_three_headers_present_per_agent
test_single_shared_map_no_duplicate_directive
test_never_binds_public
test_idempotent_no_drift
test_auth_file_mode_600
test_auth_file_mode_reasserted_on_drift
test_missing_token_fails_loudly
finish
