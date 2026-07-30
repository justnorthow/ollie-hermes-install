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

# run_ensure DIR [EXTRA_ENV_ASSIGNMENT...] — run the script against fixture DIR.
# Captures stdout into ENSURE_OUT and the exit status into ENSURE_RC instead of
# discarding them: the "done (changed=N)" line is the script's only report of
# whether it decided anything actually changed, and that decision (a mode-only
# correction must NOT count as a change, and so must not trigger a reload) is
# the property two earlier fix rounds established. Untested, it can regress
# silently. Extra NAME=VALUE args are layered on (e.g. to drop
# ENSURE_UI_PROXY_NO_RELOAD, or to prepend a stub PATH).
ENSURE_OUT=""; ENSURE_ERR=""; ENSURE_RC=0
run_ensure() {
  local d="$1"; shift
  ENSURE_OUT="$(env ORCH_ENV="$d/orch.env" SYSTEMD_USER_DIR="$d/units" \
    NGINX_CONF_DIR="$d/nginx" NGINX_AUTH_FILE="$d/nginx/hermes-ui-auth.conf" \
    ENSURE_UI_PROXY_NO_RELOAD=1 "$@" bash "$ENSURE" 2>"$d/stderr.log")"
  ENSURE_RC=$?
  ENSURE_ERR="$(cat "$d/stderr.log" 2>/dev/null)"
}

# The changed count the script reported on its last run ("" if it never got
# that far).
ensure_changed() {
  local line
  while IFS= read -r line; do
    case "$line" in
      *"done (changed="*) line="${line#*done (changed=}"; printf '%s' "${line%%)*}"; return 0 ;;
    esac
  done <<< "$ENSURE_OUT"
  printf ''
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
  local before; before="$(cat "$d/nginx/hermes-ui-auth.conf")"
  chmod 644 "$d/nginx/hermes-ui-auth.conf"
  run_ensure "$d"
  assert_eq "auth file content unchanged by mode-only fix" \
    "$(cat "$d/nginx/hermes-ui-auth.conf")" "$before"
  local probe; probe="$(mktemp)"; chmod 600 "$probe"
  if [[ "$(stat -c %a "$probe")" == "600" ]]; then
    assert_eq "auth file mode re-asserted to 600 after drift" \
      "$(stat -c %a "$d/nginx/hermes-ui-auth.conf")" "600"
  else
    echo "SKIP: mode re-assertion assertion (filesystem does not enforce POSIX modes)"
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

test_rotation_rerenders_auth_file() {
  local d; d="$(setup_dir)"; run_ensure "$d"
  assert_eq "initial bearer" "$(cat "$d/nginx/hermes-ui-auth.conf")" \
    'proxy_set_header Authorization "Bearer tok-abcdef0123456789";'
  printf 'HERMES_DASHBOARD_TOKEN=tok-ROTATED-9876543210\n' > "$d/orch.env"
  run_ensure "$d"
  assert_eq "auth file follows rotation" "$(cat "$d/nginx/hermes-ui-auth.conf")" \
    'proxy_set_header Authorization "Bearer tok-ROTATED-9876543210";'
  assert_eq "server blocks unchanged by rotation" \
    "$(grep -c 'listen 127.0.0.1:9219;' "$d/nginx/hermes-ui-proxy-default.conf")" "1"
}

test_ensure_token_invokes_ui_proxy() {
  local d; d="$(setup_dir)"
  ORCH_ENV="$d/orch.env" SYSTEMD_USER_DIR="$d/units" \
  NGINX_CONF_DIR="$d/nginx" NGINX_AUTH_FILE="$d/nginx/hermes-ui-auth.conf" \
  ENSURE_UI_PROXY_NO_RELOAD=1 ENSURE_TOKEN_NO_RESTART=1 \
    bash "$HERE/../scripts/lib/ensure-dashboard-token.sh" >/dev/null 2>&1
  local tok; tok="$(grep '^HERMES_DASHBOARD_TOKEN=' "$d/orch.env" | cut -d= -f2-)"
  assert_eq "ui-proxy auth file written by token script" \
    "$(cat "$d/nginx/hermes-ui-auth.conf")" \
    "$(printf 'proxy_set_header Authorization "Bearer %s";' "$tok")"
}

# --- changed-count contract -------------------------------------------------
# `changed` is what gates the nginx reload. A mode-only correction re-asserting
# 600 must not inflate it (that would reload nginx on every single run), and a
# token rotation must.

test_changed_zero_on_noop_rerun() {
  local d; d="$(setup_dir)"; run_ensure "$d"
  assert_eq "first run reports a change" "$(ensure_changed)" "1"
  run_ensure "$d"
  assert_eq "no-op rerun reports changed=0" "$(ensure_changed)" "0"
  assert_eq "no-op rerun exits 0" "$ENSURE_RC" "0"
}

test_changed_zero_on_mode_only_correction() {
  local d; d="$(setup_dir)"; run_ensure "$d"
  chmod 644 "$d/nginx/hermes-ui-auth.conf"
  run_ensure "$d"
  assert_eq "mode-only fix reports changed=0" "$(ensure_changed)" "0"
  assert_eq "mode-only fix wrote nothing" \
    "$(printf '%s\n' "$ENSURE_OUT" | grep -c 'wrote ')" "0"
}

test_changed_one_on_token_rotation() {
  local d; d="$(setup_dir)"; run_ensure "$d"
  printf 'HERMES_DASHBOARD_TOKEN=tok-ROTATED-9876543210\n' > "$d/orch.env"
  run_ensure "$d"
  assert_eq "rotation reports changed=1" "$(ensure_changed)" "1"
}

# --- reload path ------------------------------------------------------------
# Everything above runs with ENSURE_UI_PROXY_NO_RELOAD=1, which skips the block
# that actually makes a rendered config take effect. Stub nginx/systemctl onto
# PATH and exercise it for real. ($d/nginx is writable by the test user, so the
# script picks SUDO="" and calls these directly.)

stub_bin() { # $1=dir  $2=nginx exit  $3=systemctl exit
  local d="$1"
  mkdir -p "$d/bin"
  cat > "$d/bin/nginx" <<SH
#!/usr/bin/env bash
echo "nginx \$*" >> "$d/calls.log"
exit $2
SH
  cat > "$d/bin/systemctl" <<SH
#!/usr/bin/env bash
echo "systemctl \$*" >> "$d/calls.log"
exit $3
SH
  chmod +x "$d/bin/nginx" "$d/bin/systemctl"
  : > "$d/calls.log"
}

test_reload_runs_only_when_something_changed() {
  local d; d="$(setup_dir)"; stub_bin "$d" 0 0
  run_ensure "$d" ENSURE_UI_PROXY_NO_RELOAD=0 PATH="$d/bin:$PATH"
  assert_eq "first run exits 0" "$ENSURE_RC" "0"
  assert_eq "config tested before reload" "$(grep -c 'nginx -t' "$d/calls.log")" "1"
  assert_eq "nginx reloaded on change" \
    "$(grep -c 'systemctl reload nginx' "$d/calls.log")" "1"

  : > "$d/calls.log"
  run_ensure "$d" ENSURE_UI_PROXY_NO_RELOAD=0 PATH="$d/bin:$PATH"
  assert_eq "no-op rerun reports changed=0" "$(ensure_changed)" "0"
  assert_eq "no-op rerun never touches nginx" "$(wc -l < "$d/calls.log" | tr -d ' ')" "0"
}

test_failed_reload_is_fatal() {
  # The new bearer is on disk but the running nginx still holds the old one:
  # exiting 0 here is the permanent-401 this design exists to prevent.
  local d; d="$(setup_dir)"; stub_bin "$d" 0 1
  run_ensure "$d" ENSURE_UI_PROXY_NO_RELOAD=0 PATH="$d/bin:$PATH"
  assert_eq "failed reload exits non-zero" "$ENSURE_RC" "1"
  assert_eq "failure names the consequence" \
    "$(printf '%s' "$ENSURE_ERR" | grep -cE 'FATAL.*reload failed')" "1"
  assert_eq "failure warns the old token is still live" \
    "$(printf '%s' "$ENSURE_ERR" | grep -c 'PREVIOUS token')" "1"
}

test_rejected_config_never_reloads() {
  local d; d="$(setup_dir)"; stub_bin "$d" 1 0
  run_ensure "$d" ENSURE_UI_PROXY_NO_RELOAD=0 PATH="$d/bin:$PATH"
  assert_eq "rejected config exits non-zero" "$ENSURE_RC" "1"
  assert_eq "no reload after a failed nginx -t" \
    "$(grep -c 'systemctl reload' "$d/calls.log")" "0"
}

test_renders_both_agents_with_correct_ports
test_all_three_headers_present_per_agent
test_single_shared_map_no_duplicate_directive
test_never_binds_public
test_idempotent_no_drift
test_auth_file_mode_600
test_auth_file_mode_reasserted_on_drift
test_missing_token_fails_loudly
test_rotation_rerenders_auth_file
test_ensure_token_invokes_ui_proxy
test_changed_zero_on_noop_rerun
test_changed_zero_on_mode_only_correction
test_changed_one_on_token_rotation
test_reload_runs_only_when_something_changed
test_failed_reload_is_fatal
test_rejected_config_never_reloads
finish
