# Idempotency Phase 2 — `fleetctl update` Re-Apply Completeness — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `ollie-fleetctl update {hermes,stack,orchestrator}` re-apply everything the update wipes, so an operator never has to run install scripts by hand after an update.

**Architecture:** Extract the update step-list out of `cmd_update` into a pure `build_update_steps(component)` function, add a `--dry-run` flag that prints the planned steps without executing (a real operator feature + the test seam), then fix the three step lists: `stack` re-runs `06-install-stack.sh` (ships compose/pin changes), `hermes` also re-applies `09-install-identity-sync.sh`, `orchestrator` re-runs `05-install-orchestrator.sh` (restores the systemd unit + gateway-key wiring). Canonicalize the README against the code. A zero-dependency bash test drives `--dry-run`.

**Tech Stack:** Python 3 stdlib (the `ollie-fleetctl` CLI — `os`, `sys`, `json`; no third-party imports). Bash + coreutils for the test harness (same pattern as Phase 1). `python3` must be on PATH to run the CLI in tests.

## Global Constraints

- **Commits are LOCAL + UNPUSHED**, stacked on `ollie-hermes-install` master (base = current HEAD `80b4590`, the Phase-1 tip). Do not push.
- `ollie-fleetctl` is **Python 3, stdlib-only** — introduce no third-party imports.
- **`build_update_steps(component)` must be PURE** — it only constructs the `[(name, argv, timeout), …]` list, runs nothing, touches no filesystem/network — so `--dry-run` and the tests work offline on any host.
- **Do not change the behavior of steps that are not being modified**: the `hermes-update` step keeps its `input_text="y\ny\ny\ny\ny\n"` special-case; the `event(progress/error/done)` emissions and the `sys.exit(1)`-on-failure loop are unchanged.
- The `update orchestrator` change is an **intentional behavior change**: `05-install-orchestrator.sh` does more than the old 3 steps (it installs/refreshes the systemd unit, regenerates `ORCHESTRATOR_KEY` via the orchestrator's own `install.sh`, re-wires `HERMES_GATEWAY_KEY` from `~/.hermes/.env`, and uses `git reset --hard origin/master` instead of `pull --ff-only`). This is the point of #10 — call it out in the commit.
- The README "After a `hermes update`" section must name the **actual** re-applied scripts (`04`, `07`, `08`, `09`) and state that `ollie-fleetctl update hermes` runs them.
- `#13` (profile model-inheritance self-heal) is **OUT OF SCOPE** for this phase — see §Out of Scope.

---

## File Structure

- **Modify `templates/bin/ollie-fleetctl`** — add `build_update_steps(component)` (pure), rewrite `cmd_update` to call it + honor `--dry-run`, add the `--dry-run` argparse flag to the `update` subparser, and change the three component step lists.
- **Modify `README.md`** — rewrite the "After a `hermes update`" section to match `cmd_update`.
- **Create `tests/test-fleetctl-update.sh`** — drives `python3 templates/bin/ollie-fleetctl update <c> --dry-run` and asserts the planned step set per component. Reuses `tests/lib/assert.sh` from Phase 1.

---

### Task 1: Extract `build_update_steps` + `--dry-run` (no behavior change)

Characterization-first: expose the CURRENT step lists via `--dry-run` and lock them with a test, then Tasks 2-4 change them red-green.

**Files:**
- Modify: `templates/bin/ollie-fleetctl` (`cmd_update` region ~409-446; the `update` argparse subparser)
- Create: `tests/test-fleetctl-update.sh`

**Interfaces:**
- Produces: `build_update_steps(component) -> list[tuple[str, list[str], int]]` (pure). `cmd_update` prints steps as JSON via `emit({...})` when `args.dry_run` is set, else runs them.

- [ ] **Step 1: Write the characterization test (current steps)**

Create `tests/test-fleetctl-update.sh`:
```bash
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
test_stack_current() {
  assert_eq "stack has compose-pull" "$(has_step stack compose-pull && echo y)" "y"
  assert_eq "stack has compose-up"   "$(has_step stack compose-up && echo y)" "y"
}
test_orch_current() {
  assert_eq "orchestrator has git-pull-orchestrator" "$(has_step orchestrator git-pull-orchestrator && echo y)" "y"
  assert_eq "orchestrator has restart-orchestrator"  "$(has_step orchestrator restart-orchestrator && echo y)" "y"
}
test_hermes_current
test_stack_current
test_orch_current
finish
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test-fleetctl-update.sh`
Expected: FAIL — `--dry-run` is not a recognized flag yet (argparse errors / no JSON), so `has_step` finds nothing.

- [ ] **Step 3: Extract `build_update_steps` (verbatim current lists) + honor `--dry-run`**

In `templates/bin/ollie-fleetctl`, replace the body of `cmd_update` (lines ~409-446) with a pure builder + a dry-run branch. Add this function immediately above `cmd_update`:
```python
def build_update_steps(component):
    """Ordered (name, argv, timeout) steps for `update <component>`.
    Pure: constructs the list, runs nothing (used by cmd_update and --dry-run)."""
    steps = []
    if component in ("hermes", "all"):
        steps += [
            ("git-pull-install-repo", ["git", "-C", INSTALL_DIR, "pull", "--ff-only"], 120),
            ("reinstall-fleetctl", ["bash", os.path.join(INSTALL_DIR, "scripts", "10-install-fleetctl.sh")], 60),
            ("hermes-update", ["hermes", "update"], 900),
            # hermes update resets ~/.hermes/hermes-agent — re-apply the stack pieces it wipes:
            ("reinstall-cortex-plugin", ["bash", os.path.join(INSTALL_DIR, "scripts", "04-install-cortex-plugin.sh")], 300),
            ("repatch-cron-brain", ["bash", os.path.join(INSTALL_DIR, "scripts", "07-patch-cron-brain.sh")], 120),
            ("reinstall-souls", ["bash", os.path.join(INSTALL_DIR, "scripts", "08-install-souls.sh")], 120),
        ]
    if component in ("stack", "all"):
        steps += [
            ("compose-pull", ["docker", "compose", "-f", COMPOSE_FILE, "pull"], 600),
            ("compose-up", ["docker", "compose", "-f", COMPOSE_FILE, "up", "-d"], 300),
        ]
    if component in ("orchestrator", "all"):
        steps += [
            ("git-pull-orchestrator", ["git", "-C", ORCH_DIR, "pull", "--ff-only"], 120),
            ("pip-install", [os.path.join(ORCH_DIR, ".venv", "bin", "pip"),
                             "install", "-q", "-r",
                             os.path.join(ORCH_DIR, "requirements.txt")], 600),
            ("restart-orchestrator", ["systemctl", "--user", "restart", "ollie-orchestrator"], 60),
        ]
    return steps


def cmd_update(args):
    component = args.component
    steps = build_update_steps(component)
    if getattr(args, "dry_run", False):
        emit({"component": component, "dry_run": True,
              "steps": [{"name": n, "cmd": a, "timeout": t} for (n, a, t) in steps]})
        return
    for name, cmd_args, timeout in steps:
        event(event="progress", step=name)
        # hermes update prompts interactively; answer yes so it can't hang to the timeout.
        ok, detail = _step_cmd(cmd_args, timeout,
                               input_text="y\ny\ny\ny\ny\n" if name == "hermes-update" else None)
        if not ok:
            event(event="error", step=name, error=detail)
            sys.exit(1)
    event(event="done", component=component)
```

- [ ] **Step 4: Add the `--dry-run` flag to the `update` subparser**

Find the argparse block that defines the `update` subcommand (search for `add_parser("update"` or `add_parser('update'`). On that subparser object (the variable it's assigned to), add:
```python
    p_update.add_argument("--dry-run", action="store_true",
                          help="print the planned steps as JSON without running them")
```
(Use whatever variable name the existing code uses for the update subparser; match the `component` argument that's already defined there.)

- [ ] **Step 5: Run to verify the characterization test passes**

Run: `bash tests/test-fleetctl-update.sh`
Expected: PASS — all current step names present for each component.
Also sanity-check the CLI still parses: `python3 templates/bin/ollie-fleetctl update hermes --dry-run` prints a JSON object with a `steps` array. If the CLI errors at import/top-level in this environment (needs a real box), STOP and report BLOCKED with the error — do not fake the test.

- [ ] **Step 6: Commit**

```bash
git add templates/bin/ollie-fleetctl tests/test-fleetctl-update.sh
git commit -m "refactor(fleetctl): extract build_update_steps + add update --dry-run

No behavior change to real runs. Pulls the update step-list into a pure
build_update_steps(component) and adds a --dry-run flag that prints the planned
steps as JSON — an operator preview and the test seam for Phase 2.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: `update stack` re-runs `06-install-stack.sh` (#2)

**Files:**
- Modify: `templates/bin/ollie-fleetctl` (`build_update_steps`, stack branch)
- Modify: `tests/test-fleetctl-update.sh`

- [ ] **Step 1: Write the failing test**

In `tests/test-fleetctl-update.sh`, replace `test_stack_current` with:
```bash
# Stack update must re-run 06 (restages compose + refreshes pins), not a bare compose pull/up.
test_stack_reinstalls_06() {
  assert_eq "stack has reinstall-stack" "$(has_step stack reinstall-stack && echo y)" "y"
  assert_eq "stack no longer bare compose-pull" "$(has_step stack compose-pull && echo y)" ""
}
```
and change the call `test_stack_current` → `test_stack_reinstalls_06`.

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test-fleetctl-update.sh`
Expected: FAIL — stack still lists `compose-pull`/`compose-up`, not `reinstall-stack`.

- [ ] **Step 3: Change the stack branch**

In `build_update_steps`, replace the two `stack`-branch steps with:
```python
    if component in ("stack", "all"):
        # Re-run 06 (not a bare compose pull/up): it restages docker-compose.yml from
        # templates/, refreshes the CORTEX_IMAGE/FRONTEND_IMAGE pins, preserves the .env,
        # then does compose pull + up. `compose pull` alone would re-pull the same old
        # digest already pinned in .env and miss any compose/pin change.
        steps += [
            ("reinstall-stack", ["bash", os.path.join(INSTALL_DIR, "scripts", "06-install-stack.sh")], 900),
        ]
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/test-fleetctl-update.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add templates/bin/ollie-fleetctl tests/test-fleetctl-update.sh
git commit -m "fix(fleetctl): update stack re-runs 06 so compose/pin changes ship (#2)

A bare 'compose pull' re-pulls the same digest already in .env; re-running
06-install-stack.sh restages the compose file and refreshes the image pins, so a
committed compose or pin change actually takes on 'update stack'.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: `update hermes` also re-applies `09-install-identity-sync.sh` (#7)

**Files:**
- Modify: `templates/bin/ollie-fleetctl` (`build_update_steps`, hermes branch)
- Modify: `tests/test-fleetctl-update.sh`

- [ ] **Step 1: Write the failing test**

In `tests/test-fleetctl-update.sh`, add to `test_hermes_current` (rename it `test_hermes_reapply`) one assertion:
```bash
  assert_eq "hermes re-applies identity-sync (09)" "$(has_step hermes reinstall-identity-sync && echo y)" "y"
```
(Rename the function and its call from `test_hermes_current` → `test_hermes_reapply`.)

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test-fleetctl-update.sh`
Expected: FAIL — no `reinstall-identity-sync` step.

- [ ] **Step 3: Add the 09 step**

In `build_update_steps`, append to the `hermes/all` step list (after `reinstall-souls`):
```python
            # hermes update also resets ~/.hermes/config.yaml — re-apply the command
            # allowlist so ollie-set-identity runs without an approval prompt.
            ("reinstall-identity-sync", ["bash", os.path.join(INSTALL_DIR, "scripts", "09-install-identity-sync.sh")], 60),
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/test-fleetctl-update.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add templates/bin/ollie-fleetctl tests/test-fleetctl-update.sh
git commit -m "fix(fleetctl): update hermes re-applies 09 identity-sync (#7)

hermes update resets ~/.hermes/config.yaml, dropping the command_allowlist that
lets the agent run ollie-set-identity without an approval prompt. Re-apply 09 in
the update so the identity wizard doesn't re-arm approvals after every update.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: `update orchestrator` re-runs `05-install-orchestrator.sh` (#10)

**Files:**
- Modify: `templates/bin/ollie-fleetctl` (`build_update_steps`, orchestrator branch)
- Modify: `tests/test-fleetctl-update.sh`

- [ ] **Step 1: Write the failing test**

In `tests/test-fleetctl-update.sh`, replace `test_orch_current` with:
```bash
# Orchestrator update must re-run 05 (restores systemd unit + HERMES_GATEWAY_KEY wiring),
# not just git-pull + pip + restart.
test_orch_reinstalls_05() {
  assert_eq "orchestrator has reinstall-orchestrator" "$(has_step orchestrator reinstall-orchestrator && echo y)" "y"
  assert_eq "orchestrator no longer bare git-pull-orchestrator" "$(has_step orchestrator git-pull-orchestrator && echo y)" ""
}
```
and change the call `test_orch_current` → `test_orch_reinstalls_05`.

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test-fleetctl-update.sh`
Expected: FAIL — orchestrator still lists the 3 old steps.

- [ ] **Step 3: Change the orchestrator branch**

In `build_update_steps`, replace the three `orchestrator`-branch steps with:
```python
    if component in ("orchestrator", "all"):
        # Re-run 05 (not just git-pull + pip + restart): 05 also (re)installs the
        # ollie-orchestrator.service systemd unit, regenerates ORCHESTRATOR_KEY via the
        # orchestrator's own install.sh, and re-wires HERMES_GATEWAY_KEY from ~/.hermes/.env
        # — all of which a bare pull/restart would miss when the unit or key contract changes.
        steps += [
            ("reinstall-orchestrator", ["bash", os.path.join(INSTALL_DIR, "scripts", "05-install-orchestrator.sh")], 600),
        ]
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/test-fleetctl-update.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add templates/bin/ollie-fleetctl tests/test-fleetctl-update.sh
git commit -m "fix(fleetctl): update orchestrator re-runs 05 (unit + key re-wire) (#10)

The old git-pull + pip + restart missed systemd-unit reinstall, ORCHESTRATOR_KEY
regeneration, and HERMES_GATEWAY_KEY re-wiring. 05-install-orchestrator.sh is
argument-free and idempotent, so re-running it restores the full contract.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Canonicalize the README "After a `hermes update`" section (#11)

The README currently tells operators to re-run only `07` + `08` by hand, and claims `ollie-fleetctl update hermes` is "the one-command equivalent" — but the code re-applies `04`, `07`, `08`, and now `09`. Make the doc match.

**Files:**
- Modify: `README.md` (the "After a `hermes update`" section, ~lines 97-114)
- Modify: `tests/test-fleetctl-update.sh` (add a doc-vs-code consistency check)

- [ ] **Step 1: Write the failing consistency test**

In `tests/test-fleetctl-update.sh`, add (before `finish`):
```bash
# The README's after-update section must name every script the code re-applies.
test_readme_matches_code() {
  local readme="$HERE/../README.md"
  for s in 04-install-cortex-plugin.sh 07-patch-cron-brain.sh 08-install-souls.sh 09-install-identity-sync.sh; do
    assert_eq "README names $s" "$(grep -q "$s" "$readme" && echo y)" "y"
  done
}
test_readme_matches_code
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test-fleetctl-update.sh`
Expected: FAIL — the README's manual snippet names only `07` and `08` (missing `04` and `09`).

- [ ] **Step 3: Rewrite the README section**

In `README.md`, replace the manual "re-run these two/three" code block and the "one-command equivalent" note so the section reads (keep the surrounding prose about SOUL.md/personas):
```markdown
**Preferred: one command.** If `ollie-fleetctl` is installed:

​```bash
ollie-fleetctl update hermes
​```

This git-pulls the install repo and, after `hermes update`, re-applies everything the
update wipes: the Cortex memory plugin (`04-install-cortex-plugin.sh`), the cron
brain-tools patch (`07-patch-cron-brain.sh`), the agent personas
(`08-install-souls.sh`), and the `ollie-set-identity` command allowlist
(`09-install-identity-sync.sh`).

**By hand (no fleetctl):** run the same set, in order:

​```bash
cd ~/ollie-hermes-install && git pull
bash scripts/04-install-cortex-plugin.sh
bash scripts/07-patch-cron-brain.sh
bash scripts/08-install-souls.sh
bash scripts/09-install-identity-sync.sh
​```
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/test-fleetctl-update.sh`
Expected: PASS — README names all four scripts.

- [ ] **Step 5: Commit**

```bash
git add README.md tests/test-fleetctl-update.sh
git commit -m "docs(install): canonicalize the after-hermes-update re-apply list (#11)

The manual snippet listed only 07+08 and the fleetctl note was stale; both now
match the actual cmd_update set (04, 07, 08, 09). A test asserts the README names
every script the code re-applies, so they can't drift again.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Out of Scope (deferred, with rationale)

- **#13 — profile model-inheritance self-heal.** The spec assumed `03-install-profile.sh` could be re-run per profile on update. Grounding proved otherwise: `03` hard-requires 3 positional args (`name gateway_port dashboard_port`), and its inheritance step pushes the *default* agent's model onto a profile **unconditionally** — so re-running it on every update would **overwrite a profile intentionally set to a non-default model** (a regression, the exact anti-pattern this workstream fights). The safe fix is a *separate, small* follow-up: extract `03`'s step-4b inheritance logic into a shared helper that both `03` and a new update step call, guarded to inherit **only when the profile has no `model.provider` set** (heals the historical "no inference provider" gap without clobbering customizations). Deferred to keep Phase 2 low-risk; profile config survives `hermes update`, so this is a historical/drift heal, not a wipe-restore.
- **#8 — onboarding-injection patch.** Confirmed design-doc-only (no `scripts/11-*`; the plan doc even names a `10-patch-onboarding.sh` filename now taken by `10-install-fleetctl.sh`). Landing it is its own feature (rewrites Hermes's `onboarding.py`), not a re-apply-list change. Tracked separately.
- **#12 — non-cortex plugins.** Only the Cortex plugin is vendored/restored (via `04`). If a box ever grows another Hermes plugin, it would need the same vendor+re-apply treatment; no such plugin exists today, so no change (YAGNI).

---

## Self-Review

**1. Spec coverage (Phase 2 items):** #2 → Task 2; #7 → Task 3; #10 → Task 4; #11 → Task 5. #13/#8/#12 → Out of Scope with rationale. ✓
**2. Placeholder scan:** exact Python/bash/markdown in every code step; the only "locate it yourself" is the `--dry-run` argparse line (Task 1 Step 4), which is a standard, unambiguous argparse addition to a named subparser. ✓
**3. Type/name consistency:** `build_update_steps(component)`, step names (`reinstall-stack`, `reinstall-identity-sync`, `reinstall-orchestrator`), `has_step`/`steps_for` test helpers, and the `--dry-run`→`args.dry_run` flag are used consistently across Tasks 1-5. ✓
**4. Risk note for the executor:** the `update orchestrator` change swaps `git pull --ff-only` for `05`'s `git reset --hard origin/master` — intentional (matches provision), but means local orchestrator edits on a box are discarded on update. Called out in the Task 4 commit message. The `--dry-run` tests never execute real update steps, so they're safe to run anywhere with `python3`.
