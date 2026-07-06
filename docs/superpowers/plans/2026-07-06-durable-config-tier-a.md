# Durable Per-Box Config — Tier A Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make re-running `06-install-stack.sh` preserve the RBAC `scope`/`manager_visible` tags in `AGENTS_JSON`, and make `ollie-fleetctl update hermes` self-heal stale dashboard units stuck on `--host 0.0.0.0` — so an update can no longer re-break a box's RBAC or crash-loop a dashboard.

**Architecture:** Two independent, on-box changes in `ollie-hermes-install`. P1 extracts the `AGENTS_JSON` merge into a testable `scripts/lib/merge-agents-json.py` (matching the S74 "extract render → `scripts/lib/stack-env.sh`" pattern) and adds two preserved fields. P2 adds a testable `scripts/lib/heal-dashboard-units.sh` helper and wires it as a step in `build_update_steps("hermes")`.

**Tech Stack:** Bash + POSIX `sed`/`grep`, Python 3 (stdlib `json`), systemd `--user`, the repo's own `tests/lib/assert.sh` bash harness + `pytest` for `test_fleetctl.py`.

## Global Constraints

- **Commits LOCAL on `master`** (match the workstream convention; base = current tip `0905a1f`). Do not push unless asked.
- **Scope = Tier A only** (P1 + P2). Do NOT implement Tier B/C (P3–P7) from the spec.
- **Any fleetctl-touching change runs BOTH `pytest tests/test_fleetctl.py` AND every `tests/test-*.sh`** before commit (S74 lesson — a fleetctl edit once broke pytest while the bash tests passed and vice-versa).
- **Idempotent:** running either path twice produces zero drift (re-render `AGENTS_JSON` = same bytes for unchanged input; re-heal units = byte-identical).
- Spec: `docs/superpowers/specs/2026-07-06-durable-per-box-config-design.md`. Reference box: sandbox `ollie@178.105.216.167`.
- `assert.sh` signature is `assert_eq "<label>" "<actual>" "<expected>"`; each test file ends with `finish`.

---

### Task 1: P1 — `06` preserves `scope`/`manager_visible` in `AGENTS_JSON` (via extracted merge)

**Files:**
- Create: `scripts/lib/merge-agents-json.py`
- Modify: `scripts/06-install-stack.sh:92-115` (replace the inline `python3 <<'PY' … PY` heredoc with a call to the new script)
- Create test: `tests/test-merge-agents.sh`

**Interfaces:**
- Produces: `scripts/lib/merge-agents-json.py` — reads env `EXISTING_AGENTS` (prior `AGENTS_JSON`, JSON array; may be empty/absent) and `DETECTED` (JSON array of `{"id","gw","dash"}`); prints the merged `AGENTS_JSON` (compact, `separators=(",",":")`) to stdout. Preserves from the prior entry when present: `name`, `color`, `model`, `scope`, `manager_visible`. Always refreshes `gatewayUrl`/`dashboardUrl` from `DETECTED`; drops agents absent from `DETECTED`.

- [ ] **Step 1: Write the failing test**

Create `tests/test-merge-agents.sh`:
```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/assert.sh"
MERGE="$HERE/../scripts/lib/merge-agents-json.py"
PY="$(command -v python3 || command -v python)"
DETECTED='[{"id":"default","gw":8642,"dash":9119},{"id":"marketing-agent","gw":8643,"dash":9121}]'
field() { "$PY" -c 'import sys,json; a={x["id"]:x for x in json.load(sys.stdin)}; print(a[sys.argv[1]].get(sys.argv[2]))' "$1" "$2"; }

test_preserves_scope_and_manager_visible() {
  local existing='[{"id":"default","name":"Ollie","scope":"user","color":"#888"},{"id":"marketing-agent","name":"Olivia","manager_visible":true,"model":"gpt-5.5"}]'
  local out; out="$(EXISTING_AGENTS="$existing" DETECTED="$DETECTED" "$PY" "$MERGE")"
  assert_eq "default keeps scope:user"        "$(printf '%s' "$out" | field default scope)" "user"
  assert_eq "marketing keeps manager_visible" "$(printf '%s' "$out" | field marketing-agent manager_visible)" "True"
  assert_eq "color still preserved"           "$(printf '%s' "$out" | field default color)" "#888"
  assert_eq "model still preserved"           "$(printf '%s' "$out" | field marketing-agent model)" "gpt-5.5"
}
test_absent_scope_stays_absent() {
  local existing='[{"id":"default","name":"Ollie"}]'
  local out; out="$(EXISTING_AGENTS="$existing" DETECTED="$DETECTED" "$PY" "$MERGE")"
  assert_eq "no spurious scope key" "$(printf '%s' "$out" | "$PY" -c 'import sys,json; a={x["id"]:x for x in json.load(sys.stdin)}; print("scope" in a["default"])')" "False"
}
test_urls_refreshed_from_detected() {
  local existing='[{"id":"default","name":"Ollie","gatewayUrl":"http://old:1"}]'
  local out; out="$(EXISTING_AGENTS="$existing" DETECTED="$DETECTED" "$PY" "$MERGE")"
  assert_eq "gatewayUrl refreshed" "$(printf '%s' "$out" | field default gatewayUrl)" "http://host.docker.internal:8642"
}
test_preserves_scope_and_manager_visible
test_absent_scope_stays_absent
test_urls_refreshed_from_detected
finish
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-merge-agents.sh`
Expected: FAIL (the script `scripts/lib/merge-agents-json.py` does not exist yet → non-zero exits / assertion failures).

- [ ] **Step 3: Create the merge script**

Create `scripts/lib/merge-agents-json.py`:
```python
#!/usr/bin/env python3
# Merge detected agents with the EXISTING AGENTS_JSON so operator/wizard-set fields
# survive a re-run of 06. Reads EXISTING_AGENTS + DETECTED (both JSON) from the env,
# prints the merged AGENTS_JSON (compact) to stdout. Ports/URLs are always refreshed
# from DETECTED; an agent whose profile is gone (not in DETECTED) is dropped.
import json, os

try:
    prev = {a["id"]: a for a in json.loads(os.environ.get("EXISTING_AGENTS") or "[]")}
except Exception:
    prev = {}

out = []
for d in json.loads(os.environ["DETECTED"]):
    p = prev.get(d["id"], {})
    entry = {
        "id": d["id"],
        # Preserve a wizard-set displayName; else default (capitalized id; "Ollie" for default).
        "name": p.get("name") or ("Ollie" if d["id"] == "default" else d["id"].capitalize()),
        "gatewayUrl": f'http://host.docker.internal:{d["gw"]}',
        "dashboardUrl": f'http://host.docker.internal:{d["dash"]}',
    }
    if p.get("color"):
        entry["color"] = p["color"]
    if p.get("model"):
        entry["model"] = p["model"]
    # RBAC fields — preserve so a re-run of 06 never drops the scope:"user" tag on
    # Ollie (which fail-closes members out of their own assistant) or a company
    # agent's manager_visible flag.
    if p.get("scope"):
        entry["scope"] = p["scope"]
    if p.get("manager_visible"):
        entry["manager_visible"] = p["manager_visible"]
    out.append(entry)

print(json.dumps(out, separators=(",", ":")))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-merge-agents.sh`
Expected: PASS (all assertions, `finish` prints the OK summary).

- [ ] **Step 5: Wire `06` to call the extracted script**

In `scripts/06-install-stack.sh`, replace the whole inline merge block (currently the `AGENTS_JSON="$(EXISTING_AGENTS="${EXISTING_AGENTS}" DETECTED="${DETECTED}" python3 <<'PY'` … `PY` `)"` heredoc, lines ~92-115) with a call to the script:
```bash
# Merge detection with the EXISTING AGENTS_JSON so operator/wizard-set fields
# (displayName/color/model/scope/manager_visible) survive a re-run; ports/URLs are
# refreshed from detection; agents whose profile is gone are dropped.
EXISTING_AGENTS="$(grep -E '^AGENTS_JSON=' "${STACK_ENV}" 2>/dev/null | cut -d= -f2- || true)"
AGENTS_JSON="$(EXISTING_AGENTS="${EXISTING_AGENTS}" DETECTED="${DETECTED}" python3 "${SCRIPT_DIR}/lib/merge-agents-json.py")"
```
(Keep the existing `EXISTING_AGENTS=` line if it already sits just above; do not duplicate it. `SCRIPT_DIR` is already defined at the top of `06`.)

- [ ] **Step 6: Verify `06` still parses and the detected-agents echo still works**

Run: `bash -n scripts/06-install-stack.sh`
Expected: no output, exit 0 (syntax clean).
Run (smoke the merge exactly as 06 calls it): `EXISTING_AGENTS='[{"id":"default","name":"Ollie","scope":"user"}]' DETECTED='[{"id":"default","gw":8642,"dash":9119}]' python3 scripts/lib/merge-agents-json.py`
Expected: compact JSON containing `"scope":"user"` and `"gatewayUrl":"http://host.docker.internal:8642"`.

- [ ] **Step 7: Commit**

```bash
git add scripts/lib/merge-agents-json.py scripts/06-install-stack.sh tests/test-merge-agents.sh
git commit -m "feat(stack): preserve AGENTS_JSON scope/manager_visible across 06 re-run (P1)

Extract the AGENTS_JSON merge to testable scripts/lib/merge-agents-json.py and
add scope + manager_visible to the preserved fields. Re-running 06 no longer drops
the RBAC scope:\"user\" tag on Ollie (which would fail-close members out of their
own assistant). Spec: 2026-07-06-durable-per-box-config-design.md (Tier A P1).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: P2 — `update hermes` heals stale dashboard units (`--host 0.0.0.0` → `127.0.0.1`)

**Files:**
- Create: `scripts/lib/heal-dashboard-units.sh`
- Create test: `tests/test-heal-dashboard-units.sh`
- Modify: `templates/bin/ollie-fleetctl` (`build_update_steps`, the `hermes` block — add the heal step)
- Modify: `tests/test-fleetctl-update.sh` (assert the heal step is present)
- Modify: `README.md` (the "After a hermes update" section names the new step)

**Interfaces:**
- Produces: `scripts/lib/heal-dashboard-units.sh` — scans `${SYSTEMD_USER_DIR:-$HOME/.config/systemd/user}/hermes-dashboard*.service`; rewrites `--host 0.0.0.0` → `--host 127.0.0.1`; unless `HEAL_DASHBOARD_NO_RESTART=1` (test hook), `daemon-reload`s and restarts any dashboard unit not already active. Idempotent.
- Consumes (from Task-1 nothing; this task is independent). New `build_update_steps("hermes")` step name: `heal-dashboard-units`.

- [ ] **Step 1: Write the failing test**

Create `tests/test-heal-dashboard-units.sh`:
```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/assert.sh"
HEAL="$HERE/../scripts/lib/heal-dashboard-units.sh"

setup_dir() {
  local d; d="$(mktemp -d)"
  printf '[Service]\nExecStart=%%h/.local/bin/hermes dashboard --host 127.0.0.1 --port 9119 --insecure --no-open\n' > "$d/hermes-dashboard.service"
  printf '[Service]\nExecStart=%%h/.local/bin/hermes -p marketing-agent dashboard --host 0.0.0.0 --port 9121 --insecure --no-open\n' > "$d/hermes-dashboard-marketing-agent.service"
  printf '[Service]\nExecStart=%%h/.local/bin/hermes gateway --host 0.0.0.0 --port 8642\n' > "$d/hermes-gateway.service"
  echo "$d"
}

test_rewrites_stale_and_leaves_others() {
  local d; d="$(setup_dir)"
  local before_ok; before_ok="$(cat "$d/hermes-dashboard.service")"
  SYSTEMD_USER_DIR="$d" HEAL_DASHBOARD_NO_RESTART=1 bash "$HEAL" >/dev/null
  assert_eq "stale dashboard now on 127.0.0.1" "$(grep -c -- '--host 127.0.0.1' "$d/hermes-dashboard-marketing-agent.service")" "1"
  assert_eq "no 0.0.0.0 left in dashboard"     "$(grep -c -- '--host 0.0.0.0'   "$d/hermes-dashboard-marketing-agent.service")" "0"
  assert_eq "correct dashboard byte-identical" "$(cat "$d/hermes-dashboard.service")" "$before_ok"
  assert_eq "non-dashboard gateway untouched"  "$(grep -c -- '--host 0.0.0.0' "$d/hermes-gateway.service")" "1"
  rm -rf "$d"
}
test_idempotent() {
  local d; d="$(setup_dir)"
  SYSTEMD_USER_DIR="$d" HEAL_DASHBOARD_NO_RESTART=1 bash "$HEAL" >/dev/null
  local first; first="$(cat "$d/hermes-dashboard-marketing-agent.service")"
  SYSTEMD_USER_DIR="$d" HEAL_DASHBOARD_NO_RESTART=1 bash "$HEAL" >/dev/null
  assert_eq "second heal is a no-op" "$(cat "$d/hermes-dashboard-marketing-agent.service")" "$first"
  rm -rf "$d"
}
test_rewrites_stale_and_leaves_others
test_idempotent
finish
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-heal-dashboard-units.sh`
Expected: FAIL (`scripts/lib/heal-dashboard-units.sh` does not exist yet).

- [ ] **Step 3: Create the heal helper**

Create `scripts/lib/heal-dashboard-units.sh`:
```bash
#!/usr/bin/env bash
# Heal stale per-profile Hermes dashboard systemd units. An OLD installer wrote
# ExecStart '--host 0.0.0.0', which current Hermes REFUSES to bind without an auth
# provider ("Refusing to bind dashboard to 0.0.0.0") -> crash-loop. Rewrite any such
# unit to '--host 127.0.0.1' (the canonical value current install code writes),
# reload, and restart any dashboard unit that isn't running. Idempotent: a unit
# already on 127.0.0.1 is left byte-identical. Run as the service user.
set -uo pipefail
UNIT_DIR="${SYSTEMD_USER_DIR:-$HOME/.config/systemd/user}"
changed=0
shopt -s nullglob
for unit in "$UNIT_DIR"/hermes-dashboard*.service; do
  if grep -qE '^ExecStart=.*--host 0\.0\.0\.0' "$unit"; then
    sed -i 's/--host 0\.0\.0\.0/--host 127.0.0.1/g' "$unit"
    echo "healed $(basename "$unit"): --host 0.0.0.0 -> 127.0.0.1"
    changed=1
  fi
done
# Tests set HEAL_DASHBOARD_NO_RESTART=1 (no systemd --user in CI). Real runs reload
# + restart any dashboard unit that isn't active (covers a just-healed crash-looper).
if [ "${HEAL_DASHBOARD_NO_RESTART:-}" = 1 ]; then
  echo "heal-dashboard-units: rewrite-only (changed=$changed)"
  exit 0
fi
[ "$changed" = 1 ] && systemctl --user daemon-reload
for unit in "$UNIT_DIR"/hermes-dashboard*.service; do
  name="$(basename "$unit")"
  systemctl --user is-active --quiet "$name" && continue
  systemctl --user reset-failed "$name" 2>/dev/null || true
  systemctl --user restart "$name" 2>/dev/null || true
  echo "restarted $name"
done
echo "heal-dashboard-units: done (changed=$changed)"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-heal-dashboard-units.sh`
Expected: PASS (both tests, `finish` OK summary).

- [ ] **Step 5: Wire the heal step into `build_update_steps`**

In `templates/bin/ollie-fleetctl`, `build_update_steps`, inside the `if component in ("hermes", "all"):` list, add as the LAST entry of that block (after `reinstall-identity-sync`):
```python
            # Heal stale per-profile dashboard units still on --host 0.0.0.0 (crash-loop
            # under current Hermes). Idempotent; a correct unit is left byte-identical.
            ("heal-dashboard-units", ["bash", os.path.join(INSTALL_DIR, "scripts", "lib", "heal-dashboard-units.sh")], 60),
```

- [ ] **Step 6: Assert the step in the update-steps bash test**

In `tests/test-fleetctl-update.sh`, add to `test_hermes_reapply()` (after the identity-sync assertion):
```bash
  assert_eq "hermes heals dashboard units"     "$(has_step hermes heal-dashboard-units && echo y)" "y"
```

- [ ] **Step 7: Name the step in the README after-update section**

In `README.md`, in the `## After a hermes update` section, add `scripts/lib/heal-dashboard-units.sh` to the list of things the update re-applies (one bullet, matching the existing style). Then extend the README↔code test in `tests/test-fleetctl-update.sh` `test_readme_matches_code()` loop to include it:
```bash
  for s in 04-install-cortex-plugin.sh 07-patch-cron-brain.sh 08-install-souls.sh 09-install-identity-sync.sh heal-dashboard-units.sh; do
```

- [ ] **Step 8: Run the full test suites (BOTH pytest and bash — S74 lesson)**

Run: `python3 -m pytest tests/test_fleetctl.py -q`
Expected: PASS (no step-list assertions in pytest; must stay green).
Run: `for t in tests/test-*.sh; do echo "== $t =="; bash "$t" || break; done`
Expected: every bash test PASSES (`test-merge-agents.sh`, `test-heal-dashboard-units.sh`, `test-fleetctl-update.sh` with the new heal + README assertions, `test-stack-env.sh` unaffected).

- [ ] **Step 9: Commit**

```bash
git add scripts/lib/heal-dashboard-units.sh tests/test-heal-dashboard-units.sh templates/bin/ollie-fleetctl tests/test-fleetctl-update.sh README.md
git commit -m "feat(fleetctl): update hermes self-heals stale dashboard units (P2)

Adds scripts/lib/heal-dashboard-units.sh — rewrites any dashboard unit still on
ExecStart --host 0.0.0.0 (crash-loops under current Hermes) to --host 127.0.0.1,
reloads + restarts. Wired as the heal-dashboard-units step in build_update_steps
hermes so an update fixes a stale box instead of leaving it crash-looping.
Idempotent. Spec: 2026-07-06-durable-per-box-config-design.md (Tier A P2).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

- **Spec coverage:** Tier A P1 → Task 1 (extract + preserve scope/manager_visible + test). Tier A P2 → Task 2 (heal helper + wire into update hermes + tests + README). Tier B/C intentionally excluded per scope. ✓
- **Placeholders:** none — every step has exact file paths, full code, exact run commands + expected output. ✓
- **Type/name consistency:** the extracted script name (`scripts/lib/merge-agents-json.py`), the env var names (`EXISTING_AGENTS`/`DETECTED`), the step name (`heal-dashboard-units`), and the test hook (`HEAL_DASHBOARD_NO_RESTART`) are used identically in the code, the wiring, and the tests. ✓
- **Idempotency:** asserted directly (Task 1 `test_urls_refreshed`/absent-scope; Task 2 `test_idempotent`). ✓
- **S74 lesson:** Task 2 Step 8 runs BOTH pytest and every bash test before commit. ✓

## Out of Scope (Tier B/C — follow-up plan)

P3 (orchestrator proxy maps written by 05), P4 (dashboard token generated+persisted by install), P5 (Fleet writes INSTANCE_ID at enroll), P6 (Fleet-instructs-box RBAC seed), P7 (parity gate) — all deferred to a follow-up plan per the spec's phased build.
