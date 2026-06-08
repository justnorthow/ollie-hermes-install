#!/usr/bin/env bash
# 10-patch-onboarding.sh — deliver the Ollie first-run identity interview through
# Hermes's once-only first-message onboarding channel.
#
# Run as: the service user (ollie by default; NOT root) — patches files under
# ~/.hermes/hermes-agent and writes ~/.hermes/ollie-onboarding-directive.txt.
# Idempotent: safe to re-run; detects the already-applied marker.
#
# Why this patch exists
# ---------------------
# Hermes injects SOUL.md into the system prompt on EVERY message. Seeding the
# first-run interview into SOUL.md therefore re-asserts "start setup" every turn,
# and the agent intermittently restarts the interview (re-asks the name, reverts
# the chosen name, loops). gateway/run.py instead injects onboarding directives
# exactly ONCE, on the first message of a fresh install (gated by `not history and
# not has_any_sessions()`), via agent/onboarding.py::profile_build_directive().
# Delivering our interview through that channel makes it run as a normal
# conversation off history — no per-turn re-injection, no restart.
#
# We override profile_build_directive() by APPENDING a marker-guarded redefinition
# to the end of onboarding.py. Python binds the module name to the last definition,
# so the call site's `from agent.onboarding import profile_build_directive` picks up
# ours. Append-only and line-number-independent, so it survives upstream edits.
#
# Re-apply after every `hermes update` (it rewrites onboarding.py). Same maintenance
# model as 07-patch-cron-brain.sh.

set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  echo "error: run as the service user, not root" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIRECTIVE_SRC="${SCRIPT_DIR}/../templates/onboarding/profile-build-directive.md"
HERMES_HOME="${HOME}/.hermes"
ONBOARDING="${HERMES_HOME}/hermes-agent/agent/onboarding.py"
DIRECTIVE_DEST="${HERMES_HOME}/ollie-onboarding-directive.txt"

if [[ ! -f "${DIRECTIVE_SRC}" ]]; then
  echo "error: vendored directive not found at ${DIRECTIVE_SRC}" >&2
  exit 1
fi
if [[ ! -f "${ONBOARDING}" ]]; then
  echo "error: hermes-agent not installed at ${HERMES_HOME}/hermes-agent" >&2
  echo "       run 02-install-hermes.sh first" >&2
  exit 1
fi

echo "==> step 1: install onboarding directive → ${DIRECTIVE_DEST}"
install -m 644 "${DIRECTIVE_SRC}" "${DIRECTIVE_DEST}"
echo "    installed ($(wc -c < "${DIRECTIVE_DEST}") bytes)"

echo "==> step 2: override profile_build_directive() in onboarding.py"
if grep -q 'OLLIE-IDENTITY-ONBOARDING' "${ONBOARDING}"; then
  echo "    already applied — skipping"
else
  cp -n "${ONBOARDING}" "${ONBOARDING}.bak.onboard" 2>/dev/null || true
  cat >> "${ONBOARDING}" <<'PYEOF'


# >>> OLLIE-IDENTITY-ONBOARDING (idempotent; re-applied after hermes update) >>>
import os as _ollie_os
_ollie_orig_profile_build_directive = profile_build_directive


def profile_build_directive() -> str:
    """Override: deliver the Ollie identity interview on first contact.

    Falls back to Hermes's built-in user-profile onboarding when this gateway's
    agent already carries a real (non-default) persona, or when the directive
    file is missing — so preset agents (paige/karl) and customized agents are
    never interrogated for an identity they already have.
    """
    home = _ollie_os.environ.get("HERMES_HOME") or _ollie_os.path.expanduser("~/.hermes")
    soul_path = _ollie_os.path.join(home, "SOUL.md")
    try:
        with open(soul_path, encoding="utf-8") as _f:
            _soul = _f.read()
        if _soul.strip() and "OLLIE-SOUL-DEFAULT" not in _soul:
            return _ollie_orig_profile_build_directive()
    except FileNotFoundError:
        pass
    try:
        _p = _ollie_os.path.join(home, "ollie-onboarding-directive.txt")
        with open(_p, encoding="utf-8") as _f:
            return "\n\n" + _f.read().strip()
    except Exception:
        return _ollie_orig_profile_build_directive()
# <<< OLLIE-IDENTITY-ONBOARDING <<<
PYEOF
  echo "    appended override block"
fi

echo "==> step 3: byte-compile check (syntax)"
python3 -c "import py_compile, sys; py_compile.compile('${ONBOARDING}', doraise=True); print('    onboarding.py compiles')"

echo "==> step 4: verify the override is the live binding"
( cd "${HERMES_HOME}/hermes-agent" && python3 - <<'PY'
import agent.onboarding as o
src = o.profile_build_directive.__doc__ or ""
print("    live profile_build_directive doc:", "OVERRIDE" if "Ollie identity interview" in src else "UPSTREAM")
PY
) || echo "    (live-binding check skipped; import needs hermes deps)"

echo "==> step 5: restart any running gateways so the override loads"
for unit in $(systemctl --user list-units --no-legend --plain 'hermes-gateway*' 2>/dev/null | awk '{print $1}'); do
  echo "    restarting ${unit}"
  systemctl --user restart "${unit}"
done

echo
echo "✓ Onboarding-injection patch applied."
echo "  The default agent runs its identity interview ONCE, on the first message of a"
echo "  fresh install, then saves SOUL.md via ollie-set-identity. Re-apply after"
echo "  'hermes update'. To edit the interview, change"
echo "  templates/onboarding/profile-build-directive.md and re-run this script."
