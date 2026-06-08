# First-run SOUL Provisioning — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a first-run identity flow so the default agent ("Ollie") interviews the operator and writes its own `SOUL.md`, while other agents get vendored preset personas — all installed safely (never clobbering a customized persona).

**Architecture:** No upstream patch. We vendor SOUL content under `templates/souls/` and add `scripts/08-install-souls.sh`, which marker-gates installs into `~/.hermes/SOUL.md` (default) and `~/.hermes/profiles/<name>/SOUL.md` (presets). The default's `SOUL.md` *contains* the onboarding directive; Hermes re-reads `SOUL.md` every message, so the agent runs the interview then overwrites the file itself (self-clearing).

**Tech Stack:** Bash, Markdown. No unit-test framework — validation is on-box gating scenarios (Task 4), plus a one-time manual chat smoke test for the LLM conversation.

**TDD note:** This feature is config/content + a provisioning shell script; there is no in-repo unit harness. "Tests" = the on-box gating matrix in Task 4 (exact commands + expected output). The LLM interview itself is verified by a flagged manual smoke test.

**Spec:** `docs/superpowers/specs/2026-06-07-soul-onboarding-design.md`

**Markers:** `OLLIE-SOUL-BOOTSTRAP` (default bootstrap) and `OLLIE-PRESET-SOUL` (presets). A `SOUL.md` is *replaceable* iff missing, effectively empty (stock template), or carrying one of these markers; a real persona with neither marker is left alone.

---

### Task 1: Vendor SOUL content under `templates/souls/`

**Files:**
- Create: `templates/souls/default-onboarding.md`
- Create: `templates/souls/paige.md`
- Create: `templates/souls/karl.md`
- Create: `templates/souls/README.md`

- [ ] **Step 1: Create `templates/souls/default-onboarding.md`** with EXACTLY this content:

```markdown
# Ollie — Agent Persona

<!-- OLLIE-SOUL-BOOTSTRAP v1 — replaced once setup completes; self-clears. -->

You are **Ollie**, this user's personal agent. You're brand new — your
personality, mission, and working style aren't defined yet. The operator
gets to shape who you become.

## FIRST-RUN SETUP (do this once, at the start of your first conversation)
While this notice is still here, your identity isn't set. Make setting it the
first thing you do — before any other onboarding or task:

1. Greet briefly as Ollie; mention they can rename you and that `/help` lists commands.
2. Say you'd like to ask a few quick questions so you can become *their* agent —
   they can skip or change any answer later.
3. Ask, conversationally (adapt to their answers):
   - **Name** — "I'm 'Ollie' by default — keep that, or call me something else?"
   - **Personality** — "What personality should I have — tone, vibe, quirks?"
   - **Mission** — "What's my main mission — what are you mostly here for me to do?"
   - **Communication** — "Brief and direct, or detailed and thorough? Any format you like?"
   - **Hard rules** — "Anything I should always or never do?"
4. Draft a short persona (second person, "You are …") covering those five. Show it:
   "Here's who I'll be — does this capture it, or want to tweak anything?"
5. On confirmation, OVERWRITE this file (`~/.hermes/SOUL.md`) with ONLY the
   finalized persona — removing this setup section and the marker above.

If they decline or seem uninterested: don't push. Write a sensible default
persona (a friendly, capable assistant named Ollie) to `~/.hermes/SOUL.md` so
you don't ask again, and carry on. They can say "redo your setup" anytime.

Once your identity is saved, proceed normally — any built-in "tell me about
you" user-profile step comes AFTER your own identity is set.
```

- [ ] **Step 2: Create `templates/souls/paige.md`** with EXACTLY this content:

```markdown
# Paige — Agent Persona

<!-- OLLIE-PRESET-SOUL v1 — starter preset. Replace the persona prose below with
     Paige's real personality and mission, then re-run scripts/08-install-souls.sh.
     This file is repo-managed: while this marker is present, 08 refreshes the
     host copy from here. To pin the host copy, remove this marker on the host. -->

You are **Paige**, a capable and friendly assistant. You are clear, proactive,
and reliable, with a warm, professional tone. You help with whatever the
operator needs and ask concise clarifying questions when a request is ambiguous.

<!-- AUTHOR TODO: give Paige a distinct personality, mission, communication style,
     and any hard rules — replace the generic persona above with the real one. -->
```

- [ ] **Step 3: Create `templates/souls/karl.md`** with EXACTLY this content:

```markdown
# Karl — Agent Persona

<!-- OLLIE-PRESET-SOUL v1 — starter preset. Replace the persona prose below with
     Karl's real personality and mission, then re-run scripts/08-install-souls.sh.
     This file is repo-managed: while this marker is present, 08 refreshes the
     host copy from here. To pin the host copy, remove this marker on the host. -->

You are **Karl**, a capable and friendly assistant. You are clear, proactive,
and reliable, with a warm, professional tone. You help with whatever the
operator needs and ask concise clarifying questions when a request is ambiguous.

<!-- AUTHOR TODO: give Karl a distinct personality, mission, communication style,
     and any hard rules — replace the generic persona above with the real one. -->
```

- [ ] **Step 4: Create `templates/souls/README.md`** with EXACTLY this content:

```markdown
# Agent personas (SOUL.md)

Hermes loads `SOUL.md` from each agent's home and injects it as the agent's
identity **fresh every message** (`~/.hermes/SOUL.md` for the default agent;
`~/.hermes/profiles/<name>/SOUL.md` for a profile). `scripts/08-install-souls.sh`
provisions these from the files here.

## Two kinds of persona

- **`default-onboarding.md`** → the default agent's `SOUL.md`. Its contents are a
  first-run *interview directive*: on first contact the agent (named Ollie by
  default) asks the operator for name, personality, mission, communication style,
  and hard rules, then **overwrites its own `SOUL.md`** with the finalized persona
  and removes the `OLLIE-SOUL-BOOTSTRAP` marker. After that it never re-runs.

- **`<profile>.md`** (e.g. `paige.md`, `karl.md`) → a hand-authored preset for a
  non-default agent. No onboarding — the persona is whatever you write here.

## Marker-gating (why your edits are safe)

`08-install-souls.sh` only writes a target `SOUL.md` when it is **replaceable**:
missing, still the stock Hermes template (effectively empty), or still carrying a
marker (`OLLIE-SOUL-BOOTSTRAP` / `OLLIE-PRESET-SOUL`). A real persona with no
marker is left untouched — so a completed onboarding or a hand-edited host file is
never clobbered.

## Authoring a preset for a new agent

1. Create `templates/souls/<profile-name>.md` (match the profile name used with
   `scripts/03-install-profile.sh`). Keep the `OLLIE-PRESET-SOUL` marker comment
   so `08` can deploy/refresh it; write the real persona as plain prose.
2. Run `scripts/08-install-souls.sh` (after the profile exists). It installs the
   preset to that profile's `SOUL.md`.
3. To stop the repo from managing a host copy, delete the marker line on the host
   file (or just edit the host file directly — removing the marker pins it).
```

- [ ] **Step 5: Commit**

```bash
git add templates/souls/
git commit -m "feat(souls): vendor default onboarding bootstrap + preset persona starters"
```

---

### Task 2: Add `scripts/08-install-souls.sh`

**Files:**
- Create: `scripts/08-install-souls.sh`

- [ ] **Step 1: Create `scripts/08-install-souls.sh`** with EXACTLY this content:

```bash
#!/usr/bin/env bash
# 08-install-souls.sh — provision agent personas (SOUL.md).
#
# Run as: the service user (ollie by default; NOT root)
# Idempotent: safe to re-run. Marker-gated so it NEVER clobbers a SOUL.md you
# (or the default agent's onboarding) have already customized.
#
# What it does:
#   1. Default agent: installs the first-run onboarding bootstrap to
#      ~/.hermes/SOUL.md, so the default agent interviews you about its identity
#      on first contact, then rewrites the file itself.
#   2. Preset agents: for each ~/.hermes/profiles/<name>/ that has a matching
#      templates/souls/<name>.md, installs that preset persona.
#
# A SOUL.md is REPLACEABLE only if it is missing, still the stock Hermes template
# (effectively empty), or still carries one of our markers
# (OLLIE-SOUL-BOOTSTRAP / OLLIE-PRESET-SOUL). A customized persona (real content,
# no marker) is left untouched.

set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  echo "error: run as the service user, not root" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOULS_SRC="${SCRIPT_DIR}/../templates/souls"
HERMES_HOME="${HOME}/.hermes"
PROFILES_DIR="${HERMES_HOME}/profiles"

if [[ ! -f "${SOULS_SRC}/default-onboarding.md" ]]; then
  echo "error: vendored souls not found at ${SOULS_SRC}" >&2
  exit 1
fi

# Return 0 (replaceable) if the target SOUL.md is missing, effectively empty
# (stock template — only comments/headers/blanks), or still carries a marker.
# Return 1 (keep) if it holds a real, customized persona.
soul_is_replaceable() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  if grep -qE 'OLLIE-SOUL-BOOTSTRAP|OLLIE-PRESET-SOUL' "$f"; then
    return 0
  fi
  local meaningful
  meaningful="$(awk '
    /<!--/{inc=1}
    { if(!inc){ print } }
    /-->/{inc=0}
  ' "$f" | sed -E 's/^[[:space:]]*#.*$//' | grep -vE '^[[:space:]]*$' || true)"
  [[ -z "${meaningful}" ]] && return 0
  return 1
}

install_soul() {  # $1=src  $2=dest  $3=label
  local src="$1" dest="$2" label="$3"
  [[ -f "$src" ]] || return 0
  mkdir -p "$(dirname "$dest")"
  if soul_is_replaceable "$dest"; then
    cp "$src" "$dest"
    chmod 644 "$dest"
    printf '  %-24s installed\n' "$label"
  else
    printf '  %-24s skipped (customized persona present)\n' "$label"
  fi
}

echo "==> default agent: ~/.hermes/SOUL.md"
install_soul "${SOULS_SRC}/default-onboarding.md" "${HERMES_HOME}/SOUL.md" "default (onboarding)"

echo "==> preset agents: per-profile SOUL.md"
shopt -s nullglob
found_profile=0
for prof_dir in "${PROFILES_DIR}"/*/; do
  found_profile=1
  name="$(basename "${prof_dir}")"
  preset="${SOULS_SRC}/${name}.md"
  if [[ -f "${preset}" ]]; then
    install_soul "${preset}" "${prof_dir}SOUL.md" "${name} (preset)"
  else
    printf '  %-24s no preset in templates/souls — left as-is\n' "${name}"
  fi
done
[[ "${found_profile}" -eq 0 ]] && echo "  (no profiles installed)"

echo
echo "✓ SOUL provisioning complete."
echo "  The default agent runs its first-run identity setup on the next NEW chat,"
echo "  then rewrites its own SOUL.md. Re-run after adding a profile (03) or after"
echo "  editing a preset in templates/souls/."
```

- [ ] **Step 2: Make it executable + syntax-check**

Run: `chmod +x scripts/08-install-souls.sh && bash -n scripts/08-install-souls.sh && echo OK`
Expected: `OK` (exit 0, no other output).

- [ ] **Step 3: Commit**

```bash
git add scripts/08-install-souls.sh
git commit -m "feat(08): SOUL provisioner — marker-gated default onboarding + per-profile presets"
```

---

### Task 3: Add `08` to the README quick-start

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Read `README.md`** and find the end of the numbered quick-start (the block that currently ends with step 9, `bash scripts/07-patch-cron-brain.sh`).

- [ ] **Step 2: Insert this step** immediately after the `07-patch-cron-brain.sh` step (still inside the same fenced code block):

```bash

# 10. Provision agent personas: seed the default agent's first-run identity
#     onboarding (it interviews you on first chat) + any preset personas for
#     extra profiles. Marker-gated — never overwrites a customized SOUL.md.
#     Run this LAST, before you start chatting. Re-run after adding a profile.
bash scripts/08-install-souls.sh
```

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs(readme): add step 10 — provision agent personas (08-install-souls)"
```

---

### Task 4: On-box validation (gating matrix) + deploy — CONTROLLER

This both validates the gating logic and deploys to the live box (the default `SOUL.md` is still the stock template, so it's eligible). Run from the Windows control machine via the BOM/CRLF-safe transfer helper:

```powershell
function Send-And-Run { param([string]$LocalSh,[string]$RemoteName)
  $txt=[System.IO.File]::ReadAllText($LocalSh).Replace("`r","").TrimStart([char]0xFEFF)
  $tmp=[System.IO.Path]::Combine($env:TEMP,"clean_$RemoteName")
  [System.IO.File]::WriteAllText($tmp,$txt,(New-Object System.Text.UTF8Encoding($false)))
  scp -q $tmp "ollie:/tmp/$RemoteName" 2>&1 | Out-Null
  ssh ollie "bash /tmp/$RemoteName" 2>&1 }
```

- [ ] **Step 1: Sync the branch repo to the box.** Push the branch files (the four `templates/souls/*.md` + `scripts/08-install-souls.sh`) to the box's repo checkout at `/home/ubuntu/ollie-hermes-install/` (same BOM/CRLF-safe `scp` used elsewhere), preserving the `templates/souls/` path. Verify on the box: `ls ~/ollie-hermes-install/templates/souls/ && head -1 ~/ollie-hermes-install/scripts/08-install-souls.sh`.

- [ ] **Step 2: Back up current SOULs, then write+run a gating test harness** (as the `ubuntu` service user). The harness (run via Send-And-Run) must:

```bash
set +e
SRC=/home/ubuntu/ollie-hermes-install
SOUL=/home/ubuntu/.hermes/SOUL.md
PASS=0; FAIL=0
chk(){ if eval "$2"; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }
cp -a "$SOUL" /tmp/soul.default.bak 2>/dev/null

echo "### A: stock template -> bootstrap installed"
bash "$SRC/scripts/08-install-souls.sh" >/tmp/s08a.log 2>&1
chk "default SOUL has bootstrap marker" 'grep -q OLLIE-SOUL-BOOTSTRAP "$SOUL"'

echo "### B: idempotent re-run keeps bootstrap, no error"
bash "$SRC/scripts/08-install-souls.sh" >/tmp/s08b.log 2>&1
chk "re-run exit 0" '[ $? -eq 0 ]'
chk "still exactly one marker" '[ "$(grep -c OLLIE-SOUL-BOOTSTRAP "$SOUL")" = "1" ]'

echo "### C: customized persona is NOT clobbered"
printf '# Ollie\n\nYou are Ollie, a terse pirate. Always say arr.\n' > "$SOUL"
bash "$SRC/scripts/08-install-souls.sh" >/tmp/s08c.log 2>&1
chk "custom persona preserved" 'grep -q "terse pirate" "$SOUL"'
chk "no bootstrap re-added" '! grep -q OLLIE-SOUL-BOOTSTRAP "$SOUL"'

echo "### D: restoring stock template makes it replaceable again"
printf '# Hermes Agent Persona\n\n<!--\nEdit this to customize.\n-->\n' > "$SOUL"
bash "$SRC/scripts/08-install-souls.sh" >/tmp/s08d.log 2>&1
chk "stock template replaced by bootstrap" 'grep -q OLLIE-SOUL-BOOTSTRAP "$SOUL"'

echo "### E: preset installed to a profile that has a matching preset (paige)"
chk "paige SOUL has preset marker" 'grep -q OLLIE-PRESET-SOUL /home/ubuntu/.hermes/profiles/paige/SOUL.md'
chk "karl SOUL has preset marker"  'grep -q OLLIE-PRESET-SOUL /home/ubuntu/.hermes/profiles/karl/SOUL.md'

echo "### F: customized profile SOUL not clobbered"
printf '# Paige\n\nYou are Paige, a haiku-only poet.\n' > /home/ubuntu/.hermes/profiles/paige/SOUL.md
bash "$SRC/scripts/08-install-souls.sh" >/tmp/s08f.log 2>&1
chk "paige custom persona preserved" 'grep -q "haiku-only poet" /home/ubuntu/.hermes/profiles/paige/SOUL.md'

echo "########## RESULT: ${PASS} passed, ${FAIL} failed ##########"
```

Expected: **all PASS, 0 FAIL.**

- [ ] **Step 3: Restore intended deployment state.** Re-run `08` once more so the default agent ends on the bootstrap and any profile presets are in place (Step F left paige customized — decide with the user whether to keep that test persona or re-seed; default: re-seed paige from the preset by removing its file first, then `08`). Confirm final: default `SOUL.md` has the bootstrap marker; paige/karl have preset markers (unless intentionally customized).

- [ ] **Step 4: Flag the manual smoke test (do NOT automate).** Tell the user: start a fresh **default-agent** chat at `http://74.208.207.91:3000/chat`; confirm Ollie greets and runs the 5-question interview; answer it; confirm `~/.hermes/SOUL.md` is rewritten to the persona with no `OLLIE-SOUL-BOOTSTRAP` marker. This validates the LLM conversation path, which can't be unit-tested.

---

### Task 5: Merge, push, sync box — CONTROLLER

- [ ] **Step 1: Final review.** `git --no-pager diff --stat master..feat/soul-onboarding` (expect only `templates/souls/*`, `scripts/08-install-souls.sh`, `README.md`, and the spec/plan docs). Confirm all commits authored `John Bryant <jb@getrevomate.com>`.

- [ ] **Step 2: Merge + push.**

```bash
git checkout master
git merge --ff-only feat/soul-onboarding
git push origin master
git branch -d feat/soul-onboarding
```
Expected: FF merge; push succeeds; branch deleted.

- [ ] **Step 3: Sync the box checkout.** `ssh ollie 'cd ~/ollie-hermes-install && git fetch -q origin && git reset --hard origin/master && git rev-parse --short HEAD'` — expect box HEAD == origin/master, clean. (This brings the committed `templates/souls/` + `08` onto the box cleanly; the live `SOUL.md` files seeded in Task 4 are outside the repo and unaffected.)

---

## Self-Review

**Spec coverage:**
- Default bootstrap content + 5 questions + self-clear + decline → Task 1 Step 1; runtime behavior is the file's content. Manual smoke test Task 4 Step 4.
- Preset personas (paige/karl, safe generics + markers) → Task 1 Steps 2-3.
- Authoring guide → Task 1 Step 4.
- `08` provisioner, marker-gating, per-profile presets, idempotency → Task 2; validated Task 4 Steps 2 (A–F).
- Never clobber a customized SOUL → Task 4 C, F (PASS = preserved).
- README final-step placement (before first interaction) → Task 3.
- Deploy to live box → Task 4 Steps 2-3.
- Merge/push/sync → Task 5.

**Placeholder scan:** none — all file contents and the script are literal. The `[AUTHOR TODO]` lines are intentional *product* guidance inside vendored presets (in HTML comments, not active persona prose), not plan placeholders.

**Type/name consistency:** markers `OLLIE-SOUL-BOOTSTRAP` / `OLLIE-PRESET-SOUL`, paths `templates/souls/<name>.md` and `~/.hermes/profiles/<name>/SOUL.md`, and function names `soul_is_replaceable` / `install_soul` are used consistently across Tasks 1, 2, and 4.
