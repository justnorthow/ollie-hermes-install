#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/assert.sh"
FLEETCTL="$HERE/../templates/bin/ollie-fleetctl"
PY="$(command -v python3 || command -v python || true)"
if [ -z "$PY" ]; then echo "FAIL: python3 not found on PATH (required to run ollie-fleetctl)"; exit 1; fi

# Capture the dry-run step names for a component into a newline list.
steps_for() { "$PY" "$FLEETCTL" update "$1" --dry-run 2>/dev/null | grep -oE '"name": ?"[^"]+"' | sed -E 's/.*"name": ?"([^"]+)".*/\1/'; }
has_step()  { steps_for "$1" | grep -qx "$2"; }

# CURRENT behavior (pre-Tasks-2-4):
test_hermes_current() {
  assert_eq "hermes has git-pull-install-repo" "$(has_step hermes git-pull-install-repo && echo y)" "y"
  assert_eq "hermes has hermes-update"         "$(has_step hermes hermes-update && echo y)" "y"
  assert_eq "hermes has reinstall-cortex-plugin" "$(has_step hermes reinstall-cortex-plugin && echo y)" "y"
  assert_eq "hermes has repatch-cron-brain"    "$(has_step hermes repatch-cron-brain && echo y)" "y"
  assert_eq "hermes has reinstall-souls"       "$(has_step hermes reinstall-souls && echo y)" "y"
}
# Stack update must re-run 06 (restages compose + refreshes pins), not a bare compose pull/up.
test_stack_reinstalls_06() {
  assert_eq "stack has reinstall-stack" "$(has_step stack reinstall-stack && echo y)" "y"
  assert_eq "stack no longer bare compose-pull" "$(has_step stack compose-pull && echo y)" ""
}
test_orch_current() {
  assert_eq "orchestrator has git-pull-orchestrator" "$(has_step orchestrator git-pull-orchestrator && echo y)" "y"
  assert_eq "orchestrator has restart-orchestrator"  "$(has_step orchestrator restart-orchestrator && echo y)" "y"
}
test_hermes_current
test_stack_reinstalls_06
test_orch_current
finish
