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

# CURRENT behavior (post-Tasks-2-4):
test_hermes_reapply() {
  assert_eq "hermes has git-pull-install-repo" "$(has_step hermes git-pull-install-repo && echo y)" "y"
  assert_eq "hermes has hermes-update"         "$(has_step hermes hermes-update && echo y)" "y"
  assert_eq "hermes has reinstall-cortex-plugin" "$(has_step hermes reinstall-cortex-plugin && echo y)" "y"
  assert_eq "hermes has repatch-cron-brain"    "$(has_step hermes repatch-cron-brain && echo y)" "y"
  assert_eq "hermes has reinstall-souls"       "$(has_step hermes reinstall-souls && echo y)" "y"
  assert_eq "hermes re-applies identity-sync (09)" "$(has_step hermes reinstall-identity-sync && echo y)" "y"
  assert_eq "hermes heals dashboard units"     "$(has_step hermes heal-dashboard-units && echo y)" "y"
}
# Stack update must re-run 06 (restages compose + refreshes pins), not a bare compose pull/up.
test_stack_reinstalls_06() {
  assert_eq "stack has reinstall-stack" "$(has_step stack reinstall-stack && echo y)" "y"
  assert_eq "stack no longer bare compose-pull" "$(has_step stack compose-pull && echo y)" ""
}
# Orchestrator update must re-run 05 (restores systemd unit + HERMES_GATEWAY_KEY wiring),
# not just git-pull + pip + restart.
test_orch_reinstalls_05() {
  assert_eq "orchestrator has reinstall-orchestrator" "$(has_step orchestrator reinstall-orchestrator && echo y)" "y"
  assert_eq "orchestrator no longer bare git-pull-orchestrator" "$(has_step orchestrator git-pull-orchestrator && echo y)" ""
}
# The README's after-update section must name every script the code re-applies.
test_readme_matches_code() {
  local readme="$HERE/../README.md"
  local section; section="$(awk '/^## After a .hermes update/{f=1;next} f&&/^## /{f=0} f' "$readme")"
  for s in 04-install-cortex-plugin.sh 07-patch-cron-brain.sh 08-install-souls.sh 09-install-identity-sync.sh heal-dashboard-units.sh; do
    assert_eq "after-update section names $s" "$(printf '%s' "$section" | grep -q "$s" && echo y)" "y"
  done
}
test_hermes_reapply
test_stack_reinstalls_06
test_orch_reinstalls_05
test_readme_matches_code
finish
