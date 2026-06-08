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
# the chosen name, loops).
#
# The dashboard talks to the gateway's api_server platform, which has its OWN agent
# executor (APIServerAdapter._run_agent -> _create_agent -> AIAgent). Hermes's
# built-in first-message onboarding lives in gateway/run.py's _handle_message_with_agent
# and only runs for MESSAGING platforms (Telegram/Discord/Slack) — the dashboard never
# reaches it. So the only channel that ever reached the dashboard agent was SOUL.md
# (every message). We need a ONCE-only channel on the api_server path.
#
# api_server._run_agent threads an `ephemeral_system_prompt` straight to the agent for
# THAT run only. We wrap _run_agent so that, when the caller supplied no ephemeral
# prompt AND the default agent's SOUL.md is still the OLLIE-SOUL-DEFAULT stub AND our
# once-ever flag is unset, it injects the interview directive and marks the flag. The
# directive is delivered exactly once, on the dashboard's first message — no per-turn
# re-injection, no restart. (We also override agent/onboarding.py::profile_build_directive
# so the SAME interview drives messaging-platform onboarding, for parity.)
#
# Both overrides are APPENDED as marker-guarded blocks (Python binds the name/method to
# the last definition), so they are append-only, line-number-independent, and survive
# upstream edits. Re-apply after every `hermes update`. Same model as 07-patch-cron-brain.sh.

set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  echo "error: run as the service user, not root" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIRECTIVE_SRC="${SCRIPT_DIR}/../templates/onboarding/profile-build-directive.md"
HERMES_HOME="${HOME}/.hermes"
ONBOARDING="${HERMES_HOME}/hermes-agent/agent/onboarding.py"
API_SERVER="${HERMES_HOME}/hermes-agent/gateway/platforms/api_server.py"
DIRECTIVE_DEST="${HERMES_HOME}/ollie-onboarding-directive.txt"

if [[ ! -f "${DIRECTIVE_SRC}" ]]; then
  echo "error: vendored directive not found at ${DIRECTIVE_SRC}" >&2
  exit 1
fi
if [[ ! -f "${ONBOARDING}" || ! -f "${API_SERVER}" ]]; then
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

echo "==> step 2b: inject the interview once via api_server _run_agent (the dashboard path)"
# The dashboard's api_server executor never runs Hermes's onboarding gate, so we inject
# our directive through its per-run ephemeral_system_prompt hook — exactly once, while
# SOUL is still the default stub and our flag is unset.
if grep -q 'OLLIE-IDENTITY-ONBOARDING-APISERVER' "${API_SERVER}"; then
  echo "    already applied — skipping"
else
  cp -n "${API_SERVER}" "${API_SERVER}.bak.onboard" 2>/dev/null || true
  cat >> "${API_SERVER}" <<'PYEOF'


# >>> OLLIE-IDENTITY-ONBOARDING-APISERVER (idempotent; re-applied after hermes update) >>>
import os as _ollie_os2
from pathlib import Path as _OlliePath

_OLLIE_ONBOARD_FLAG = "ollie_identity_onboarded"
_ollie_orig_run_agent = APIServerAdapter._run_agent


def _ollie_onboarding_ephemeral():
    """Return the identity-interview directive exactly once, on the dashboard's first
    message — while the default agent's SOUL.md is still the OLLIE-SOUL-DEFAULT stub and
    our once-ever flag is unset — then mark the flag. Returns None otherwise (incl. preset
    agents whose SOUL carries a real persona). Best-effort: any error -> None (no injection).
    """
    try:
        home = _ollie_os2.environ.get("HERMES_HOME") or _ollie_os2.path.expanduser("~/.hermes")
        with open(_ollie_os2.path.join(home, "SOUL.md"), encoding="utf-8") as _f:
            if "OLLIE-SOUL-DEFAULT" not in _f.read():
                return None  # identity already personalized (or a preset agent)
        from gateway.run import _load_gateway_config
        from agent.onboarding import is_seen, mark_seen
        cfg = _load_gateway_config()
        if is_seen(cfg, _OLLIE_ONBOARD_FLAG):
            return None  # already offered once
        with open(_ollie_os2.path.join(home, "ollie-onboarding-directive.txt"), encoding="utf-8") as _f:
            directive = _f.read().strip()
        if not directive:
            return None
        mark_seen(_OlliePath(home) / "config.yaml", _OLLIE_ONBOARD_FLAG)
        return directive
    except Exception:
        return None


async def _ollie_run_agent(self, *args, **kwargs):
    # ephemeral_system_prompt is always passed by keyword by every caller; only inject
    # when the caller supplied none of their own.
    if not kwargs.get("ephemeral_system_prompt"):
        _inj = _ollie_onboarding_ephemeral()
        if _inj:
            kwargs["ephemeral_system_prompt"] = _inj
    return await _ollie_orig_run_agent(self, *args, **kwargs)


APIServerAdapter._run_agent = _ollie_run_agent
# <<< OLLIE-IDENTITY-ONBOARDING-APISERVER <<<
PYEOF
  echo "    appended api_server injection block"
fi

echo "==> step 3: byte-compile check (syntax)"
python3 -c "import py_compile, sys; py_compile.compile('${ONBOARDING}', doraise=True); print('    onboarding.py compiles')"
python3 -c "import py_compile, sys; py_compile.compile('${API_SERVER}', doraise=True); print('    api_server.py compiles')"

echo "==> step 4: verify the overrides are the live bindings"
( cd "${HERMES_HOME}/hermes-agent" && python3 - <<'PY'
import agent.onboarding as o
src = o.profile_build_directive.__doc__ or ""
print("    profile_build_directive:", "OVERRIDE" if "Ollie identity interview" in src else "UPSTREAM")
try:
    from gateway.platforms.api_server import APIServerAdapter
    print("    api_server._run_agent:", "OVERRIDE" if APIServerAdapter._run_agent.__name__ == "_ollie_run_agent" else "UPSTREAM")
except Exception as _e:
    print("    api_server._run_agent: (import skipped:", type(_e).__name__, ")")
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
