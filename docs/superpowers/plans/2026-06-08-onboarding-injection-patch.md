# First-Run Identity Onboarding via Hermes Native Injection — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver the default agent's first-run identity interview through Hermes's once-only first-message injection (overriding `profile_build_directive()` in `agent/onboarding.py`) instead of seeding it into `SOUL.md`, eliminating the per-turn re-injection that caused the interview to restart.

**Architecture:** Three vendored pieces in the install repo — a plain-text directive (`templates/onboarding/profile-build-directive.md`), a minimal default persona (`templates/souls/default.md`), and an idempotent patcher (`scripts/10-patch-onboarding.sh`) that copies the directive to `~/.hermes/`, appends a marker-guarded override to `onboarding.py`, and restarts gateways. `08-install-souls.sh` is updated to seed the minimal persona; the override falls through to Hermes's stock onboarding for preset/customized agents.

**Tech Stack:** Bash, Python 3 (heredoc patcher, matching `07-patch-cron-brain.sh`), Markdown. Target host: Ubuntu VPS, hermes-agent v0.16.0 editable install at `~/.hermes/hermes-agent`.

**Reference (spec):** `docs/superpowers/specs/2026-06-08-onboarding-injection-patch-design.md`

---

## File Structure

- `templates/onboarding/profile-build-directive.md` (new) — the interview prose, installed to `~/.hermes/ollie-onboarding-directive.txt`.
- `templates/souls/default.md` (new) — minimal "You are Ollie" persona stub, marker `OLLIE-SOUL-DEFAULT`.
- `templates/souls/default-onboarding.md` (delete) — the old every-message bootstrap.
- `scripts/10-patch-onboarding.sh` (new) — idempotent installer/patcher.
- `scripts/08-install-souls.sh` (modify) — seed `default.md`; recognize `OLLIE-SOUL-DEFAULT`; update message.
- `README.md` (modify) — add step 10.

---

### Task 1: Directive text + minimal default persona

**Files:**
- Create: `templates/onboarding/profile-build-directive.md`
- Create: `templates/souls/default.md`
- Delete: `templates/souls/default-onboarding.md`

- [ ] **Step 1: Write the directive text**

Create `templates/onboarding/profile-build-directive.md` with exactly this content:

```markdown
[System note: This is the operator's very first message. You are "Ollie", their
brand-new personal agent, and your identity isn't saved yet — your job right now is
to run a short, friendly setup interview, then save the result. "Ollie" is only a
placeholder name; whatever they choose replaces it everywhere.

Ask these five questions ONE AT A TIME, in order — ask one, wait for the answer,
then ask the next. Keep it conversational and offer the example where it helps.
  1. Name — "I'm 'Ollie' by default — keep that, or call me something else?"
  2. Personality — "What personality should I have — tone, vibe, any quirks?
     (e.g. 'professional but warm, with a dry, understated sense of humor')"
  3. Mission — "What's my main mission — what are you mostly here for me to do?
     (e.g. 'be the lead agent for my business, ACME Co, and help run day-to-day ops')"
  4. Communication — "How should I communicate — brief and direct, or detailed and
     thorough? Any format you prefer? (e.g. 'detailed, with a short bullet summary up top')"
  5. Hard rules — "Any hard rules — things I should always or never do?
     (e.g. 'never make things up — if you're unsure, say so')"

When all five are answered, save your identity:
  1. Compose your finalized persona as second-person prose ("You are <name>, …")
     reflecting their answers to all five questions.
  2. Write it to a temporary file with your file-writing tool (e.g. /tmp/ollie-persona.md).
  3. Run exactly this one command — it saves your persona AND updates your dashboard
     name; do NOT edit SOUL.md yourself:
       ollie-set-identity --name "<the name they chose>" --soul-file /tmp/ollie-persona.md
  4. After it reports success, briefly confirm what you saved, then continue normally.

If the operator declines or asks to skip setup: don't push — write a sensible default
persona (named with whatever name they gave, or "Ollie") to /tmp/ollie-persona.md and
run the same ollie-set-identity command, so an identity is always saved.]
```

- [ ] **Step 2: Write the minimal default persona**

Create `templates/souls/default.md` with exactly this content:

```markdown
# Ollie — Agent Persona

<!-- OLLIE-SOUL-DEFAULT — minimal starter persona; replaced when identity setup completes. -->

You are **Ollie**, this operator's personal agent. Your personality and mission
aren't fully defined yet — you'll learn them directly from the operator and then
update this file. Until then: be helpful, be honest, and keep a light, friendly tone.
```

- [ ] **Step 3: Delete the old bootstrap template**

```bash
git rm templates/souls/default-onboarding.md
```

- [ ] **Step 4: Verify content and marker**

Run:
```bash
grep -c "ollie-set-identity --name" templates/onboarding/profile-build-directive.md
grep -c "OLLIE-SOUL-DEFAULT" templates/souls/default.md
test ! -f templates/souls/default-onboarding.md && echo "old template removed"
```
Expected: `1`, `1`, `old template removed`.

- [ ] **Step 5: Commit**

```bash
git add templates/onboarding/profile-build-directive.md templates/souls/default.md
git commit -m "feat: vendored onboarding directive text + minimal default persona"
```

---

### Task 2: The patcher — `scripts/10-patch-onboarding.sh`

**Files:**
- Create: `scripts/10-patch-onboarding.sh`

- [ ] **Step 1: Write the patcher script**

Create `scripts/10-patch-onboarding.sh` with exactly this content:

```bash
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
import importlib, agent.onboarding as o
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
```

- [ ] **Step 2: Make executable**

```bash
chmod +x scripts/10-patch-onboarding.sh
```

- [ ] **Step 3: Lint the script**

Run:
```bash
bash -n scripts/10-patch-onboarding.sh && echo "syntax OK"
command -v shellcheck >/dev/null && shellcheck scripts/10-patch-onboarding.sh || echo "(shellcheck not installed; bash -n passed)"
```
Expected: `syntax OK` (and no shellcheck errors if installed).

- [ ] **Step 4: Verify the embedded Python override compiles in isolation**

Run (extracts the heredoc body between the markers and compiles it as a module on top of a stub `profile_build_directive`):
```bash
python3 - <<'PY'
import re, pathlib, py_compile, tempfile, textwrap
s = pathlib.Path("scripts/10-patch-onboarding.sh").read_text()
m = re.search(r"# >>> OLLIE-IDENTITY-ONBOARDING.*?# <<< OLLIE-IDENTITY-ONBOARDING <<<", s, re.S)
assert m, "marker block not found"
stub = "def profile_build_directive():\n    return 'x'\n"
body = stub + m.group(0)
p = tempfile.NamedTemporaryFile("w", suffix=".py", delete=False)
p.write(body); p.close()
py_compile.compile(p.name, doraise=True)
print("override block compiles")
PY
```
Expected: `override block compiles`.

- [ ] **Step 5: Commit**

```bash
git add scripts/10-patch-onboarding.sh
git commit -m "feat: 10-patch-onboarding.sh — once-only identity interview via onboarding.py override"
```

---

### Task 3: Update `08-install-souls.sh` for the minimal default persona

**Files:**
- Modify: `scripts/08-install-souls.sh`

- [ ] **Step 1: Point the default install at `default.md`**

In `scripts/08-install-souls.sh`, change the default-agent install line (currently
referencing `default-onboarding.md`) and the existence guard at the top.

Replace the guard near the top:
```bash
if [[ ! -f "${SOULS_SRC}/default-onboarding.md" ]]; then
  echo "error: vendored souls not found at ${SOULS_SRC}" >&2
  exit 1
fi
```
with:
```bash
if [[ ! -f "${SOULS_SRC}/default.md" ]]; then
  echo "error: vendored souls not found at ${SOULS_SRC}" >&2
  exit 1
fi
```

Replace the default-agent install call:
```bash
echo "==> default agent: ~/.hermes/SOUL.md"
install_soul "${SOULS_SRC}/default-onboarding.md" "${HERMES_HOME}/SOUL.md" "default (onboarding)"
```
with:
```bash
echo "==> default agent: ~/.hermes/SOUL.md"
install_soul "${SOULS_SRC}/default.md" "${HERMES_HOME}/SOUL.md" "default (Ollie stub)"
```

- [ ] **Step 2: Recognize the new marker in `soul_is_replaceable()`**

In the `soul_is_replaceable()` function, change the marker grep so an existing
minimal-default stub is treated as replaceable (and keep the old bootstrap marker so
boxes seeded with a v1–v6 bootstrap upgrade cleanly):
```bash
  if grep -qE 'OLLIE-SOUL-BOOTSTRAP|OLLIE-PRESET-SOUL' "$f"; then
```
becomes:
```bash
  if grep -qE 'OLLIE-SOUL-BOOTSTRAP|OLLIE-SOUL-DEFAULT|OLLIE-PRESET-SOUL' "$f"; then
```

- [ ] **Step 3: Update the closing message**

Replace the closing echo block:
```bash
echo "✓ SOUL provisioning complete."
echo "  The default agent runs its first-run identity setup on the next NEW chat,"
echo "  then rewrites its own SOUL.md. Re-run after adding a profile (03) or after"
echo "  editing a preset in templates/souls/."
```
with:
```bash
echo "✓ SOUL provisioning complete."
echo "  The default agent starts as 'Ollie' (minimal persona). Its first-run identity"
echo "  interview is delivered by 10-patch-onboarding.sh on the first chat of a fresh"
echo "  install, then saved via ollie-set-identity. Re-run after adding a profile (03)"
echo "  or after editing a preset in templates/souls/."
```

- [ ] **Step 4: Verify the script still parses and references the new file**

Run:
```bash
bash -n scripts/08-install-souls.sh && echo "syntax OK"
grep -c "default\.md" scripts/08-install-souls.sh
grep -c "OLLIE-SOUL-DEFAULT" scripts/08-install-souls.sh
grep -c "default-onboarding\.md" scripts/08-install-souls.sh
```
Expected: `syntax OK`, then `2` (the existence guard + the install call both reference `default.md`), `1` (marker added to the grep alternation), `0` (no remaining reference to the deleted file).

- [ ] **Step 5: Commit**

```bash
git add scripts/08-install-souls.sh
git commit -m "feat: 08 seeds minimal Ollie persona; recognize OLLIE-SOUL-DEFAULT marker"
```

---

### Task 4: README — add step 10

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add the step-10 invocation**

In `README.md`, immediately after the `bash scripts/09-install-identity-sync.sh` line,
add:
```bash
bash scripts/10-patch-onboarding.sh
```

If the `09` line has a surrounding explanatory sentence, add a parallel one for `10`,
e.g.: "`10-patch-onboarding.sh` — wires the default agent's first-run identity
interview into Hermes's once-only onboarding channel (re-apply after `hermes update`)."

- [ ] **Step 2: Verify**

Run:
```bash
grep -n "10-patch-onboarding.sh" README.md
```
Expected: at least one line, positioned after the `09` reference.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: add step 10 (onboarding patch) to README install sequence"
```

---

### Task 5: On-box deploy + fresh-install validation (controller)

**Files:** none (operational — run by the controller, not a subagent).

This task simulates a fresh install on the existing box (which already has sessions, so
the once-ever gate would otherwise never fire) and verifies the interview runs once
without restarting.

- [ ] **Step 1: Sync the repo branch to the box**

Push the four new/changed files to `~/ollie-hermes-install/` on the box (templates/,
scripts/08, scripts/10, README), via the established scp transport.

- [ ] **Step 2: Re-seed the minimal default persona and apply the patch**

```bash
bash ~/ollie-hermes-install/scripts/08-install-souls.sh   # may need SOUL.md reset first if customized
bash ~/ollie-hermes-install/scripts/10-patch-onboarding.sh
```
Expected: `08` installs the default Ollie stub; `10` installs the directive, appends the
override (or reports already-applied), compiles, and restarts the gateway.

- [ ] **Step 3: Simulate a fresh install (clear the once-ever gate)**

On the box: stop the default gateway; clear conversation sessions/messages from
`~/.hermes/state.db`; remove `onboarding.seen.profile_build_offered` from
`~/.hermes/config.yaml`; reset `~/.hermes/SOUL.md` to the minimal stub; restart the
gateway. (Exact commands authored at execution time against the live DB/config schema.)

- [ ] **Step 4: Run the interview from the dashboard**

Send a first message; answer all five questions, choosing a non-default name (e.g.
"Billie"). Assert:
- progresses through all five questions **without restarting or re-asking the name**;
- keeps the chosen name;
- finishes by running `ollie-set-identity`;
- `~/.hermes/SOUL.md` now holds the chosen persona (no `OLLIE-SOUL-DEFAULT` marker);
- the dashboard chip + upper-left name auto-update to the chosen name.

- [ ] **Step 5: Idempotency + preset fall-through checks**

```bash
bash ~/ollie-hermes-install/scripts/10-patch-onboarding.sh   # → "already applied — skipping"
```
And confirm a preset gateway (paige) does NOT trigger the identity interview: its
`SOUL.md` carries a real persona with no `OLLIE-SOUL-DEFAULT` marker, so the override
falls through to Hermes's stock onboarding.

- [ ] **Step 6: Report results**

Summarize what happened in the live chat (the actual transcript), the final `SOUL.md`,
and the dashboard label. Do not claim success without the on-box evidence.
