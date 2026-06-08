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
SESSION_PY="${HERMES_HOME}/hermes-agent/gateway/session.py"
DIRECTIVE_DEST="${HERMES_HOME}/ollie-onboarding-directive.txt"

if [[ ! -f "${DIRECTIVE_SRC}" ]]; then
  echo "error: vendored directive not found at ${DIRECTIVE_SRC}" >&2
  exit 1
fi
if [[ ! -f "${ONBOARDING}" || ! -f "${SESSION_PY}" ]]; then
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

echo "==> step 2b: override SessionStore.has_any_sessions() in gateway/session.py"
# The first-message onboarding gate in run.py is `not history and not
# has_any_sessions()`, where has_any_sessions() is `session_count() > 1`. In this
# deployment the dashboard/orchestrator create their own api_server sessions, so the
# count is always >1 at first contact and the gate never fires. has_any_sessions() has
# a SINGLE caller (that gate), so we safely make it report "no sessions" WHILE the
# default agent's SOUL is still the OLLIE-SOUL-DEFAULT stub — letting onboarding fire
# once regardless of poller sessions. Once ollie-set-identity writes a real SOUL
# (marker gone), it reverts to the genuine count.
if grep -q 'OLLIE-IDENTITY-ONBOARDING-GATE' "${SESSION_PY}"; then
  echo "    already applied — skipping"
else
  cp -n "${SESSION_PY}" "${SESSION_PY}.bak.onboard" 2>/dev/null || true
  cat >> "${SESSION_PY}" <<'PYEOF'


# >>> OLLIE-IDENTITY-ONBOARDING-GATE (idempotent; re-applied after hermes update) >>>
import os as _ollie_os2
_ollie_orig_has_any_sessions = SessionStore.has_any_sessions


def _ollie_has_any_sessions(self) -> bool:
    """While the default agent's identity is still the un-personalized stub, report
    'no sessions' so gateway/run.py's first-message onboarding gate fires even when
    background dashboard/poller sessions exist. The profile_build_offered flag still
    limits the interview to once. Once ollie-set-identity writes a real SOUL (the
    OLLIE-SOUL-DEFAULT marker is gone), behave exactly as upstream.
    """
    try:
        home = _ollie_os2.environ.get("HERMES_HOME") or _ollie_os2.path.expanduser("~/.hermes")
        with open(_ollie_os2.path.join(home, "SOUL.md"), encoding="utf-8") as _f:
            if "OLLIE-SOUL-DEFAULT" in _f.read():
                return False
    except Exception:
        pass
    return _ollie_orig_has_any_sessions(self)


SessionStore.has_any_sessions = _ollie_has_any_sessions
# <<< OLLIE-IDENTITY-ONBOARDING-GATE <<<
PYEOF
  echo "    appended gate override block"
fi

echo "==> step 3: byte-compile check (syntax)"
python3 -c "import py_compile, sys; py_compile.compile('${ONBOARDING}', doraise=True); print('    onboarding.py compiles')"
python3 -c "import py_compile, sys; py_compile.compile('${SESSION_PY}', doraise=True); print('    session.py compiles')"

echo "==> step 4: verify the overrides are the live bindings"
( cd "${HERMES_HOME}/hermes-agent" && python3 - <<'PY'
import agent.onboarding as o
src = o.profile_build_directive.__doc__ or ""
print("    profile_build_directive:", "OVERRIDE" if "Ollie identity interview" in src else "UPSTREAM")
try:
    from gateway.session import SessionStore
    doc = SessionStore.has_any_sessions.__doc__ or ""
    print("    has_any_sessions:", "OVERRIDE" if "un-personalized stub" in doc else "UPSTREAM")
except Exception as _e:
    print("    has_any_sessions: (import skipped:", type(_e).__name__, ")")
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
