#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/assert.sh"
SCRIPT="$HERE/../scripts/lib/restart-dashboard-units.sh"

setup_dir() {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/units"
  printf '[Service]\nExecStart=hermes dashboard --host 127.0.0.1 --port 9119\n' > "$d/units/hermes-dashboard.service"
  printf '[Service]\nExecStart=hermes -p real-estate dashboard --host 127.0.0.1 --port 9121\n' > "$d/units/hermes-dashboard-real-estate.service"
  printf '[Service]\nExecStart=hermes -p olivia dashboard --host 127.0.0.1 --port 9122\n' > "$d/units/hermes-dashboard-olivia.service"
  printf '[Service]\nExecStart=hermes gateway\n' > "$d/units/hermes-gateway.service"
  # A drop-in directory must not be mistaken for a unit.
  mkdir -p "$d/units/hermes-dashboard.service.d"
  echo "$d"
}

# Every unit reports ACTIVE — the exact post-`hermes update` situation, where the
# processes are running happily but against a source tree that changed underneath
# them. A restarter that trusts is-active does nothing here, which is the bug.
stub_systemctl() { # $1=dir  $2=exit code for `restart`
  local d="$1"
  mkdir -p "$d/bin"
  cat > "$d/bin/systemctl" <<SH
#!/usr/bin/env bash
echo "systemctl \$*" >> "$d/calls.log"
case "\$*" in
  *is-active*) exit 0 ;;
  *restart*)   exit $2 ;;
esac
exit 0
SH
  chmod +x "$d/bin/systemctl"
  : > "$d/calls.log"
}

run_it() { # $1=dir
  local d="$1"
  PATH="$d/bin:$PATH" SYSTEMD_USER_DIR="$d/units" bash "$SCRIPT" >"$d/out.log" 2>"$d/err.log"
  echo $?
}

test_restarts_dashboards_that_are_already_active() {
  local d; d="$(setup_dir)"; stub_systemctl "$d" 0
  local rc; rc="$(run_it "$d")"
  assert_eq "exits 0" "$rc" "0"
  assert_eq "default restarted even though it reports active" \
    "$(grep -c 'systemctl --user restart hermes-dashboard.service' "$d/calls.log")" "1"
  assert_eq "every dashboard restarted" \
    "$(grep -c 'systemctl --user restart hermes-dashboard' "$d/calls.log")" "3"
}

test_never_restarts_non_dashboard_units() {
  local d; d="$(setup_dir)"; stub_systemctl "$d" 0
  run_it "$d" >/dev/null
  assert_eq "gateway untouched" "$(grep -c 'hermes-gateway' "$d/calls.log")" "0"
}

test_a_failed_restart_does_not_abort_the_rest() {
  # One wedged dashboard must not leave the others on stale code.
  local d; d="$(setup_dir)"; stub_systemctl "$d" 1
  local rc; rc="$(run_it "$d")"
  assert_eq "all three still attempted" \
    "$(grep -c 'systemctl --user restart hermes-dashboard' "$d/calls.log")" "3"
  assert_eq "failure is reported on stderr" \
    "$(grep -c 'restart failed' "$d/err.log")" "3"
  assert_eq "still exits 0 so the update run completes" "$rc" "0"
}

test_restarts_dashboards_that_are_already_active
test_never_restarts_non_dashboard_units
test_a_failed_restart_does_not_abort_the_rest
finish
