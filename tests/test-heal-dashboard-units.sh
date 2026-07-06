#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/assert.sh"
HEAL="$HERE/../scripts/lib/heal-dashboard-units.sh"

setup_dir() {
  local d; d="$(mktemp -d)"
  printf '[Service]\nExecStart=%%h/.local/bin/hermes dashboard --host 127.0.0.1 --port 9119 --insecure --no-open\n' > "$d/hermes-dashboard.service"
  printf '[Service]\nExecStart=%%h/.local/bin/hermes -p marketing-agent dashboard --host 0.0.0.0 --port 9121 --insecure --no-open\n' > "$d/hermes-dashboard-marketing-agent.service"
  printf '[Service]\nExecStart=%%h/.local/bin/hermes gateway --host 0.0.0.0 --port 8642\n' > "$d/hermes-gateway.service"
  echo "$d"
}

test_rewrites_stale_and_leaves_others() {
  local d; d="$(setup_dir)"
  local before_ok; before_ok="$(cat "$d/hermes-dashboard.service")"
  SYSTEMD_USER_DIR="$d" HEAL_DASHBOARD_NO_RESTART=1 bash "$HEAL" >/dev/null
  assert_eq "stale dashboard now on 127.0.0.1" "$(grep -c -- '--host 127.0.0.1' "$d/hermes-dashboard-marketing-agent.service")" "1"
  assert_eq "no 0.0.0.0 left in dashboard"     "$(grep -c -- '--host 0.0.0.0'   "$d/hermes-dashboard-marketing-agent.service")" "0"
  assert_eq "correct dashboard byte-identical" "$(cat "$d/hermes-dashboard.service")" "$before_ok"
  assert_eq "non-dashboard gateway untouched"  "$(grep -c -- '--host 0.0.0.0' "$d/hermes-gateway.service")" "1"
  rm -rf "$d"
}
test_idempotent() {
  local d; d="$(setup_dir)"
  SYSTEMD_USER_DIR="$d" HEAL_DASHBOARD_NO_RESTART=1 bash "$HEAL" >/dev/null
  local first; first="$(cat "$d/hermes-dashboard-marketing-agent.service")"
  SYSTEMD_USER_DIR="$d" HEAL_DASHBOARD_NO_RESTART=1 bash "$HEAL" >/dev/null
  assert_eq "second heal is a no-op" "$(cat "$d/hermes-dashboard-marketing-agent.service")" "$first"
  rm -rf "$d"
}
test_rewrites_stale_and_leaves_others
test_idempotent
finish
