# Idempotency Phase 7 — `INSTALL_REPO_REF` Drift Guard — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use `- [ ]`.

**Goal:** Stop the Fleet install-repo pin from silently going stale. `INSTALL_REPO_REF` (`src/server/enroll-core.ts:9`, a hardcoded install-repo SHA) is what NEW box provisions clone; if install-repo master moves ahead without a pin bump, new boxes ship old install code (missing this workstream's fixes). Provide a runnable drift check + a format lock + a deploy gate so the bump can't be forgotten.

**Context:** The pin is currently `9d23b0f` (the install security commit), but install master now carries the Phase 1/2 idempotency fixes on top — so it's *already* stale and must be bumped to the deployed install HEAD before new-box provisions ship the fixes. On-box `update hermes` pulls `master` (not the pin); converging those two is deferred (a Phase-2 behavior change, out of scope here).

## Global Constraints

- **Commits LOCAL + UNPUSHED** on `ollie-fleet` master (base = the Phase-3 tip `b328187`). Do not push.
- The **format-lock test** must run anywhere (no network / no sibling repo) — it only asserts the hardcoded pin is a well-formed 40-hex SHA.
- The **drift-check script** compares the pin to a LOCAL `ollie-hermes-install` checkout's `master` tip (path arg, default `../ollie-hermes-install`) — a deploy-time/manual tool, not CI.
- Do NOT bump the pin value in this task (install HEAD is still moving through the batch; the bump is a deploy step). Only add the guard + gate.

## File Structure

- **Create `scripts/check-install-pin.sh`** — compares `INSTALL_REPO_REF` (grepped from `enroll-core.ts`) to a local install-repo master tip; exits non-zero on drift with a clear "bump" message.
- **Modify `tests/unit/` (new `install-ref.test.ts`)** — assert the hardcoded `INSTALL_REPO_REF` fallback is a 40-hex SHA.
- **Modify `deploy/DEPLOY.md`** (or the provisioning runbook) — add a pre-provision gate: run the check, bump the pin if it reports drift.

---

### Task 1: `INSTALL_REPO_REF` format-lock test + drift-check script + deploy gate (#18 Phase 7)

**Files:**
- Create: `scripts/check-install-pin.sh`
- Create: `tests/unit/install-ref.test.ts`
- Modify: `deploy/DEPLOY.md`

- [ ] **Step 1: Write the failing/again format-lock test**

Read `src/server/enroll-core.ts:8-9` to confirm the export shape (`export const INSTALL_REPO_REF = process.env.INSTALL_REPO_REF?.trim() || '<40-hex>'`). Create `tests/unit/install-ref.test.ts`:
```ts
import { describe, it, expect } from 'vitest'
import { INSTALL_REPO_REF } from '../../src/server/enroll-core.js'

describe('INSTALL_REPO_REF', () => {
  it('is a full 40-hex git sha (a pin, never a branch/tag/short-sha)', () => {
    // With INSTALL_REPO_REF unset in the test env, this is the hardcoded fallback.
    delete process.env.INSTALL_REPO_REF
    expect(INSTALL_REPO_REF).toMatch(/^[0-9a-f]{40}$/)
  })
})
```
(If `enroll-core.ts` reads the env var at import time such that `delete` after import has no effect, adjust: assert the module's exported value matches the regex — the point is to lock that the committed pin is a full SHA. If the import path/extension differs in this repo's vitest config, match the existing test files' import style.)

- [ ] **Step 2: Run — verify it passes (format lock)**

Run (in `ollie-fleet`): `npx vitest run tests/unit/install-ref.test.ts`
Expected: PASS (the pin is already a 40-hex SHA). This locks the format so a future edit to a short-sha/branch/tag fails CI. If it FAILS now, the pin is malformed — STOP and report.

- [ ] **Step 3: Write the drift-check script**

Create `scripts/check-install-pin.sh`:
```bash
#!/usr/bin/env bash
# Fail if Fleet's INSTALL_REPO_REF pin != the install-repo master tip, so a new-box
# provision can't silently ship stale install code. Run before provisioning new boxes
# (and after any ollie-hermes-install change). Compares against a LOCAL checkout.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${1:-$HERE/../../ollie-hermes-install}"
pin="$(grep -oE "[0-9a-f]{40}" "$HERE/../src/server/enroll-core.ts" | head -1)"
if [ -z "$pin" ]; then echo "ERROR: could not read INSTALL_REPO_REF from enroll-core.ts" >&2; exit 2; fi
if [ ! -d "$INSTALL_DIR/.git" ]; then
  echo "SKIP: install repo not found at $INSTALL_DIR (pass the path as \$1). Pin=$pin" >&2; exit 0
fi
tip="$(git -C "$INSTALL_DIR" rev-parse master)"
if [ "$pin" = "$tip" ]; then
  echo "OK: INSTALL_REPO_REF ($pin) == ollie-hermes-install master."
else
  echo "DRIFT: INSTALL_REPO_REF=$pin but ollie-hermes-install master=$tip." >&2
  echo "  New box provisions would clone STALE install code." >&2
  echo "  Bump INSTALL_REPO_REF in src/server/enroll-core.ts to $tip before provisioning." >&2
  exit 1
fi
```
Make it executable-friendly (the test/runbook invokes via `bash`). `chmod +x` if the repo tracks the bit (match sibling scripts).

- [ ] **Step 4: Verify the script runs (and correctly reports current drift)**

Run: `bash scripts/check-install-pin.sh` (with the sibling `ollie-hermes-install` checkout present).
Expected: it prints either `OK:` or `DRIFT:` with the two SHAs. Given install master is currently ahead of the `9d23b0f` pin, expect a **DRIFT** report (exit 1) — which is correct and is exactly the signal the deploy needs (bump the pin to the deployed install HEAD). Confirm the message is clear. (`bash -n scripts/check-install-pin.sh` for syntax.)

- [ ] **Step 5: Add the deploy gate to DEPLOY.md**

In `deploy/DEPLOY.md`, add a short "Install-repo pin (pre-provision gate)" subsection: before provisioning NEW boxes, run `bash scripts/check-install-pin.sh`; if it reports DRIFT, bump `INSTALL_REPO_REF` in `src/server/enroll-core.ts` to the deployed `ollie-hermes-install` master tip and re-run. Note that on-box `update hermes` uses `master` (so existing boxes self-update regardless), and that converging the two paths is a separate follow-up.

- [ ] **Step 6: Run — full suite + commit**

Run: `npm test` → full vitest green (the new test passes; no regressions).
```bash
git add scripts/check-install-pin.sh tests/unit/install-ref.test.ts deploy/DEPLOY.md
git commit -m "feat(fleet): guard INSTALL_REPO_REF against silent drift (#18 Phase 7)

Adds a format-lock test (the pin must be a full 40-hex SHA) and a check script
that fails when INSTALL_REPO_REF != the install-repo master tip, wired into DEPLOY.md
as a pre-provision gate — so a new-box provision can't silently ship stale install
code. Does not bump the pin (a deploy step); converging on-box update-vs-pin deferred.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Out of Scope
- **Bumping the pin value** — a deploy step (install HEAD is still moving through this batch; bump to the final deployed install HEAD when pushing).
- **Converging on-box `update hermes` (master) with the provision pin** — a behavior change to the update path (Phase 2 territory); deferred + noted in DEPLOY.md.

## Self-Review
- **Coverage:** format lock (test, runs anywhere) + drift detection (script) + un-skippable at deploy (DEPLOY.md gate). ✓
- **Placeholders:** exact test + script; the DEPLOY.md edit is a documented gate. The one env-timing caveat (does `delete process.env` after import take effect) is flagged with a fallback. ✓
- **Risk:** additive only (new test/script/doc); no provisioning behavior changes; the script correctly reporting current drift is the intended signal, not a failure. ✓
