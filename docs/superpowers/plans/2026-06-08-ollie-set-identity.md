# ollie-set-identity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the fragile "agent overwrites its own SOUL.md" onboarding step with one deterministic command, `ollie-set-identity`, that atomically saves the persona AND syncs the dashboard display name via the orchestrator.

**Architecture:** A vendored host command writes the persona to the correct `SOUL.md` (clean, marker-free → loop cannot recur) and best-effort `PATCH`es the orchestrator's `displayName` (→ both dashboard labels update live). The onboarding directive is changed to: gather answers one-at-a-time → `write_file` the persona to a temp file → call the command once. A new install step drops the command on PATH and allowlists it.

**Tech Stack:** Bash, curl, the orchestrator REST API (`PATCH /v1/agents/{id}`), Hermes config (`command_allowlist`). No unit-test framework — validation is on-box scenarios (Task 5) + one manual chat smoke test.

**TDD note:** This is shell + config + a directive. "Tests" = the on-box matrix in Task 5 (exact commands + expected output). The LLM interview path is a flagged manual smoke test.

**Spec:** `docs/superpowers/specs/2026-06-08-ollie-set-identity-design.md`

**Verified facts used here:** orchestrator on `localhost:9123`, key in `~/.config/ollie-orchestrator/.env` (`ORCHESTRATOR_KEY=`), `PATCH /v1/agents/{id} {"displayName":...}` updates the label live (no restart); the agent runs as the service user with `~/.local/bin` on PATH; the Hermes venv (`~/.hermes/hermes-agent/venv/bin/python`) has `ruamel.yaml` for safe config edits.

---

### Task 1: The `ollie-set-identity` command

**Files:**
- Create: `templates/bin/ollie-set-identity`

- [ ] **Step 1: Create `templates/bin/ollie-set-identity`** with EXACTLY this content:

```bash
#!/usr/bin/env bash
# ollie-set-identity — atomically save an agent's persona to its SOUL.md and
# sync its dashboard display name via the orchestrator.
#
# Usage:
#   ollie-set-identity --name "<name>" --soul-file <path> [--id <agent_id>]
#
# The persona write is the hard requirement (non-zero exit on failure). The
# display-name update is best-effort: if the orchestrator is unreachable it warns
# and still exits 0 — the persona is what matters; the label is cosmetic and can
# be set later from the dashboard.

set -euo pipefail

NAME=""
SOUL_FILE=""
AGENT_ID="default"
ORCH_URL="${ORCH_URL:-http://localhost:9123}"
ORCH_ENV="${HOME}/.config/ollie-orchestrator/.env"

usage() {
  echo 'usage: ollie-set-identity --name "<name>" --soul-file <path> [--id <agent_id>]' >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)      NAME="${2:-}"; shift 2 ;;
    --soul-file) SOUL_FILE="${2:-}"; shift 2 ;;
    --id)        AGENT_ID="${2:-}"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

[[ -n "${NAME}" ]]      || { echo "error: --name is required" >&2; usage; exit 2; }
[[ -n "${SOUL_FILE}" ]] || { echo "error: --soul-file is required" >&2; usage; exit 2; }
[[ -f "${SOUL_FILE}" ]] || { echo "error: --soul-file not found: ${SOUL_FILE}" >&2; exit 2; }
[[ -s "${SOUL_FILE}" ]] || { echo "error: --soul-file is empty: ${SOUL_FILE}" >&2; exit 2; }

if [[ "${AGENT_ID}" == "default" ]]; then
  SOUL_DEST="${HOME}/.hermes/SOUL.md"
else
  PROFILE_DIR="${HOME}/.hermes/profiles/${AGENT_ID}"
  [[ -d "${PROFILE_DIR}" ]] || { echo "error: profile '${AGENT_ID}' not found at ${PROFILE_DIR}" >&2; exit 2; }
  SOUL_DEST="${PROFILE_DIR}/SOUL.md"
fi

# 1) Atomically install the persona (hard requirement). The file content is
#    exactly the persona, so the bootstrap marker cannot survive.
mkdir -p "$(dirname "${SOUL_DEST}")"
TMP="${SOUL_DEST}.tmp.$$"
cp "${SOUL_FILE}" "${TMP}"
chmod 644 "${TMP}"
mv -f "${TMP}" "${SOUL_DEST}"
echo "✓ persona saved → ${SOUL_DEST} ($(wc -c < "${SOUL_DEST}") bytes)"

# 2) Update the dashboard display name via the orchestrator (best-effort).
rename_status="skipped"
ORCH_KEY=""
[[ -f "${ORCH_ENV}" ]] && ORCH_KEY="$(grep -E '^ORCHESTRATOR_KEY=' "${ORCH_ENV}" | head -1 | cut -d= -f2- || true)"

if [[ -z "${ORCH_KEY}" ]]; then
  echo "    WARNING: no ORCHESTRATOR_KEY in ${ORCH_ENV}; skipping display-name update." >&2
  rename_status="no-key"
else
  payload="$(NAME="${NAME}" python3 -c 'import os,json; print(json.dumps({"displayName": os.environ["NAME"]}))')"
  set +e
  code="$(curl -sS -m 8 -o /tmp/.ollie-rename.out -w '%{http_code}' \
            -X PATCH "${ORCH_URL}/v1/agents/${AGENT_ID}" \
            -H "Authorization: Bearer ${ORCH_KEY}" \
            -H "Content-Type: application/json" \
            -d "${payload}" 2>/dev/null)"
  set -e
  if [[ "${code}" =~ ^2[0-9][0-9]$ ]]; then
    echo "✓ display name updated: ${AGENT_ID} → \"${NAME}\""
    rename_status="ok"
  else
    echo "    WARNING: display-name update failed (HTTP ${code:-none}); set it from the dashboard if needed." >&2
    rename_status="http-${code:-err}"
  fi
fi

echo "✓ identity set: id=${AGENT_ID} name=\"${NAME}\" rename=${rename_status}"
exit 0
```

- [ ] **Step 2: Syntax check**

Run: `bash -n templates/bin/ollie-set-identity && echo OK`
Expected: `OK`.

- [ ] **Step 3: Commit**

```bash
git add templates/bin/ollie-set-identity
git commit -m "feat(identity): ollie-set-identity — atomic persona save + orchestrator display-name sync"
```

---

### Task 2: `scripts/09-install-identity-sync.sh`

**Files:**
- Create: `scripts/09-install-identity-sync.sh`

- [ ] **Step 1: Create `scripts/09-install-identity-sync.sh`** with EXACTLY this content:

```bash
#!/usr/bin/env bash
# 09-install-identity-sync.sh — install the ollie-set-identity helper and let the
# agent run it without an approval prompt.
#
# Run as: the service user (ollie by default; NOT root). Idempotent.
# The display-name half needs the orchestrator (05); the SOUL-write half works
# without it. Re-run after `hermes update` (which can reset config/PATH).

set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  echo "error: run as the service user, not root" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${SCRIPT_DIR}/../templates/bin/ollie-set-identity"
DEST="${HOME}/.local/bin/ollie-set-identity"
CFG="${HOME}/.hermes/config.yaml"
VENV_PY="${HOME}/.hermes/hermes-agent/venv/bin/python"

[[ -f "${SRC}" ]] || { echo "error: ${SRC} not found" >&2; exit 1; }

echo "==> installing ollie-set-identity → ${DEST} (+ /usr/local/bin symlink)"
mkdir -p "${HOME}/.local/bin"
cp "${SRC}" "${DEST}"
chmod 755 "${DEST}"
sudo ln -sfn "${DEST}" /usr/local/bin/ollie-set-identity
echo "    linked /usr/local/bin/ollie-set-identity"

echo "==> allowlisting ollie-set-identity (so the agent runs it without an approval prompt)"
# Best-effort: a round-trip YAML edit (ruamel preserves comments/formatting).
# If anything goes wrong, the command still works — the agent just gets a
# one-time approval prompt. So we never fail the install on this.
if [[ -x "${VENV_PY}" && -f "${CFG}" ]]; then
  if "${VENV_PY}" - "${CFG}" <<'PY'
import sys
from ruamel.yaml import YAML
path = sys.argv[1]
yaml = YAML()  # round-trip: preserves comments + formatting
with open(path) as f:
    cfg = yaml.load(f)
al = cfg.get("command_allowlist")
if not isinstance(al, list):
    al = []
    cfg["command_allowlist"] = al
if "ollie-set-identity" not in al:
    al.append("ollie-set-identity")
    with open(path, "w") as f:
        yaml.dump(cfg, f)
    print("    added ollie-set-identity to command_allowlist")
else:
    print("    already in command_allowlist")
PY
  then
    # restart running gateways so they pick up the config change
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
    for unit in $(systemctl --user list-units --no-legend --plain 'hermes-gateway*' 2>/dev/null | awk '{print $1}'); do
      systemctl --user restart "${unit}" 2>/dev/null && echo "    restarted ${unit}"
    done
  else
    echo "    WARNING: could not edit command_allowlist; the agent may prompt once for approval." >&2
  fi
else
  echo "    WARNING: ${CFG} or venv python missing; skipped allowlisting (agent may prompt once)." >&2
fi

echo
echo "✓ identity-sync installed."
echo "  ollie-set-identity --name \"<name>\" --soul-file <path> [--id default]"
echo "  (display-name sync needs the orchestrator from 05-install-orchestrator.sh)"
```

- [ ] **Step 2: Make executable + syntax check**

Run: `chmod +x scripts/09-install-identity-sync.sh && bash -n scripts/09-install-identity-sync.sh && echo OK`
Expected: `OK`.

- [ ] **Step 3: Commit**

```bash
git add scripts/09-install-identity-sync.sh
git commit -m "feat(09): install ollie-set-identity + allowlist it for the agent"
```

---

### Task 3: Switch the onboarding directive to use the command

**Files:**
- Modify (full rewrite): `templates/souls/default-onboarding.md`

- [ ] **Step 1: Replace the entire file** with EXACTLY this content (bumps marker to v4; steps 4–5 now use `ollie-set-identity`):

```markdown
# Ollie — Agent Persona

<!-- OLLIE-SOUL-BOOTSTRAP v4 — replaced the moment setup completes; self-clears. -->

You are **Ollie**, this user's personal agent. You're brand new — your
personality, mission, and working style aren't defined yet. The operator gets
to shape who you become.

## FIRST-RUN SETUP (your top priority until it is done)

This notice means your identity is NOT yet saved. **The way to finish setup is to
run the `ollie-set-identity` command** (step 5) — it saves your persona AND
updates your dashboard name in one step. Until you run it, this notice reappears
in your prompt on EVERY message, so you will keep restarting setup. Run it as soon
as you reasonably can.

Do this at the very start of your first conversation, before any other onboarding
or task:

1. Greet briefly as Ollie; mention they can rename you and that `/help` lists commands.
2. Say you'd like to ask a few quick questions so you can become *their* agent —
   they can skip or change any answer later.
3. Ask these ONE AT A TIME — ask a question, wait for the answer, then ask the
   next. Keep it conversational, and offer an example where it helps so they're
   not staring at a blank prompt:
   - **Name** — "First: I'm 'Ollie' by default — keep that, or call me something else?"
   - **Personality** — "What personality should I have — tone, vibe, any quirks?
     (e.g. 'professional but warm, with a dry, understated sense of humor')"
   - **Mission** — "What's my main mission — what are you mostly here for me to do?
     (e.g. 'be the lead agent for my business, ACME Co, and help run day-to-day ops')"
   - **Communication** — "How should I communicate — brief and direct, or detailed
     and thorough? Any format you prefer? (e.g. 'detailed, with a short bullet summary up top')"
   - **Hard rules** — "Last one: any hard rules — things I should always or never do?
     (e.g. 'never make things up — if you're unsure, say so')"
4. When you have the answers, compose your finalized persona as second-person
   prose ("You are …") covering name, personality, mission, communication style,
   and rules. Write it to a temp file with your file-writing tool — e.g.
   `write_file` to `/tmp/ollie-persona.md`. (Do this via the file tool, not the
   shell, so quotes are safe.)
5. Then run this ONE command — it saves your persona AND updates your dashboard
   name. Do NOT edit SOUL.md yourself; this command does it correctly:
   `ollie-set-identity --name "<the name they chose>" --soul-file /tmp/ollie-persona.md`
   Running this is what ends setup. After it reports success, briefly confirm to
   the user what you saved.

If they decline or seem uninterested: don't push — but still finish setup so this
stops repeating. Write a sensible default persona (a friendly, capable assistant
named Ollie) to `/tmp/ollie-persona.md` and run
`ollie-set-identity --name "Ollie" --soul-file /tmp/ollie-persona.md`.

Once setup is done, proceed normally — any built-in "tell me about you"
user-profile step comes AFTER your own identity is saved.
```

- [ ] **Step 2: Confirm the marker + command are present**

Run: `grep -q 'OLLIE-SOUL-BOOTSTRAP v4' templates/souls/default-onboarding.md && grep -q 'ollie-set-identity --name' templates/souls/default-onboarding.md && echo OK`
Expected: `OK`.

- [ ] **Step 3: Commit**

```bash
git add templates/souls/default-onboarding.md
git commit -m "feat(souls): onboarding finalizes via ollie-set-identity (deterministic save + rename)"
```

---

### Task 4: README step 11

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Read `README.md`**, find the quick-start fenced block (it currently ends with `bash scripts/08-install-souls.sh`). Insert this step immediately after that line, inside the same fenced block:

```bash

# 11. Install the identity-sync helper (ollie-set-identity): lets the agent save
#     its persona + update its dashboard display name in one deterministic step
#     during onboarding. Needs the orchestrator (step 7) for the rename half.
bash scripts/09-install-identity-sync.sh
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs(readme): add step 11 — install identity-sync helper"
```

---

### Task 5: On-box validation + deploy — CONTROLLER

Use the BOM/CRLF-safe transfer helper:

```powershell
function Send-And-Run { param([string]$LocalSh,[string]$RemoteName)
  $txt=[System.IO.File]::ReadAllText($LocalSh).Replace("`r","").TrimStart([char]0xFEFF)
  $tmp=[System.IO.Path]::Combine($env:TEMP,"clean_$RemoteName")
  [System.IO.File]::WriteAllText($tmp,$txt,(New-Object System.Text.UTF8Encoding($false)))
  scp -q $tmp "ollie:/tmp/$RemoteName" 2>&1 | Out-Null
  ssh ollie "bash /tmp/$RemoteName" 2>&1 }
```

> **Coordinate with the user first** — only mutate box state between their tests; announce when the box is clean. Do NOT run `08`/reset while they're mid-onboarding-test.

- [ ] **Step 1: Push branch files to the box** (BOM/CRLF-safe `scp`), preserving paths: `templates/bin/ollie-set-identity`, `scripts/09-install-identity-sync.sh`, `templates/souls/default-onboarding.md`. Verify: `ls ~/ollie-hermes-install/templates/bin/ ~/ollie-hermes-install/scripts/09-install-identity-sync.sh`.

- [ ] **Step 2: Run `09` on the box**, then run the validation harness (via Send-And-Run):

```bash
set +e
SRC=/home/ubuntu/ollie-hermes-install
PASS=0; FAIL=0
chk(){ if eval "$2"; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }

bash "$SRC/scripts/09-install-identity-sync.sh" >/tmp/i09.log 2>&1; echo "09 rc=$?"; tail -3 /tmp/i09.log
chk "helper on PATH" 'command -v ollie-set-identity >/dev/null'
chk "allowlist has entry" 'grep -q "ollie-set-identity" /home/ubuntu/.hermes/config.yaml'

# Save a sample persona to a profile that is safe to mutate: use 'karl' (preset).
printf 'You are Karl, a meticulous, fact-based assistant. You never invent answers.\n' > /tmp/karl-persona.md
ollie-set-identity --name "Karl Test" --soul-file /tmp/karl-persona.md --id karl >/tmp/sid.log 2>&1
echo "--- ollie-set-identity output ---"; cat /tmp/sid.log
chk "karl SOUL byte-equals the persona file" 'cmp -s /tmp/karl-persona.md /home/ubuntu/.hermes/profiles/karl/SOUL.md'
chk "karl SOUL has NO bootstrap/preset marker" '! grep -qE "OLLIE-SOUL-BOOTSTRAP|OLLIE-PRESET-SOUL" /home/ubuntu/.hermes/profiles/karl/SOUL.md'

# Verify the orchestrator now reports the new display name for karl.
OK="$(grep -E "^ORCHESTRATOR_KEY=" /home/ubuntu/.config/ollie-orchestrator/.env | cut -d= -f2-)"
NAME_NOW="$(curl -sS -H "Authorization: Bearer $OK" http://localhost:9123/v1/agents/karl | python3 -c 'import sys,json;print(json.load(sys.stdin).get("displayName",""))' 2>/dev/null)"
echo "orchestrator displayName for karl: $NAME_NOW"
chk "orchestrator displayName updated to 'Karl Test'" '[ "$NAME_NOW" = "Karl Test" ]'

# Empty soul-file rejected, SOUL untouched.
: > /tmp/empty.md
ollie-set-identity --name "X" --soul-file /tmp/empty.md --id karl >/tmp/sid2.log 2>&1; rc=$?
chk "empty --soul-file rejected (non-zero)" '[ '"$rc"' -ne 0 ]'
chk "karl SOUL unchanged after rejected empty write" 'cmp -s /tmp/karl-persona.md /home/ubuntu/.hermes/profiles/karl/SOUL.md'

# Missing profile rejected.
ollie-set-identity --name "X" --soul-file /tmp/karl-persona.md --id nope >/tmp/sid3.log 2>&1; rc=$?
chk "missing --id profile rejected (non-zero)" '[ '"$rc"' -ne 0 ]'

# Orchestrator-down simulated via bad key path -> persona still saved, exit 0.
ORCH_ENV=/nonexistent ollie-set-identity --name "Karl Test" --soul-file /tmp/karl-persona.md --id karl >/tmp/sid4.log 2>&1; rc=$?
chk "no-key path still exits 0 (persona is the hard part)" '[ '"$rc"' -eq 0 ]'
chk "no-key path warns about display name" 'grep -qi "skipping display-name\|no ORCHESTRATOR_KEY" /tmp/sid4.log'

echo "########## RESULT: ${PASS} passed, ${FAIL} failed ##########"
```

Expected: **all PASS, 0 FAIL.** (Note: the `ORCH_ENV=/nonexistent` override exercises the no-key branch because the script reads `ORCH_ENV` from the environment.)

- [ ] **Step 3: Restore karl** to its repo preset (the test renamed it): `rm -f ~/.hermes/profiles/karl/SOUL.md && bash ~/ollie-hermes-install/scripts/08-install-souls.sh`, and PATCH karl's displayName back to `Karl` via the orchestrator (or note it for the user). Confirm karl shows the preset again.

- [ ] **Step 4: Deploy the new default onboarding** — between user tests, reset the live default `SOUL.md` to the v4 bootstrap so a fresh chat exercises the new flow: `rm -f ~/.hermes/SOUL.md && bash ~/ollie-hermes-install/scripts/08-install-souls.sh`. Confirm `grep OLLIE-SOUL-BOOTSTRAP\ v4 ~/.hermes/SOUL.md`.

- [ ] **Step 5: Flag the manual smoke test** (do NOT automate): fresh default chat → agent asks one-at-a-time, writes a temp file, runs `ollie-set-identity` once → persona persists (no loop) AND the dashboard chip + upper-left name update to the chosen name without a page-reload-only delay (refresh if needed).

---

### Task 6: Merge, push, sync box — CONTROLLER

- [ ] **Step 1: Final review.** `git --no-pager diff --stat master..feat/ollie-set-identity` (expect only the four files + spec/plan docs). Confirm all commits authored `John Bryant <jb@getrevomate.com>`.

- [ ] **Step 2: Merge + push.**

```bash
git checkout master
git merge --ff-only feat/ollie-set-identity
git push origin master
git branch -d feat/ollie-set-identity
```

- [ ] **Step 3: Sync box checkout.** `ssh ollie 'cd ~/ollie-hermes-install && git fetch -q origin && git reset --hard origin/master && git rev-parse --short HEAD'` — expect box HEAD == origin/master, clean.

---

## Self-Review

**Spec coverage:**
- Deterministic command (atomic SOUL write + best-effort PATCH, exit-code rules) → Task 1; validated Task 5 (byte-equal, no-marker, displayName, no-key exit 0, empty/missing rejected).
- Onboarding directive → temp-file + command → Task 3; manual smoke test Task 5 Step 5.
- Install + symlink + allowlist + gateway restart → Task 2; validated Task 5 Step 2 (PATH + allowlist entry).
- README step → Task 4.
- Scope: `--id` for profiles → Task 1; preset (karl) used in tests.
- Edge cases (orch down, empty file, missing profile, marker-gone) → Task 5.
- Process: no resets mid-test → Task 5 preamble + Steps 3–4 "between tests".
- Deploy to live box → Task 5 Steps 3–4; merge/sync → Task 6.

**Placeholder scan:** none — full command, installer, and v4 directive are literal.

**Type/name consistency:** flags (`--name`/`--soul-file`/`--id`), `ORCH_ENV`/`ORCHESTRATOR_KEY`, paths (`~/.hermes/SOUL.md`, `~/.hermes/profiles/<id>/SOUL.md`), marker `OLLIE-SOUL-BOOTSTRAP v4`, and `command_allowlist` are consistent across Tasks 1–5.
