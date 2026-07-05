# Idempotency Phase 1 — Stack `.env` Preservation Completeness — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `06-install-stack.sh` rewrite `~/hermes-stack/.env` without ever wiping an operator/Fleet-set key or shipping a stale image pin, and declare `CORTEX_API_KEY` so it can later be enabled safely.

**Architecture:** Extract the `.env` body rendering + key preservation out of `06-install-stack.sh` into a pure, sourceable helper (`scripts/lib/stack-env.sh`) with **no** docker/host side effects, so it is unit-testable in Git Bash. `06` sources it and calls one function. A new zero-dependency plain-bash test harness (`tests/`) exercises the helper against fixture `.env` files. Also declare `CORTEX_API_KEY` in the deployed `templates/docker-compose.yml` (both the `cortex` and `dashboard` services) so the key reaches the containers when set.

**Tech Stack:** Bash (POSIX-ish, `set -euo pipefail`), coreutils (`grep`/`cut`/`mktemp`), Docker Compose (integration check only). No test framework dependency (no bats) — a hand-rolled assert harness that runs in Git Bash on Windows and bash on the Linux boxes.

## Global Constraints

- **Commits are LOCAL + UNPUSHED**, stacked on the install repo's current `master` HEAD (`f1bd2d2` = the Phase-0 spec commit on top of security `9d23b0f`). Do not push.
- **`CORTEX_API_KEY` stays UNSET on boxes** this pass — this plan ships *plumbing only* (preserve + compose declaration). Never write a non-empty `CORTEX_API_KEY` value into any committed file.
- **One preservation mechanism for operator keys:** inline "env var > old `.env` value > empty" read-forward inside the helper. **Drop `CORTEX_IMAGE`/`FRONTEND_IMAGE` from `preserve_env_keys`** — the script-derived pin is authoritative and must be the single `.env` line.
- **Preserve existing security-batch behaviors** of `06`: `set -euo pipefail`, the `preserve_env_keys` explicit `return 0` guard (so a missing key never aborts under `set -e`), and `chmod 600` on the final `.env`.
- **No new runtime dependencies.** Tests use only bash + coreutils.
- Zero behavior change for keys already handled correctly (`HERMES_GATEWAY_KEY`, `ORCHESTRATOR_KEY`, `AGENTS_JSON`, `FIRECRAWL_API_KEY`, `HERMES_UI_URL`, `VERTICAL`, all `OAUTH2_PROXY_*`, `DASHBOARD_USER/PASS`, `SUPABASE_*`).

---

## File Structure

- **Create `scripts/lib/stack-env.sh`** — pure helper. Defines `preserve_env_keys` (OAuth/dashboard/Supabase allowlist; image pins are dropped from it in Task 2) and `render_stack_env NEW_ENV OLD_ENV` (writes the canonical `.env` heredoc from caller-exported derived values + inline-forwards the operator keys from `OLD_ENV`). No docker, no host reads beyond `OLD_ENV`. Sourceable + unit-testable.
- **Modify `scripts/06-install-stack.sh`** — remove the inline `preserve_env_keys` definition (lines ~34-48), the three inline read-forward blocks (lines ~139-159), and the heredoc+preserve block (lines ~161-189); source the lib and call `render_stack_env`. Keep the snapshot-to-`ENV_OLD`, `chmod 600`, and everything else unchanged.
- **Modify `templates/docker-compose.yml`** — add `- CORTEX_API_KEY=${CORTEX_API_KEY:-}` to the `cortex` service env (it enforces the key) and the `dashboard` service env (its nginx injects the bearer via `generate-cortex-auth.sh`).
- **Create `tests/lib/assert.sh`** — assert helpers (`assert_eq`, `assert_count`, `finish`).
- **Create `tests/test-stack-env.sh`** — unit tests for `render_stack_env`.
- **Create `tests/README.md`** — one line: how to run (`bash tests/test-stack-env.sh`).

---

### Task 1: Test harness + extract `.env` rendering into a pure helper (no behavior change)

Characterization-first: stand up the harness and lock **current** behavior with a test, then move the logic **verbatim** (image pins still in `preserve_env_keys` — Task 2 removes them red-green) so this task is a true no-op refactor.

**Files:**
- Create: `tests/lib/assert.sh`
- Create: `tests/test-stack-env.sh`
- Create: `tests/README.md`
- Create: `scripts/lib/stack-env.sh`
- Modify: `scripts/06-install-stack.sh:34-48,139-189`

**Interfaces:**
- Produces: `scripts/lib/stack-env.sh` with:
  - `preserve_env_keys OLD NEW` — appends allowlisted keys present in `OLD` to `NEW` (returns 0 always).
  - `render_stack_env NEW OLD` — writes `NEW` from exported `GATEWAY_KEY ORCH_KEY CORTEX_IMAGE FRONTEND_IMAGE AGENTS_JSON` plus inline-forwarded operator keys read from `OLD`; then calls `preserve_env_keys OLD NEW`.
  - `assert_eq DESC ACTUAL EXPECTED`, `assert_count DESC FILE KEY N`, `finish` (from `tests/lib/assert.sh`).

- [ ] **Step 1: Write the assert harness**

Create `tests/lib/assert.sh`:
```bash
#!/usr/bin/env bash
# Minimal zero-dependency test asserts. Source this, call asserts, end with finish.
_tests=0; _fails=0
assert_eq() { # DESC ACTUAL EXPECTED
  _tests=$((_tests+1))
  if [ "$2" = "$3" ]; then echo "  ok: $1"
  else echo "  FAIL: $1"; echo "    expected: [$3]"; echo "    actual:   [$2]"; _fails=$((_fails+1)); fi
}
assert_count() { # DESC FILE KEY EXPECTED_COUNT  (counts lines matching ^KEY=)
  local n; n="$(grep -Ec "^$3=" "$2" || true)"
  assert_eq "$1" "$n" "$4"
}
finish() { echo; echo "$((_tests-_fails))/$_tests passed"; [ "$_fails" -eq 0 ]; }
```

- [ ] **Step 2: Write the characterization test (current behavior)**

Create `tests/test-stack-env.sh`:
```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/assert.sh"
. "$HERE/../scripts/lib/stack-env.sh"

# Derived host values that 06 computes before rendering.
export GATEWAY_KEY="gwkey123" ORCH_KEY="orchkey123"
export CORTEX_IMAGE="justnorthow/cortex@sha256:NEW"
export FRONTEND_IMAGE="justnorthow/frontend@sha256:NEW"
export AGENTS_JSON='[{"id":"default","name":"Ollie"}]'

# Baseline: derived keys land; a preserved OAuth key survives.
test_baseline() {
  local old new; old="$(mktemp)"; new="$(mktemp)"
  cat > "$old" <<'OLD'
OAUTH2_PROXY_CLIENT_ID=abc123
OAUTH2_PROXY_COOKIE_SECRET=sekret
SUPABASE_URL=https://x.supabase.co
DASHBOARD_USER=admin
OLD
  ( unset FIRECRAWL_API_KEY HERMES_UI_URL VERTICAL \
          CORTEX_API_KEY HERMES_UI_HOSTNAME DASHBOARD_BIND HIA_BASE_URL
    render_stack_env "$new" "$old" )
  assert_eq  "HERMES_GATEWAY_KEY derived" "$(grep -E '^HERMES_GATEWAY_KEY=' "$new" | cut -d= -f2-)" "gwkey123"
  assert_eq  "ORCHESTRATOR_KEY derived"   "$(grep -E '^ORCHESTRATOR_KEY=' "$new" | cut -d= -f2-)" "orchkey123"
  assert_eq  "OAuth client id preserved"  "$(grep -E '^OAUTH2_PROXY_CLIENT_ID=' "$new" | cut -d= -f2-)" "abc123"
  assert_eq  "cookie secret preserved"    "$(grep -E '^OAUTH2_PROXY_COOKIE_SECRET=' "$new" | cut -d= -f2-)" "sekret"
  assert_eq  "SUPABASE_URL preserved"     "$(grep -E '^SUPABASE_URL=' "$new" | cut -d= -f2-)" "https://x.supabase.co"
  assert_eq  "DASHBOARD_USER preserved"   "$(grep -E '^DASHBOARD_USER=' "$new" | cut -d= -f2-)" "admin"
  rm -f "$old" "$new"
}

test_baseline
finish
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bash tests/test-stack-env.sh`
Expected: FAIL — `render_stack_env: command not found` (helper does not exist yet).

- [ ] **Step 4: Create the helper by extracting from `06` (verbatim, minus image-pin preserve)**

Create `scripts/lib/stack-env.sh`:
```bash
#!/usr/bin/env bash
# Pure stack-.env renderer. No docker/host access; reads only the old .env
# (if given) + caller-exported derived values. Sourceable + unit-testable.
# 06-install-stack.sh sources this and calls render_stack_env.

# Read one key's value from an env file (last occurrence); empty if absent.
_env_val() { [ -f "$1" ] || return 0; grep -E "^$2=" "$1" | tail -1 | cut -d= -f2- || true; }

# Resolve an operator-supplied key: exported env var > old .env value > empty.
_forward() { # VARNAME OLDENV
  local cur="${!1:-}"
  if [ -n "$cur" ]; then printf '%s' "$cur"; else _env_val "$2" "$1"; fi
}

# Carry forward keys this script does not manage but must not wipe (Fleet/operator
# writes them via set-dashboard-auth etc.).
# NOTE: this is a VERBATIM extract of 06's current preserve list — image pins
# INCLUDED — so Task 1 is a true no-op refactor. Task 2 removes CORTEX_IMAGE /
# FRONTEND_IMAGE from this list (red-green) so the script-derived pin is the
# single authoritative .env line.
# $1 = old .env, $2 = new .env
preserve_env_keys() {
  [ -f "$1" ] || return 0
  local k line
  for k in OAUTH2_PROXY_CLIENT_ID OAUTH2_PROXY_CLIENT_SECRET OAUTH2_PROXY_COOKIE_SECRET \
           OAUTH2_PROXY_REDIRECT_URL OAUTH2_PROXY_PROVIDER OAUTH2_PROXY_EMAIL_DOMAINS \
           OAUTH2_PROXY_AUTHENTICATED_EMAILS_FILE DASHBOARD_PUBLIC_HTTPS \
           DASHBOARD_USER DASHBOARD_PASS \
           SUPABASE_URL SUPABASE_ANON_KEY SUPABASE_COOKIE_DOMAIN \
           CORTEX_IMAGE FRONTEND_IMAGE; do
    line=$(grep -E "^${k}=" "$1" | tail -1) && [ -n "$line" ] && echo "$line" >> "$2"
  done
  # The last iteration's status leaks as the function's exit status under set -e;
  # return 0 so a missing key never aborts the caller before chmod/up.
  return 0
}

# Write the canonical stack .env. $1 = new path, $2 = old path (or "").
render_stack_env() {
  local out="$1" old="${2:-}"
  local firecrawl hermes_ui_url vertical
  firecrawl="$(_forward FIRECRAWL_API_KEY "$old")"
  hermes_ui_url="$(_forward HERMES_UI_URL "$old")"
  vertical="$(_forward VERTICAL "$old")"
  cat > "$out" <<EOF
# Generated by 06-install-stack.sh — re-run the script to refresh.
HERMES_GATEWAY_KEY=${GATEWAY_KEY}
ORCHESTRATOR_KEY=${ORCH_KEY}
CORTEX_IMAGE=${CORTEX_IMAGE}
FRONTEND_IMAGE=${FRONTEND_IMAGE}
AGENTS_JSON=${AGENTS_JSON}
# Brain Discovery: set this to enable website crawling (uploads work without it).
FIRECRAWL_API_KEY=${firecrawl}
# Browser-facing HTTPS URL for the Hermes dashboard ("Backend Settings" link).
HERMES_UI_URL=${hermes_ui_url}
# Customer vertical slug (e.g. real-estate) — Fleet-managed; empty = generic.
VERTICAL=${vertical}
EOF
  [ -n "$old" ] && preserve_env_keys "$old" "$out" || true
  return 0
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/test-stack-env.sh`
Expected: PASS — `6/6 passed`.

- [ ] **Step 6: Wire `06-install-stack.sh` to the helper**

In `scripts/06-install-stack.sh`: (a) **delete** the inline `preserve_env_keys()` definition (the block at ~lines 27-48, comment through `}`). (b) After `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`, add:
```bash
# shellcheck source=lib/stack-env.sh
. "${SCRIPT_DIR}/lib/stack-env.sh"
```
(c) **Delete** the three inline read-forward blocks for `FIRECRAWL_API_KEY`, `HERMES_UI_URL`, `VERTICAL` (the `EXISTING_*` + `X="${X:-...}"` blocks, ~lines 139-159) — the helper now does this. (d) Replace the heredoc + preserve block (`cat > "${STACK_ENV}" <<EOF ... preserve_env_keys ... rm -f "${ENV_OLD}"`, ~lines 169-189) with:
```bash
render_stack_env "${STACK_ENV}" "${ENV_OLD}"
[[ -n "${ENV_OLD}" ]] && rm -f "${ENV_OLD}"
```
Leave the `ENV_OLD` snapshot logic (lines ~164-168) and `chmod 600 "${STACK_ENV}"` intact. The derived exports (`GATEWAY_KEY`, `ORCH_KEY`, `CORTEX_IMAGE`, `FRONTEND_IMAGE`, `AGENTS_JSON`) must be exported or in scope when `render_stack_env` is called — they are module-level in `06`, so add `export GATEWAY_KEY ORCH_KEY CORTEX_IMAGE FRONTEND_IMAGE AGENTS_JSON` immediately before the call.

- [ ] **Step 7: Syntax-check `06` and the lib**

Run: `bash -n scripts/06-install-stack.sh && bash -n scripts/lib/stack-env.sh`
Expected: no output, exit 0. (If `shellcheck` is available: `shellcheck scripts/lib/stack-env.sh` — advisory.)

- [ ] **Step 8: Re-run tests (still green after wiring)**

Run: `bash tests/test-stack-env.sh`
Expected: PASS — `6/6 passed`.

- [ ] **Step 9: Commit**

```bash
git add scripts/lib/stack-env.sh scripts/06-install-stack.sh tests/lib/assert.sh tests/test-stack-env.sh tests/README.md
git commit -m "refactor(install): extract stack-.env rendering into testable helper + test harness

No behavior change. Pulls the heredoc + preserve + inline read-forward out of
06-install-stack.sh into scripts/lib/stack-env.sh so it is unit-testable, and
adds a zero-dependency bash test harness under tests/.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Image pins are single-line and script-authoritative (fix #1)

**Files:**
- Modify: `tests/test-stack-env.sh` (add the failing regression test)
- Modify: `scripts/lib/stack-env.sh` (remove the image pins from `preserve_env_keys`)

**Interfaces:**
- Consumes: `render_stack_env`, `assert_count`, `assert_eq` from Task 1.

- [ ] **Step 1: Write the failing test — old pin must NOT survive as a duplicate**

Add to `tests/test-stack-env.sh` (before the `finish` call at the end):
```bash
# A box already carrying an OLD pin must end up with exactly ONE pin line = the
# NEW script-derived digest (the duplicate-key/last-wins trap must be gone).
test_pins_single_and_new() {
  local old new; old="$(mktemp)"; new="$(mktemp)"
  cat > "$old" <<'OLD'
CORTEX_IMAGE=justnorthow/cortex@sha256:OLD
FRONTEND_IMAGE=justnorthow/frontend@sha256:OLD
OAUTH2_PROXY_CLIENT_ID=keepme
OLD
  ( unset FIRECRAWL_API_KEY HERMES_UI_URL VERTICAL \
          CORTEX_API_KEY HERMES_UI_HOSTNAME DASHBOARD_BIND HIA_BASE_URL
    render_stack_env "$new" "$old" )
  assert_count "exactly one CORTEX_IMAGE line"   "$new" "CORTEX_IMAGE" 1
  assert_count "exactly one FRONTEND_IMAGE line" "$new" "FRONTEND_IMAGE" 1
  assert_eq "CORTEX_IMAGE = new digest"   "$(grep -E '^CORTEX_IMAGE=' "$new" | cut -d= -f2-)"   "justnorthow/cortex@sha256:NEW"
  assert_eq "FRONTEND_IMAGE = new digest" "$(grep -E '^FRONTEND_IMAGE=' "$new" | cut -d= -f2-)" "justnorthow/frontend@sha256:NEW"
  assert_eq "unrelated OAuth key still preserved" "$(grep -E '^OAUTH2_PROXY_CLIENT_ID=' "$new" | cut -d= -f2-)" "keepme"
  rm -f "$old" "$new"
}

test_pins_single_and_new
```
(Place the `test_pins_single_and_new` call above `finish`.)

- [ ] **Step 2: Run to verify it FAILS**

Run: `bash tests/test-stack-env.sh`
Expected: FAIL — with pins still in `preserve_env_keys`, the rendered `.env` has TWO `CORTEX_IMAGE=` lines (heredoc NEW + preserved OLD), so `assert_count "exactly one CORTEX_IMAGE line" == 1` fails (actual `2`); same for `FRONTEND_IMAGE`.

- [ ] **Step 3: Remove the image pins from `preserve_env_keys`**

In `scripts/lib/stack-env.sh`, delete `CORTEX_IMAGE FRONTEND_IMAGE` from the `for k in …` allowlist (the last entry on the line ending `SUPABASE_URL SUPABASE_ANON_KEY SUPABASE_COOKIE_DOMAIN`), and update the function comment to state the script-derived pin (written in the heredoc) is the single authoritative line — pins are intentionally NOT preserved. Result:
```bash
  for k in OAUTH2_PROXY_CLIENT_ID OAUTH2_PROXY_CLIENT_SECRET OAUTH2_PROXY_COOKIE_SECRET \
           OAUTH2_PROXY_REDIRECT_URL OAUTH2_PROXY_PROVIDER OAUTH2_PROXY_EMAIL_DOMAINS \
           OAUTH2_PROXY_AUTHENTICATED_EMAILS_FILE DASHBOARD_PUBLIC_HTTPS \
           DASHBOARD_USER DASHBOARD_PASS \
           SUPABASE_URL SUPABASE_ANON_KEY SUPABASE_COOKIE_DOMAIN; do
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/test-stack-env.sh`
Expected: PASS — one pin line each, equal to the new digest; `test_baseline` still green (its fixture has no pins).

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/stack-env.sh tests/test-stack-env.sh
git commit -m "fix(install): drop image pins from preserve — script pin is authoritative (#1)

Removes the CORTEX_IMAGE/FRONTEND_IMAGE duplicate-key last-wins trap: a box
carrying an old pin now renders exactly one pin line = the script digest, so a
digest bump actually ships. Regression test locks it.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Declare + preserve `CORTEX_API_KEY` (fix #3, plumbing only)

**Files:**
- Modify: `scripts/lib/stack-env.sh` (add `CORTEX_API_KEY` inline-forward)
- Modify: `templates/docker-compose.yml:41,100` (declare in cortex + dashboard)
- Modify: `tests/test-stack-env.sh`

**Interfaces:**
- Consumes: `_forward`, `render_stack_env` from Task 1.

- [ ] **Step 1: Write the failing test — CORTEX_API_KEY forwarded, empty by default**

Add to `tests/test-stack-env.sh` (before `finish`):
```bash
# CORTEX_API_KEY must survive a re-run (forwarded from old .env), and default to
# empty when neither env var nor old .env set it (stays UNSET on boxes this pass).
test_cortex_api_key_forwarded() {
  local old new; old="$(mktemp)"; new="$(mktemp)"
  printf 'CORTEX_API_KEY=secret-token\n' > "$old"
  ( unset CORTEX_API_KEY FIRECRAWL_API_KEY HERMES_UI_URL VERTICAL \
          HERMES_UI_HOSTNAME DASHBOARD_BIND HIA_BASE_URL
    render_stack_env "$new" "$old" )
  assert_eq "CORTEX_API_KEY preserved" "$(grep -E '^CORTEX_API_KEY=' "$new" | cut -d= -f2-)" "secret-token"

  local old2 new2; old2="$(mktemp)"; new2="$(mktemp)"
  : > "$old2"
  ( unset CORTEX_API_KEY FIRECRAWL_API_KEY HERMES_UI_URL VERTICAL \
          HERMES_UI_HOSTNAME DASHBOARD_BIND HIA_BASE_URL
    render_stack_env "$new2" "$old2" )
  assert_count "CORTEX_API_KEY line present (empty ok)" "$new2" "CORTEX_API_KEY" 1
  assert_eq "CORTEX_API_KEY empty by default" "$(grep -E '^CORTEX_API_KEY=' "$new2" | cut -d= -f2-)" ""
  rm -f "$old" "$new" "$old2" "$new2"
}

test_cortex_api_key_forwarded
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test-stack-env.sh`
Expected: FAIL — no `CORTEX_API_KEY=` line in the rendered `.env`.

- [ ] **Step 3: Add the inline-forward to the helper**

In `scripts/lib/stack-env.sh` `render_stack_env`, after the `vertical="$(_forward VERTICAL "$old")"` line add:
```bash
  local cortex_api_key; cortex_api_key="$(_forward CORTEX_API_KEY "$old")"
```
and add this line to the heredoc, immediately after the `VERTICAL=${vertical}` line:
```bash
# Cortex API key. UNSET by default (open on the private Docker network). When set,
# cortex enforces it and the dashboard nginx injects it on /cortex-proxy.
CORTEX_API_KEY=${cortex_api_key}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/test-stack-env.sh`
Expected: PASS.

- [ ] **Step 5: Declare `CORTEX_API_KEY` in the deployed compose (both services)**

In `templates/docker-compose.yml`, in the **cortex** service `environment:` block, immediately after `- HERMES_GATEWAY_KEY=${HERMES_GATEWAY_KEY}` (line 41), add:
```yaml
      # Cortex enforces this bearer on all routes but /health when set. UNSET =
      # open on the private Docker network (today's behavior). Fleet/operator flip.
      - CORTEX_API_KEY=${CORTEX_API_KEY:-}
```
In the **dashboard** service `environment:` block, immediately after `- HERMES_GATEWAY_KEY=${HERMES_GATEWAY_KEY}` (line 100), add:
```yaml
      # generate-cortex-auth.sh (this container's nginx) injects
      # "Authorization: Bearer $CORTEX_API_KEY" on /cortex-proxy when set. UNSET =
      # no header (matches cortex being open on the Docker network).
      - CORTEX_API_KEY=${CORTEX_API_KEY:-}
```

- [ ] **Step 6: Assert compose declares it in both services**

Run: `grep -Ec '^\s*- CORTEX_API_KEY=\$\{CORTEX_API_KEY:-\}' templates/docker-compose.yml`
Expected: `2`

- [ ] **Step 7: Commit**

```bash
git add scripts/lib/stack-env.sh templates/docker-compose.yml tests/test-stack-env.sh
git commit -m "fix(install): plumb CORTEX_API_KEY (preserve + compose decl, both containers)

Adds CORTEX_API_KEY to the .env inline-forward so a stack re-install no longer
wipes it, and declares it on the cortex (enforces) and dashboard (injects) compose
services. Key stays UNSET on boxes this pass — plumbing only (fix #3, D5).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Preserve operator tunables `HERMES_UI_HOSTNAME`, `DASHBOARD_BIND`, `HIA_BASE_URL` (fixes #16, #17)

**Files:**
- Modify: `scripts/lib/stack-env.sh`
- Modify: `tests/test-stack-env.sh`

**Interfaces:**
- Consumes: `_forward`, `render_stack_env`.

> `LOG_LEVEL` and `DISCOVERY_MAX_*` are intentionally left as compose defaults (YAGNI — they are cosmetic and default-safe; not written by `06` today). Add them here identically only if an operator is known to tune them.

- [ ] **Step 1: Write the failing test**

Add to `tests/test-stack-env.sh` (before `finish`):
```bash
# Operator-set dashboard/host tunables must survive a re-run instead of drifting
# back to the compose defaults.
test_operator_tunables_preserved() {
  local old new; old="$(mktemp)"; new="$(mktemp)"
  cat > "$old" <<'OLD'
HERMES_UI_HOSTNAME=hermes.jnow.io
DASHBOARD_BIND=0.0.0.0
HIA_BASE_URL=https://hia.example.com
OLD
  ( unset HERMES_UI_HOSTNAME DASHBOARD_BIND HIA_BASE_URL \
          CORTEX_API_KEY FIRECRAWL_API_KEY HERMES_UI_URL VERTICAL
    render_stack_env "$new" "$old" )
  assert_eq "HERMES_UI_HOSTNAME preserved" "$(grep -E '^HERMES_UI_HOSTNAME=' "$new" | cut -d= -f2-)" "hermes.jnow.io"
  assert_eq "DASHBOARD_BIND preserved"     "$(grep -E '^DASHBOARD_BIND=' "$new" | cut -d= -f2-)" "0.0.0.0"
  assert_eq "HIA_BASE_URL preserved"       "$(grep -E '^HIA_BASE_URL=' "$new" | cut -d= -f2-)" "https://hia.example.com"
  rm -f "$old" "$new"
}

test_operator_tunables_preserved
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test-stack-env.sh`
Expected: FAIL — those keys are absent from the rendered `.env`.

- [ ] **Step 3: Add the three inline-forwards + heredoc lines**

In `render_stack_env`, after the `cortex_api_key` line add:
```bash
  local hermes_ui_hostname dashboard_bind hia_base_url
  hermes_ui_hostname="$(_forward HERMES_UI_HOSTNAME "$old")"
  dashboard_bind="$(_forward DASHBOARD_BIND "$old")"
  hia_base_url="$(_forward HIA_BASE_URL "$old")"
```
and append to the heredoc, after the `CORTEX_API_KEY=${cortex_api_key}` line:
```bash
# Operator tunables — preserved so a re-run never reverts them to compose defaults.
HERMES_UI_HOSTNAME=${hermes_ui_hostname}
DASHBOARD_BIND=${dashboard_bind}
HIA_BASE_URL=${hia_base_url}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/test-stack-env.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/stack-env.sh tests/test-stack-env.sh
git commit -m "fix(install): preserve HERMES_UI_HOSTNAME/DASHBOARD_BIND/HIA_BASE_URL (#16,#17)

These operator-set keys previously drifted back to compose defaults on every
stack re-install; now inline-forwarded like the other operator keys.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Comprehensive golden regression + compose resolution check

**Files:**
- Modify: `tests/test-stack-env.sh`

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: Write the full-fixture golden test**

Add to `tests/test-stack-env.sh` (before `finish`): an old `.env` carrying **every** operator/Fleet key + old pins, asserting each survives exactly once with the right value and pins are the new digest.
```bash
test_golden_full_env() {
  local old new; old="$(mktemp)"; new="$(mktemp)"
  cat > "$old" <<'OLD'
CORTEX_IMAGE=justnorthow/cortex@sha256:OLD
FRONTEND_IMAGE=justnorthow/frontend@sha256:OLD
OAUTH2_PROXY_CLIENT_ID=cid
OAUTH2_PROXY_CLIENT_SECRET=csecret
OAUTH2_PROXY_COOKIE_SECRET=cookiesecret
OAUTH2_PROXY_REDIRECT_URL=https://x/oauth2/callback
OAUTH2_PROXY_PROVIDER=google
OAUTH2_PROXY_EMAIL_DOMAINS=*
OAUTH2_PROXY_AUTHENTICATED_EMAILS_FILE=/etc/oauth2-proxy/emails
DASHBOARD_PUBLIC_HTTPS=true
DASHBOARD_USER=admin
DASHBOARD_PASS=pw
SUPABASE_URL=https://x.supabase.co
SUPABASE_ANON_KEY=sb_anon
SUPABASE_COOKIE_DOMAIN=.jnow.io
FIRECRAWL_API_KEY=fc_key
HERMES_UI_URL=https://ui.jnow.io
VERTICAL=real-estate
CORTEX_API_KEY=cortex-secret
HERMES_UI_HOSTNAME=hermes.jnow.io
DASHBOARD_BIND=0.0.0.0
HIA_BASE_URL=https://hia
OLD
  ( unset FIRECRAWL_API_KEY HERMES_UI_URL VERTICAL CORTEX_API_KEY \
          HERMES_UI_HOSTNAME DASHBOARD_BIND HIA_BASE_URL
    render_stack_env "$new" "$old" )
  local k
  for k in OAUTH2_PROXY_CLIENT_ID OAUTH2_PROXY_CLIENT_SECRET OAUTH2_PROXY_COOKIE_SECRET \
           OAUTH2_PROXY_REDIRECT_URL OAUTH2_PROXY_PROVIDER OAUTH2_PROXY_EMAIL_DOMAINS \
           OAUTH2_PROXY_AUTHENTICATED_EMAILS_FILE DASHBOARD_PUBLIC_HTTPS DASHBOARD_USER \
           DASHBOARD_PASS SUPABASE_URL SUPABASE_ANON_KEY SUPABASE_COOKIE_DOMAIN \
           FIRECRAWL_API_KEY HERMES_UI_URL VERTICAL CORTEX_API_KEY HERMES_UI_HOSTNAME \
           DASHBOARD_BIND HIA_BASE_URL CORTEX_IMAGE FRONTEND_IMAGE; do
    assert_count "exactly one ${k}" "$new" "$k" 1
  done
  assert_eq "pin bumped to new" "$(grep -E '^CORTEX_IMAGE=' "$new" | cut -d= -f2-)" "justnorthow/cortex@sha256:NEW"
  assert_eq "supabase cookie domain preserved" "$(grep -E '^SUPABASE_COOKIE_DOMAIN=' "$new" | cut -d= -f2-)" ".jnow.io"
  assert_eq "apollo-not-a-key sanity: vertical preserved" "$(grep -E '^VERTICAL=' "$new" | cut -d= -f2-)" "real-estate"
  rm -f "$old" "$new"
}

test_golden_full_env
```

- [ ] **Step 2: Run to verify it passes**

Run: `bash tests/test-stack-env.sh`
Expected: PASS — all green.

- [ ] **Step 3: (Integration, requires Docker) verify compose resolves the pin + CORTEX_API_KEY to both services**

Run:
```bash
tmp="$(mktemp -d)"; cat > "$tmp/.env" <<'ENV'
CORTEX_IMAGE=justnorthow/ollie-hermes-cortex:latest
FRONTEND_IMAGE=justnorthow/ollie-hermes-frontend:latest
HERMES_GATEWAY_KEY=x
CORTEX_API_KEY=probe-value
ENV
docker compose --env-file "$tmp/.env" -f templates/docker-compose.yml config 2>/dev/null \
  | grep -c 'CORTEX_API_KEY: probe-value'
rm -rf "$tmp"
```
Expected: `2` (present in both the cortex and dashboard resolved environments). If Docker is unavailable, skip this step and note it — the unit tests are the required gate.

- [ ] **Step 4: Commit**

```bash
git add tests/test-stack-env.sh
git commit -m "test(install): golden full-.env preservation regression (all 22 keys)

Every operator/Fleet key survives a stack re-render exactly once with its value;
pins bump to the new digest. Closes the Phase 1 .env-completeness coverage.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**1. Spec coverage (Phase 1 items in the design §6):**
- #1 image-pin duplicate → Task 1 (drop from preserve) + Task 2 (regression). ✓
- #3 CORTEX_API_KEY preserve + compose decl (both containers) → Task 3. ✓
- #16 HERMES_UI_HOSTNAME → Task 4. ✓
- #17 operator tunables (DASHBOARD_BIND, HIA_BASE_URL) → Task 4; LOG_LEVEL/DISCOVERY_* consciously deferred (YAGNI, noted). ✓
- R1 single preservation mechanism → helper uses inline-forward; pins dropped from preserve. ✓
- Security-batch behaviors preserved (return-0 guard, chmod 600, set -e) → carried verbatim in Task 1 Step 4/6. ✓

**2. Placeholder scan:** No TBD/TODO; every code step shows exact content; every run step has an expected result. ✓

**3. Type/name consistency:** `render_stack_env NEW OLD`, `preserve_env_keys OLD NEW`, `_forward VARNAME OLDENV`, `_env_val FILE KEY`, `assert_eq/assert_count/finish` — used consistently across Tasks 1-5. Heredoc var names (`firecrawl`, `hermes_ui_url`, `vertical`, `cortex_api_key`, `hermes_ui_hostname`, `dashboard_bind`, `hia_base_url`) match their `_forward` assignments. ✓

**4. Open item for the executor:** confirm the exact line numbers in `06-install-stack.sh` at edit time (they shift as blocks are deleted top-to-bottom — delete the `preserve_env_keys` definition first, then the read-forward blocks, then the heredoc block, re-reading between deletions).
