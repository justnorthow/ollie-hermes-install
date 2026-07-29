# Multi-App Agent Manifests Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let one agent profile bundle more than one app, so a real-estate install can bring Home Inspection Advisor and Newsletter Studio alongside Pop Bys.

**Architecture:** `scripts/24-install-agent-apps.sh` gains an app-name filter and per-app stdin keys. Host/tarball values resolve per app into per-iteration locals — never by reassigning the shared stdin variables, which is the leak the existing guard was hiding. The manifest gains a per-app `server.env` map. An app-bridge reachability check mirrors the Supabase one.

**Tech Stack:** Bash (`set -euo pipefail`), Python 3 for manifest reads, shim-based shell tests.

## Global Constraints

- **Never reassign the bare `APP_HOST` / `SB_HOST` / `IMAGE_TARBALL` stdin variables inside the per-app loop.** With two apps that leaks app 0's values into app 1 and the second app silently gets the first app's Supabase host. This is the single most important rule in this plan.
- The bare stdin keys are legal **only when exactly one app is being installed** (single-app manifest, or narrowed by the filter). With two or more targets, a value with no per-app key and no carry-forward is a fatal error naming the app and the key it wants.
- Script 24 must keep refusing to run as root, and must not try to install bridges itself — 25 needs root. It prints, as it already does for caddy.
- Existing single-app behaviour must be unchanged: today's invocation with bare `APP_HOST`/`SB_HOST`/`IMAGE_TARBALL` and no app name keeps working identically.
- Branch `feat/multi-app-manifests`, worktree `D:\ohi-multiapp`, base `ebf096a`, spec `7248d39`. Another session is active in the main checkout at `D:\workspaces\jnow\ollie-hermes-install` — do not touch it.
- Run tests with `bash tests/test-24-install-agent-apps.sh` from the repo root.

## File Structure

| File | Responsibility |
|---|---|
| `scripts/24-install-agent-apps.sh` (modify) | Filter, per-app resolution, `server.env`, bridge check, guard removal. |
| `tests/test-24-install-agent-apps.sh` (modify) | Two-app fixture, per-app stub, new cases. |
| `apps/real-estate.json` (modify, Task 4) | Re-land the HIA entry. |

---

### Task 1: App-name filter and per-app resolution

**Files:**
- Modify: `scripts/24-install-agent-apps.sh` — stdin parsing (~:39-54), the guard (~:62-66), the loop head (~:159-171)
- Modify: `tests/test-24-install-agent-apps.sh` — fixture, SUB20 stub, `run` helper, new cases

**Interfaces:**
- Consumes: nothing.
- Produces: `env_key_for(name, key)`, `per_app_val(name, basekey)`, the `TARGETS` index array, and per-iteration locals `APP_HOST_I` / `SB_HOST_I` / `TARBALL_I` that Tasks 2-3 read.

- [ ] **Step 1: Make the test harness multi-app capable**

In `tests/test-24-install-agent-apps.sh`, the SUB20 stub hardcodes `popbys`. Replace its body so it materialises a stack `.env` for whichever `STACK_NAME` it is given:

```bash
cat > "$T/bin/sub20.sh" <<'SH'
#!/usr/bin/env bash
set -eu
cat > "${SUB20_LOG}"
# Multi-app: materialise the stack .env for whichever app we were called for,
# so 24's per-app carry-forward reads that app's own values.
name="$(grep -E '^STACK_NAME=' "${SUB20_LOG}" | tail -n1 | cut -d= -f2-)"
pub="$(grep -E '^SUPABASE_PUBLIC_URL=' "${SUB20_LOG}" | tail -n1 | cut -d= -f2-)"
site="$(grep -E '^SITE_URL=' "${SUB20_LOG}" | tail -n1 | cut -d= -f2-)"
mkdir -p "${STACKS_DIR}/${name}"
cat > "${STACKS_DIR}/${name}/.env" <<ENVEOF
ANON_KEY=stub-anon
POSTGRES_PASSWORD=pw
SUPABASE_PUBLIC_URL=${pub}
SITE_URL=${site}
SERVICE_ROLE_KEY=stub-service-role
ENVEOF
SH
```

Note `SUB20_LOG` is overwritten per call, so later assertions see the LAST app's params. Where a test needs app 0's params, capture the log between runs.

Add a second manifest fixture beside the existing one — a two-app profile. Append after the existing `real-estate.json` heredoc:

```bash
cat > "$MANIFEST_DIR/two-app.json" <<'JSON'
{
  "profile": "two-app",
  "agent": { "display_name": "Two", "subtitle": "Two apps", "color": "#111111" },
  "apps": [
    {
      "name": "alpha",
      "stack": { "kong_port": 8010, "email_enabled": "false" },
      "server": { "app_port": 8110, "container_port": 3000, "health_path": "/apps/alpha/api/health" }
    },
    {
      "name": "beta",
      "stack": { "kong_port": 8020, "email_enabled": "false" },
      "server": { "app_port": 8120, "container_port": 3000, "health_path": "/apps/beta/api/health" }
    }
  ]
}
JSON
```

Neither app has a `tile`, so the tile-registration path stays out of these cases.

Extend the `run` helper (currently around line 338) to take an optional app name:

```bash
run() {  # run <profile> [app-name] <stdin lines...>
  local profile="$1"; shift
  local appname=""
  if [[ "${1:-}" != *=* && -n "${1:-}" ]]; then appname="$1"; shift; fi
  printf '%s\n' "$@" | bash "${DIR}/scripts/24-install-agent-apps.sh" "${profile}" ${appname:+"${appname}"} > "$T/out.log" 2>&1
}
```

- [ ] **Step 2: Write the failing tests**

Append to `tests/test-24-install-agent-apps.sh`, before its final summary block:

```bash
# ---- multi-app manifests ----
reset_logs() {
  : > "$DOCKER_LOG"; : > "$SUB20_LOG"; : > "$SUB23_LOG"; : > "$CURL_LOG"
  rm -f "$CURL_LOG.payload" "$CURL_FAIL_FILE"
  rm -rf "$APPLY_LOG_DIR"; mkdir -p "$APPLY_LOG_DIR"; rm -f "$APPLY_COUNT_FILE"
  rm -rf "${STACKS_DIR:?}"/alpha "${STACKS_DIR:?}"/beta
}

# M1. a two-app manifest no longer hard-fails
reset_logs
run "two-app" \
  "SB_HOST_ALPHA=sb-alpha.test" "APP_HOST_ALPHA=alpha.test" \
  "SB_HOST_BETA=sb-beta.test"  "APP_HOST_BETA=beta.test" \
  "IMAGE_TARBALL_ALPHA=/tmp/a.tar" "IMAGE_TARBALL_BETA=/tmp/b.tar" \
  "ORCH_ENV_FILE=$T/hermes-stack/.env" \
  && ok "two-app manifest installs" || bad "two-app manifest installs"
grep -q "multi-app manifests are not yet supported" "$T/out.log" \
  && bad "guard is gone" || ok "guard is gone"

# M2. THE LEAK: each app got its OWN host, not app 0's
grep -q '^SUPABASE_PUBLIC_URL=https://sb-beta.test$' "$SUB20_LOG" \
  && ok "app 1 got its own SB_HOST (no leak from app 0)" \
  || bad "app 1 got its own SB_HOST (no leak from app 0)"
grep -q 'sb-alpha' "$SUB20_LOG" \
  && bad "app 1 must not see app 0's host" || ok "app 1 must not see app 0's host"

# M3. the filter installs ONLY the named app
reset_logs
run "two-app" "alpha" \
  "SB_HOST=sb-alpha.test" "APP_HOST=alpha.test" "IMAGE_TARBALL=/tmp/a.tar" \
  "ORCH_ENV_FILE=$T/hermes-stack/.env" \
  && ok "filter run exits 0" || bad "filter run exits 0"
grep -q '^STACK_NAME=alpha$' "$SUB20_LOG" && ok "filter installed alpha" || bad "filter installed alpha"
[[ -f "${STACKS_DIR}/beta/.env" ]] && bad "filter must not install beta" || ok "filter must not install beta"

# M4. bare keys are legal for a single target (the filter narrowed it to one)
grep -q '^SUPABASE_PUBLIC_URL=https://sb-alpha.test$' "$SUB20_LOG" \
  && ok "bare SB_HOST applies to a single target" || bad "bare SB_HOST applies to a single target"

# M5. bare keys are REFUSED when two apps are in play — the silent-collision guard
reset_logs
run "two-app" \
  "SB_HOST=sb-shared.test" "APP_HOST=shared.test" "IMAGE_TARBALL=/tmp/x.tar" \
  "ORCH_ENV_FILE=$T/hermes-stack/.env" \
  && bad "bare keys with 2 apps must fail" || ok "bare keys with 2 apps must fail"
grep -qi "SB_HOST_ALPHA" "$T/out.log" \
  && ok "error names the per-app key to pass" || bad "error names the per-app key to pass"

# M6. an unknown app name errors and lists the valid ones
reset_logs
run "two-app" "nope" "ORCH_ENV_FILE=$T/hermes-stack/.env" \
  && bad "unknown app name must fail" || ok "unknown app name must fail"
grep -q "alpha" "$T/out.log" && ok "unknown-name error lists valid names" || bad "unknown-name error lists valid names"

# M7. single-app behaviour is unchanged (regression guard for the existing flow)
reset_logs
run "real-estate" "${STDIN[@]}" && ok "single-app path still works" || bad "single-app path still works"
grep -q '^STACK_NAME=popbys$' "$SUB20_LOG" && ok "single-app still installs popbys" || bad "single-app still installs popbys"
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `bash tests/test-24-install-agent-apps.sh`
Expected: M1-M6 FAIL (the guard rejects `two-app`; the filter argument is ignored). M7 passes — it is the existing behaviour and must stay green throughout.

- [ ] **Step 4: Parse the filter and the per-app keys**

In `scripts/24-install-agent-apps.sh`, after the existing `PROFILE` assignment near the top, add:

```bash
APP_NAME_FILTER="${2:-}"
```

In the stdin `case`, add these three patterns AFTER the exact-match arms for `APP_HOST`, `SB_HOST` and `IMAGE_TARBALL` (order matters — the exact names must win):

```bash
    SB_HOST_*|APP_HOST_*|IMAGE_TARBALL_*) PER_APP+=("${k}=${v}") ;;
```

and declare the array beside `PASSTHRU`:

```bash
declare -a PER_APP=()
```

- [ ] **Step 5: Add the resolution helpers**

Immediately after the `mf()` definition:

```bash
# Per-app stdin key for an app name: hia -> SB_HOST_HIA. Non-alphanumerics
# become underscores so a hyphenated app name still maps to a legal shell key.
env_key_for() {  # NAME BASEKEY
  local suffix="${1^^}"
  printf '%s_%s' "$2" "${suffix//[^A-Z0-9]/_}"
}

# Value of a per-app stdin key, or empty. Never falls back here — the caller
# owns the fallback order, because the bare-key fallback is only legal when a
# single app is being installed.
per_app_val() {  # NAME BASEKEY
  local want e
  want="$(env_key_for "$1" "$2")"
  for e in "${PER_APP[@]:-}"; do
    [[ "${e%%=*}" == "${want}" ]] && { printf '%s' "${e#*=}"; return 0; }
  done
  return 0
}
```

- [ ] **Step 6: Replace the guard with target selection**

Delete lines 62-66 (the `APP_COUNT > 1` guard) and put this in their place, keeping the `APP_COUNT` assignment above it:

```bash
# Which apps this run installs. With no filter, all of them; with a filter,
# just the named one. TARGETS drives both the loop and the bare-key rule below.
declare -a TARGETS=()
ALL_NAMES=""
for i in $(seq 0 $((APP_COUNT-1))); do
  n="$(mf "['apps'][${i}]['name']")"
  ALL_NAMES="${ALL_NAMES:+${ALL_NAMES} }${n}"
  [[ -z "${APP_NAME_FILTER}" || "${n}" == "${APP_NAME_FILTER}" ]] && TARGETS+=("${i}")
done
if [[ -n "${APP_NAME_FILTER}" && "${#TARGETS[@]}" -eq 0 ]]; then
  echo "error: no app named '${APP_NAME_FILTER}' in ${MANIFEST} (have: ${ALL_NAMES})" >&2
  exit 1
fi
```

- [ ] **Step 7: Resolve per app, into locals**

Change the loop header from `for i in $(seq 0 $((APP_COUNT-1))); do` to:

```bash
for i in "${TARGETS[@]}"; do
```

Then replace the three carry-forward/require lines (currently `:169-171`) with:

```bash
  # Resolve into PER-ITERATION locals. Assigning the bare SB_HOST/APP_HOST here
  # would leak app 0's values into app 1 — the bug the multi-app guard was
  # hiding, and a silent one: the second app would come up pointed at the first
  # app's Supabase.
  SB_HOST_I="$(per_app_val "${NAME}" SB_HOST)"
  APP_HOST_I="$(per_app_val "${NAME}" APP_HOST)"
  TARBALL_I="$(per_app_val "${NAME}" IMAGE_TARBALL)"
  # then this app's OWN stack .env, on re-runs
  [[ -z "${SB_HOST_I}" && -f "${SB_ENV}" ]] && SB_HOST_I="$(supabase_app_env_val "${SB_ENV}" SUPABASE_PUBLIC_URL)" && SB_HOST_I="${SB_HOST_I#https://}"
  [[ -z "${APP_HOST_I}" && -f "${SB_ENV}" ]] && APP_HOST_I="$(supabase_app_env_val "${SB_ENV}" SITE_URL)" && APP_HOST_I="${APP_HOST_I#https://}"
  # bare keys ONLY when this run installs exactly one app; with more targets a
  # bare value would be applied to every one of them, silently colliding.
  if [[ "${#TARGETS[@]}" -eq 1 ]]; then
    [[ -z "${SB_HOST_I}" ]] && SB_HOST_I="${SB_HOST}"
    [[ -z "${APP_HOST_I}" ]] && APP_HOST_I="${APP_HOST}"
    [[ -z "${TARBALL_I}" ]] && TARBALL_I="${IMAGE_TARBALL}"
  fi
  [[ -n "${SB_HOST_I}" ]] || { echo "error: no Supabase host for app '${NAME}' — pass $(env_key_for "${NAME}" SB_HOST)=<host> on stdin" >&2; exit 1; }
  [[ -n "${APP_HOST_I}" ]] || { echo "error: no site host for app '${NAME}' — pass $(env_key_for "${NAME}" APP_HOST)=<host> on stdin" >&2; exit 1; }
```

Then replace every later use of `${SB_HOST}`, `${APP_HOST}` and `${IMAGE_TARBALL}` INSIDE the loop with `${SB_HOST_I}`, `${APP_HOST_I}` and `${TARBALL_I}`. Read the whole loop body and change them all — a missed one reintroduces the leak. At minimum this covers the `SUPABASE_PUBLIC_URL=` / `SITE_URL=` lines in the 20 call, the `IMAGE_TARBALL` branch in the migrations step, and the `APP_ENV_SUPABASE_URL=` line in the 23 call.

- [ ] **Step 8: Run tests to verify they pass**

Run: `bash tests/test-24-install-agent-apps.sh`
Expected: all cases pass, including M7 (existing single-app behaviour).

- [ ] **Step 9: Commit**

```bash
git add scripts/24-install-agent-apps.sh tests/test-24-install-agent-apps.sh
git commit -m "feat(agent-apps): support multi-app manifests

Adds an app-name filter and per-app stdin keys (SB_HOST_<NAME> etc), so one
profile can bundle several apps. Hosts stay operator input rather than moving
into the manifest as the old guard's message advised: they are
instance-specific, and the manifest is shared by every instance.

Fixes what the guard was hiding — SB_HOST/APP_HOST were assigned inside the
per-app loop, so with the guard gone app 0's values would leak into app 1 and
the second app would come up pointed at the first app's Supabase. Resolution
now lands in per-iteration locals.

Bare keys are refused when two or more apps are in play; otherwise one value
would be applied to all of them, silently colliding.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: Per-app `server.env`

**Files:**
- Modify: `scripts/24-install-agent-apps.sh` (the 23 call), `tests/test-24-install-agent-apps.sh`

**Interfaces:**
- Consumes: Task 1's `TARGETS` loop.
- Produces: manifest `apps[i].server.env` reaching the rendered app `.env` as `APP_ENV_<KEY>`.

- [ ] **Step 1: Write the failing tests**

Add `"env": { "NODE_OPTIONS": "--max-http-header-size=65536", "DEMO_KEY": "from-manifest" }` to the `alpha` entry's `server` object in the `two-app.json` fixture, then append these cases:

```bash
# M8. manifest server.env reaches the app server
reset_logs
run "two-app" "alpha" \
  "SB_HOST=sb-alpha.test" "APP_HOST=alpha.test" "IMAGE_TARBALL=/tmp/a.tar" \
  "ORCH_ENV_FILE=$T/hermes-stack/.env"
grep -q '^APP_ENV_NODE_OPTIONS=--max-http-header-size=65536$' "$SUB23_LOG" \
  && ok "server.env reaches SUB23" || bad "server.env reaches SUB23"

# M9. operator stdin wins over a manifest server.env key of the same name
reset_logs
run "two-app" "alpha" \
  "SB_HOST=sb-alpha.test" "APP_HOST=alpha.test" "IMAGE_TARBALL=/tmp/a.tar" \
  "APP_ENV_DEMO_KEY=from-operator" \
  "ORCH_ENV_FILE=$T/hermes-stack/.env"
grep -q '^APP_ENV_DEMO_KEY=from-operator$' "$SUB23_LOG" \
  && ok "operator APP_ENV overrides manifest server.env" || bad "operator APP_ENV overrides manifest server.env"
grep -q '^APP_ENV_DEMO_KEY=from-manifest$' "$SUB23_LOG" \
  && bad "manifest value must not also be emitted" || ok "manifest value must not also be emitted"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/test-24-install-agent-apps.sh`
Expected: M8 and M9 FAIL — nothing reads `server.env` yet.

- [ ] **Step 3: Emit manifest env before the passthrough**

In the block that pipes into `SUB23`, immediately BEFORE the line that emits `"${PASSTHRU[@]}"`, add:

```bash
    # Per-app static env from the manifest. Emitted BEFORE the operator's
    # PASSTHRU so a stdin APP_ENV_<KEY> of the same name is written later and
    # wins in the rendered .env. This is where NODE_OPTIONS lives: every Node
    # tile app needs --max-http-header-size=65536 or SSO 431s and the tile
    # renders blank (Node's 16K default is smaller than the dashboard's
    # Supabase cookie jar plus the SSO token).
    while IFS= read -r kv; do [[ -n "${kv}" ]] && echo "APP_ENV_${kv}"; done < <(
      python3 -c "
import json
d=json.load(open('${MANIFEST}'))
for k,v in (d['apps'][${i}]['server'].get('env') or {}).items(): print(f'{k}={v}')
")
```

Confirm by reading `lib/app-server-env.sh` that a later duplicate key wins in the rendered `.env`. **If it does not, the operator-override test M9 will fail — say so and stop rather than reordering silently**, because the fix would then be a change to 23's rendering, which is out of scope here.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/test-24-install-agent-apps.sh`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add scripts/24-install-agent-apps.sh tests/test-24-install-agent-apps.sh
git commit -m "feat(agent-apps): per-app server.env in the manifest

Unlike hosts, static app env is app-specific rather than instance-specific,
so it belongs in the manifest. Operator APP_ENV_<KEY> still wins.

This is where NODE_OPTIONS=--max-http-header-size=65536 lives. Every Node
tile app needs it or SSO fails with 431 and the tile renders blank; Pop Bys
has carried it by hand since install and the value appeared nowhere in this
repo, which cost two debugging rounds on the HIA install.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: App-bridge reachability check

**Files:**
- Modify: `scripts/24-install-agent-apps.sh` (after the app-server step), `tests/test-24-install-agent-apps.sh`

**Interfaces:**
- Consumes: Task 1's loop locals; the existing `WARNINGS` counter and `curl` shim.
- Produces: a WARNING naming the exact `25-install-app-bridge.sh` command.

- [ ] **Step 1: Write the failing test**

The existing Supabase-bridge check uses the `curl` shim and `CURL_FAIL_FILE`. Read how that test forces a failure and mirror it:

```bash
# M10. a missing APP bridge warns, names the 25 command, and suppresses the banner
reset_logs
export CURL_FAIL_BRIDGE=1
run "two-app" "alpha" \
  "SB_HOST=sb-alpha.test" "APP_HOST=alpha.test" "IMAGE_TARBALL=/tmp/a.tar" \
  "ORCH_ENV_FILE=$T/hermes-stack/.env"
unset CURL_FAIL_BRIDGE
grep -q "25-install-app-bridge.sh alpha:8110" "$T/out.log" \
  && ok "missing app bridge names the 25 command" || bad "missing app bridge names the 25 command"
grep -q "⚠" "$T/out.log" && ok "missing app bridge suppresses ✓" || bad "missing app bridge suppresses ✓"
```

Extend the `curl` shim so `CURL_FAIL_BRIDGE=1` makes a request to `172.17.0.1:<app_port>` fail while leaving other calls alone. Read the shim before editing and follow its existing style.

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-24-install-agent-apps.sh`
Expected: M10 FAILS — nothing probes the app bridge.

- [ ] **Step 3: Add the check**

Directly after the Supabase-bridge check (around `:334-338`), add the mirror:

```bash
  # The APP bridge. Script 23 binds the app to 127.0.0.1 only, while the
  # dashboard container reaches tile apps over the docker0 gateway — so
  # without 25 the tile 502s with "connection refused" even though every
  # health check here passed on loopback. Diagnosed the hard way on the HIA
  # sandbox install, 2026-07-29. 24 cannot install it: 25 installs system
  # services and needs root, and 24 refuses to run as root.
  if ! curl -fsS --max-time 10 "http://172.17.0.1:${APP_PORT}${HEALTH_PATH}" >/dev/null 2>&1; then
    echo "    WARNING: ${NAME} is not reachable on the docker bridge (172.17.0.1:${APP_PORT}) — the dashboard tile will 502. Install the bridge: sudo bash ${SCRIPT_DIR}/25-install-app-bridge.sh ${NAME}:${APP_PORT}" >&2
    WARNINGS=$((WARNINGS+1))
  fi
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/test-24-install-agent-apps.sh`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add scripts/24-install-agent-apps.sh tests/test-24-install-agent-apps.sh
git commit -m "feat(agent-apps): warn when a tile app has no docker bridge

Script 23 binds apps to 127.0.0.1 only, while the dashboard container reaches
them over the docker0 gateway, so a missing 25 bridge makes the tile 502 with
'connection refused' while every loopback health check passes. That is exactly
how the HIA sandbox install failed. Mirrors the Supabase-bridge check already
here, prints the remedy, and counts a WARNING so the run ends in ⚠.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: Re-land the HIA manifest entry

**Files:**
- Modify: `apps/real-estate.json`

**Interfaces:**
- Consumes: Tasks 1-3.
- Produces: a two-app real-estate manifest that script 24 can now install.

- [ ] **Step 1: Restore the entry, with `server.env`**

Add to the `apps` array BEFORE `popbys` (this is `b8757d5`'s object plus the new `env` block):

```json
    {
      "name": "hia",
      "stack": { "kong_port": 8010, "email_enabled": "false" },
      "server": {
        "app_port": 8110,
        "container_port": 3000,
        "health_path": "/apps/hia/api/health",
        "env": { "NODE_OPTIONS": "--max-http-header-size=65536" }
      },
      "tile": {
        "label": "Home Inspection Advisor",
        "icon": "M3 12l2-2m0 0l7-7 7 7M5 10v10a1 1 0 001 1h3m10-11l2 2m-2-2v10a1 1 0 01-1 1h-3m-6 0a1 1 0 001-1v-4a1 1 0 011-1h2a1 1 0 011 1v4a1 1 0 001 1m-6 0h6",
        "description": "Inspection report analysis: buyer and seller reports, cost estimates",
        "order": 20
      }
    },
```

- [ ] **Step 2: Verify**

```bash
python3 -c "import json; d=json.load(open('apps/real-estate.json')); print([a['name'] for a in d['apps']]); print([(a['stack']['kong_port'], a['server']['app_port']) for a in d['apps']]); print(d['apps'][0]['server'].get('env'))"
bash tests/test-24-install-agent-apps.sh
```

Expected: `['hia', 'popbys']`; `[(8010, 8110), (8030, 8130)]`; the `NODE_OPTIONS` dict; tests still pass.

- [ ] **Step 3: Commit**

```bash
git add apps/real-estate.json
git commit -m "feat(agent-apps): add HIA to the real-estate manifest

Re-lands b8757d5, reverted in ebf096a because script 24 rejected multi-app
manifests and the entry broke the whole profile including Pop Bys. Now that
24 supports them, plus the server.env carrying the NODE_OPTIONS every Node
tile app needs.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: Sandbox acceptance — install HIA the scripted way

**Files:** none — deployment and verification.

**Interfaces:**
- Consumes: Tasks 1-4, merged and pushed.
- Produces: HIA on the sandbox installed via the manifest, replacing the hand-driven install.

- [ ] **Step 1: Merge and push**

```bash
bash tests/test-24-install-agent-apps.sh
git checkout main && git merge --ff-only feat/multi-app-manifests && git push origin main
```

- [ ] **Step 2: Record the pre-state to compare against**

```bash
ssh ollie-sandbox 'docker exec hia-db psql -U supabase_admin -d postgres -tAc "select count(*) from public._app_migrations;"; grep -E "^(NODE_OPTIONS|SUPABASE_URL|SUPABASE_INTERNAL_URL)=" ~/apps/hia/.env; systemctl list-units "*bridge*" --no-pager --plain | grep hia'
```

Keep this output. The scripted install must reproduce it, not diverge from it.

- [ ] **Step 3: Run the scripted install for HIA only**

```bash
ssh ollie-sandbox 'cd ~/ollie-hermes-install && git pull --ff-only && printf "APP_HOST=olliesandbox.jnow.io\nSB_HOST=sb-hia-sandbox.jnow.io\nIMAGE_TARBALL=/tmp/hia-runtime.tar\nORCH_ENV_FILE=/home/ollie/.config/ollie-orchestrator/.env\n" | bash scripts/24-install-agent-apps.sh real-estate hia'
```

Bare keys are legal here because the filter narrows the run to one app. Expect the migrations step to skip all 12 as already applied, and the run to touch nothing of Pop Bys'.

- [ ] **Step 4: Verify it reproduced the hand-built state**

```bash
ssh ollie-sandbox 'docker exec hia-db psql -U supabase_admin -d postgres -tAc "select count(*) from public._app_migrations;"; grep -E "^NODE_OPTIONS=" ~/apps/hia/.env; curl -s -o /dev/null -w "app health: %{http_code}\n" http://172.17.0.1:8110/apps/hia/api/health; curl -s http://127.0.0.1:8110/apps/hia/login | grep -o "__HIA_CONFIG__ = {[^}]*}" | head -1'
```

Expected: still 12 migrations (not 24 — the tracker prevented re-application); `NODE_OPTIONS` present; health 200; the injected config still naming `sb-hia-sandbox.jnow.io`.

- [ ] **Step 5: Confirm Pop Bys is untouched**

```bash
ssh ollie-sandbox 'curl -s -o /dev/null -w "popbys health: %{http_code}\n" http://172.17.0.1:8130/api/health; docker ps --format "{{.Names}}" | grep -c popbys'
```

Expected: 200, and the same popbys container count as before.

- [ ] **Step 6: Ask the human partner to re-check the tile in the browser**

The scripted install recreates the app container. Ask them to confirm the HIA tile still loads and SSO still works, and report what they saw. Do not claim success on curl alone — SSO is the half curl cannot exercise.

---

## Self-Review

**Spec coverage.** Filter → Task 1 Steps 4, 6. Per-app keys → Task 1 Steps 4, 5, 7. Resolution order → Task 1 Step 7. Leak fix (per-iteration locals) → Task 1 Step 7, tested by M2. Bare-fallback rule → Task 1 Step 7, tested by M4/M5. Guard removal → Task 1 Step 6, tested by M1. `server.env` → Task 2. App-bridge check → Task 3. Re-land HIA → Task 4. Acceptance → Task 5.

**Placeholder scan.** No TBDs. Every code step carries real code. Two steps direct the implementer to read existing code before editing (the `curl` shim in Task 3, `lib/app-server-env.sh` in Task 2) because the plan cannot state their contents reliably — each says what to look for and what to do if the assumption fails.

**Type consistency.** `env_key_for(NAME, BASEKEY)` and `per_app_val(NAME, BASEKEY)` take the same argument order at every definition and call site. `TARGETS` is an index array in Steps 6 and 7. The locals `SB_HOST_I` / `APP_HOST_I` / `TARBALL_I` are named identically in Step 7 and referenced by Tasks 2-3.

**Known limitations, stated rather than hidden.**
- Task 1 Step 7 asks the implementer to find and convert *every* in-loop use of the three bare variables. The plan names the ones it knows about, but a missed one silently reintroduces the leak, and only M2 would catch it. That test is therefore load-bearing.
- Task 2 Step 3 depends on later duplicate keys winning in the rendered `.env`. If they do not, M9 fails and the fix belongs in script 23 — out of scope, so the plan says stop rather than reorder.
- Task 5 uses bare keys via the filter, so it does NOT exercise the per-app-key path on real infrastructure. That path is covered by tests only until a second app is installed for real, which is Newsletter Studio's job.
