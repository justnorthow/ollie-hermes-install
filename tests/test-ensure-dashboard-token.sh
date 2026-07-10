#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/assert.sh"
ENSURE="$HERE/../scripts/lib/ensure-dashboard-token.sh"

setup_dir() {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/units"
  printf '[Service]\nExecStart=hermes dashboard --host 127.0.0.1 --port 9119\n' > "$d/units/hermes-dashboard.service"
  printf '[Service]\nExecStart=hermes -p m dashboard --host 127.0.0.1 --port 9121\n' > "$d/units/hermes-dashboard-m.service"
  printf '[Service]\nExecStart=hermes gateway\n' > "$d/units/hermes-gateway.service"
  echo "$d"
}

test_generates_and_drops_in() {
  local d; d="$(setup_dir)"
  ORCH_ENV="$d/orch.env" SYSTEMD_USER_DIR="$d/units" ENSURE_TOKEN_NO_RESTART=1 bash "$ENSURE" >/dev/null
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
  ORCH_ENV="$d/orch.env" SYSTEMD_USER_DIR="$d/units" ENSURE_TOKEN_NO_RESTART=1 bash "$ENSURE" >/dev/null
  local a; a="$(cat "$d/orch.env" "$d/units/hermes-dashboard.service.d/session-token.conf")"
  ORCH_ENV="$d/orch.env" SYSTEMD_USER_DIR="$d/units" ENSURE_TOKEN_NO_RESTART=1 bash "$ENSURE" >/dev/null
  assert_eq "reused + zero drift" "$(cat "$d/orch.env" "$d/units/hermes-dashboard.service.d/session-token.conf")" "$a"
  assert_eq "existing value kept" "$(grep -c 'stable-token-value' "$d/orch.env")" "1"
}

test_generates_and_drops_in
test_reuses_existing_token_and_is_idempotent
finish
