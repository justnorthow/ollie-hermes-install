#!/usr/bin/env bash
# 07-patch-cron-brain.sh — let cron jobs use the cortex memory provider (brain_* tools).
#
# Run as: the service user (ollie by default; NOT root) — patches files under ~/.hermes/hermes-agent
# Idempotent: safe to re-run; detects already-applied patches.
#
# Why this patch exists
# ---------------------
# Upstream hermes-agent hard-codes `skip_memory=True` in cron/scheduler.py with
# the comment "Cron system prompts would corrupt user representations." That's
# correct for memory_save / user_profile auto-sync, but it ALSO blocks the new
# memory provider plugin system — so `brain_read`, `brain_update`, and
# `brain_append` never surface in a cron session's tool list. Result: an agent
# scripted to log to brain falls back to `write_file` (per-profile local file
# that no other agent can see) instead of cortex brain (shared across all
# agents).
#
# We want brain ops to work in cron — that's the whole point of having a cortex
# brain with a `logs/` section. Two surgical edits achieve this:
#
#   1. cron/scheduler.py: flip `skip_memory=True` → `skip_memory=False`, so the
#      provider plugin loads and its tool schemas get injected into the cron
#      agent's tool list.
#
#   2. run_agent.py: gate the post-turn `sync_all()` on platform != "cron".
#      The provider tools are still callable (so the LLM can `brain_append`),
#      but the auto-sync that would write the cron turn into the user-repr
#      memory store is suppressed — preserving the original safety property
#      that the upstream comment was protecting.
#
# Re-apply after every `hermes update`. The install playbook in
# docs/migration-notes.md covers this.

set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  echo "error: run as the service user, not root" >&2
  exit 1
fi

HERMES_AGENT_DIR="${HOME}/.hermes/hermes-agent"
SCHED="${HERMES_AGENT_DIR}/cron/scheduler.py"
RUN_AGENT="${HERMES_AGENT_DIR}/run_agent.py"

if [[ ! -f "${SCHED}" || ! -f "${RUN_AGENT}" ]]; then
  echo "error: hermes-agent not installed at ${HERMES_AGENT_DIR}" >&2
  echo "       run 02-install-hermes.sh first" >&2
  exit 1
fi

echo "==> step 1: patch cron/scheduler.py (skip_memory=True → False)"
if grep -q 'JNOW PATCH: load cortex memory provider' "${SCHED}"; then
  echo "    already applied — skipping"
else
  cp -n "${SCHED}" "${SCHED}.bak.brain" 2>/dev/null || true
  python3 - <<PY
from pathlib import Path
p = Path("${SCHED}")
src = p.read_text()
old = "skip_memory=True,  # Cron system prompts would corrupt user representations"
new = "skip_memory=False,  # JNOW PATCH: load cortex memory provider so brain_* tools surface; sync_all is gated below by platform check"
if old not in src:
    raise SystemExit("scheduler.py: anchor line not found — upstream may have changed; review 07-patch-cron-brain.sh")
p.write_text(src.replace(old, new, 1))
print("    patched")
PY
fi

echo "==> step 2: patch run_agent.py (gate sync_all on platform != cron)"
if grep -q 'JNOW PATCH: cron turns are agent-driven' "${RUN_AGENT}"; then
  echo "    already applied — skipping"
else
  cp -n "${RUN_AGENT}" "${RUN_AGENT}.bak.brain" 2>/dev/null || true
  python3 - <<PY
from pathlib import Path
p = Path("${RUN_AGENT}")
src = p.read_text()
old = """        if interrupted:
            return
        if not (self._memory_manager and final_response and original_user_message):
            return"""
new = """        if interrupted:
            return
        # JNOW PATCH: cron turns are agent-driven, not conversational — skip
        # auto-sync to memory provider so cron context never leaks into the
        # user-representation memory store.
        if getattr(self, "platform", None) == "cron":
            return
        if not (self._memory_manager and final_response and original_user_message):
            return"""
if old not in src:
    raise SystemExit("run_agent.py: anchor block not found — upstream may have changed; review 07-patch-cron-brain.sh")
p.write_text(src.replace(old, new, 1))
print("    patched")
PY
fi

echo
echo "==> step 3: restart any running gateways so the patches load"
for unit in $(systemctl --user list-units --no-legend --plain 'hermes-gateway*' 2>/dev/null | awk '{print $1}'); do
  echo "    restarting ${unit}"
  systemctl --user restart "${unit}"
done

echo
echo "✓ Cron-brain patch applied."
echo
echo "Verify by triggering a cron job that calls brain_append and checking:"
echo "    curl -s http://localhost:9120/brain/files/logs/<your-log-key> | jq .exists"
echo "should report true after the run."
