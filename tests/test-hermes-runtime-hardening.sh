#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/assert.sh"
HARDEN="$HERE/../scripts/lib/harden-hermes-runtime.sh"

setup_dir() {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/units"
  printf '[Service]\nExecStart=hermes gateway\n' > "$d/units/hermes-gateway.service"
  printf '[Service]\nExecStart=hermes -p sales gateway\n' > "$d/units/hermes-gateway-sales.service"
  printf '[Service]\nExecStart=hermes dashboard\n' > "$d/units/hermes-dashboard.service"
  echo "$d"
}

run_hardening() {
  local d="$1"; shift
  SYSTEMD_USER_DIR="$d/units" HARDEN_RUNTIME_NO_RELOAD=1 bash "$HARDEN" "$@"
}

test_default_and_profile_are_contained() {
  local d; d="$(setup_dir)"
  run_hardening "$d" hermes-gateway.service hermes-gateway-sales.service hermes-dashboard.service >/dev/null
  local conf="$d/units/hermes-gateway.service.d/20-ollie-runtime-sandbox.conf"
  assert_eq "default drop-in written" "$([[ -f "$conf" ]] && echo yes)" "yes"
  assert_eq "profile drop-in written" "$([[ -f "$d/units/hermes-gateway-sales.service.d/20-ollie-runtime-sandbox.conf" ]] && echo yes)" "yes"
  assert_eq "dashboard drop-in written" "$([[ -f "$d/units/hermes-dashboard.service.d/20-ollie-runtime-sandbox.conf" ]] && echo yes)" "yes"
  assert_eq "no-new-privileges" "$(grep -c '^NoNewPrivileges=yes$' "$conf")" "1"
  assert_eq "home hidden" "$(grep -c '^ProtectHome=tmpfs$' "$conf")" "1"
  assert_eq "Hermes state exposed" "$(grep -c '^BindPaths=%h/.hermes$' "$conf")" "1"
  assert_eq "Docker socket hidden" "$(grep -c '^InaccessiblePaths=-/var/run/docker.sock$' "$conf")" "1"
  assert_eq "user manager hidden" "$(grep -c '^InaccessiblePaths=-/run/user/%U/bus$' "$conf")" "1"
  assert_eq "all capabilities removed" "$(grep -c '^CapabilityBoundingSet=$' "$conf")" "1"
  rm -rf "$d"
}

test_refuses_wrong_or_missing_units() {
  local d; d="$(setup_dir)"
  run_hardening "$d" ollie-orchestrator.service >/dev/null 2>&1
  assert_eq "non-Hermes unit refused" "$?" "2"
  run_hardening "$d" hermes-gateway-missing.service >/dev/null 2>&1
  assert_eq "missing gateway refused" "$?" "1"
  rm -rf "$d"
}

test_default_and_profile_are_contained
test_refuses_wrong_or_missing_units
finish
