#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/assert.sh"
ENSURE="$HERE/../scripts/lib/ensure-dashboard-token.sh"

setup_dir() {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/units" "$d/nginx"
  printf '[Service]\nExecStart=hermes dashboard --host 127.0.0.1 --port 9119\n' > "$d/units/hermes-dashboard.service"
  printf '[Service]\nExecStart=hermes -p m dashboard --host 127.0.0.1 --port 9121\n' > "$d/units/hermes-dashboard-m.service"
  printf '[Service]\nExecStart=hermes gateway\n' > "$d/units/hermes-gateway.service"
  echo "$d"
}

# ensure-dashboard-token.sh shells out to ensure-hermes-ui-proxy.sh, which
# defaults to the REAL /etc/nginx. Run on an actual box these tests would
# otherwise overwrite the live hermes-ui-auth.conf with a fixture token and
# reload nginx — observed on the sandbox 2026-07-30, where the 35-char
# 'stable-token-value-...' fixture replaced the live 43-char token and every
# proxied dashboard 401'd. Every invocation below MUST carry these.
run_token_script() { # $1=dir, then extra NAME=VALUE args
  local d="$1"; shift
  env ORCH_ENV="$d/orch.env" SYSTEMD_USER_DIR="$d/units" \
      NGINX_CONF_DIR="$d/nginx" NGINX_AUTH_FILE="$d/nginx/hermes-ui-auth.conf" \
      HERMES_UI_RELOAD_MARKER="$d/nginx/.last-reload" \
      ENSURE_UI_PROXY_NO_RELOAD=1 ENSURE_TOKEN_NO_RESTART=1 \
      "$@" bash "$ENSURE"
}

test_generates_and_drops_in() {
  local d; d="$(setup_dir)"
  run_token_script "$d" >/dev/null
  local tok; tok="$(grep '^HERMES_DASHBOARD_TOKEN=' "$d/orch.env" | cut -d= -f2-)"
  assert_eq "token nonempty (len>=32)" "$([[ ${#tok} -ge 32 ]] && echo yes)" "yes"
  assert_eq "drop-in default" "$(cat "$d/units/hermes-dashboard.service.d/session-token.conf")" \
    "$(printf '[Service]\nEnvironment=HERMES_DASHBOARD_SESSION_TOKEN=%s' "$tok")"
  assert_eq "drop-in profile" "$(cat "$d/units/hermes-dashboard-m.service.d/session-token.conf")" \
    "$(printf '[Service]\nEnvironment=HERMES_DASHBOARD_SESSION_TOKEN=%s' "$tok")"
  assert_eq "gateway untouched" "$([[ -d "$d/units/hermes-gateway.service.d" ]] && echo yes || echo no)" "no"
  # chmod is a no-op on NTFS — only assert mode where the filesystem enforces it
  _mode_probe="$(mktemp)"; chmod 600 "$_mode_probe"
  if [[ "$(stat -c %a "$_mode_probe")" == "600" ]]; then
    assert_eq "drop-in mode 600" "$(stat -c %a "$d/units/hermes-dashboard.service.d/session-token.conf")" "600"
  else
    echo "SKIP: mode-600 assertion (filesystem does not enforce POSIX modes)"
  fi
  rm -f "$_mode_probe"
}

test_reuses_existing_token_and_is_idempotent() {
  local d; d="$(setup_dir)"
  printf 'HERMES_DASHBOARD_TOKEN=stable-token-value-0123456789abcdef\n' > "$d/orch.env"
  run_token_script "$d" >/dev/null
  local a; a="$(cat "$d/orch.env" "$d/units/hermes-dashboard.service.d/session-token.conf")"
  run_token_script "$d" >/dev/null
  assert_eq "reused + zero drift" "$(cat "$d/orch.env" "$d/units/hermes-dashboard.service.d/session-token.conf")" "$a"
  assert_eq "existing value kept" "$(grep -c 'stable-token-value' "$d/orch.env")" "1"
}

test_generates_and_drops_in
test_reuses_existing_token_and_is_idempotent
finish
