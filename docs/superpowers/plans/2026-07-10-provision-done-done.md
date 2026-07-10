# Provision "Done Done" Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Fleet provision ends with a working, reachable, RBAC-seeded box — or fails loudly with an itemized gap list.

**Architecture:** Approach A from the spec (`docs/superpowers/specs/2026-07-10-provision-done-done-design.md`): install scripts own on-box derivable config (proxy maps, dashboard token, Supabase env application + verification, parity gate); Fleet owns what only it knows (instance UUID, operator email, form inputs, gate enforcement). Tasks 1–8 land in `ollie-hermes-install`, Tasks 9–13 in `ollie-fleet`, Task 14 is the cross-repo pin bump + acceptance.

**Tech Stack:** bash + python3 stdlib (install repo, zero-dep test harness in `tests/`), TypeScript/Hono/Vitest + better-sqlite3 (ollie-fleet).

## Global Constraints

- Install-repo scripts: `set -euo pipefail` for numbered scripts, `set -uo pipefail` for `scripts/lib/` helpers; root-guard on numbered scripts; env-var-overridable roots for testability; every lib helper gets a `tests/test-*.sh` using `tests/lib/assert.sh`.
- Idempotency invariant everywhere: run twice → zero drift (byte-identical files, no spurious restarts).
- fleetctl-touching changes run BOTH `python tests/test_fleetctl.py` AND `bash tests/test-fleetctl-update.sh` (S74 lesson). If a step is added to `build_update_steps`, also update the README "## After a hermes update" section (test `test_readme_matches_code` enforces this).
- ollie-fleet: `npm test` (vitest). New instances columns go in the try/catch `ALTER TABLE` loop in `src/server/db.ts` (~line 138), the `Instance` type in `src/shared/types.ts`, and a `PRAGMA table_info` assertion in `tests/unit/db.test.ts`.
- Secrets never in remote command lines: service-role key travels via stdin only. Anon key and email are non-secret (anon key ships to browsers).
- Orchestrator whoami contract (existing, do not change): `GET http://127.0.0.1:9123/v1/whoami` with header `X-Auth-User-Id: <uid>` → `{userId, tier, label, tags, governanceView, reachableAgentIds}`.
- Supabase `user_roles` column is **`tier`** (not `role`); valid values include `platform_operator` (migration `supabase/ollie-core/0003_user_roles.sql`).
- Commit after every task; conventional-commit style messages as used in each repo's log.

---

## Repo: ollie-hermes-install

### Task 1: Extract agent/port detection into `scripts/lib/detect-agents.sh`

`06-install-stack.sh` lines 62–93 already detect every agent's gateway/dashboard port. Extract it into a sourceable lib so Task 2/7 can reuse it, and refactor 06 to consume it.

**Files:**
- Create: `scripts/lib/detect-agents.sh`
- Create: `tests/test-detect-agents.sh`
- Modify: `scripts/06-install-stack.sh:62-93`

**Interfaces:**
- Produces: sourceable function `detect_agents` — prints a single-line JSON array `[{"id":"default","gw":8642,"dash":9119},...]` to stdout. Env overrides: `HERMES_ENV_FILE` (default `$HOME/.hermes/.env`), `PROFILES_DIR` (default `$HOME/.hermes/profiles`), `SYSTEMD_USER_DIR` (default `$HOME/.config/systemd/user`).

- [ ] **Step 1: Write the failing test**

Create `tests/test-detect-agents.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/assert.sh"

setup_fixture() {
  local d; d="$(mktemp -d)"
  printf 'API_SERVER_PORT=8642\nAPI_SERVER_KEY=k\n' > "$d/hermes.env"
  mkdir -p "$d/profiles/marketing-agent" "$d/units"
  printf 'API_SERVER_PORT=8643\n' > "$d/profiles/marketing-agent/.env"
  printf '[Service]\nExecStart=%%h/.local/bin/hermes -p marketing-agent dashboard --host 127.0.0.1 --port 9121 --no-open\n' \
    > "$d/units/hermes-dashboard-marketing-agent.service"
  # profile with missing unit → must be skipped
  mkdir -p "$d/profiles/broken"
  printf 'API_SERVER_PORT=8650\n' > "$d/profiles/broken/.env"
  echo "$d"
}

test_detects_default_and_profile() {
  local d out; d="$(setup_fixture)"
  out="$(HERMES_ENV_FILE="$d/hermes.env" PROFILES_DIR="$d/profiles" SYSTEMD_USER_DIR="$d/units" \
    bash -c ". '$HERE/../scripts/lib/detect-agents.sh' && detect_agents" 2>/dev/null)"
  assert_eq "detected JSON" "$out" '[{"id":"default","gw":8642,"dash":9119},{"id":"marketing-agent","gw":8643,"dash":9121}]'
}

test_idempotent() {
  local d a b; d="$(setup_fixture)"
  a="$(HERMES_ENV_FILE="$d/hermes.env" PROFILES_DIR="$d/profiles" SYSTEMD_USER_DIR="$d/units" \
    bash -c ". '$HERE/../scripts/lib/detect-agents.sh' && detect_agents" 2>/dev/null)"
  b="$(HERMES_ENV_FILE="$d/hermes.env" PROFILES_DIR="$d/profiles" SYSTEMD_USER_DIR="$d/units" \
    bash -c ". '$HERE/../scripts/lib/detect-agents.sh' && detect_agents" 2>/dev/null)"
  assert_eq "two runs identical" "$a" "$b"
}

test_detects_default_and_profile
test_idempotent
finish
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-detect-agents.sh`
Expected: FAIL (`detect-agents.sh: No such file or directory`)

- [ ] **Step 3: Write the lib**

Create `scripts/lib/detect-agents.sh` (logic lifted verbatim from `06-install-stack.sh:62-93`, roots parameterized):

```bash
#!/usr/bin/env bash
# detect-agents.sh — enumerate installed agents and their ports as JSON.
# Source this file, then call detect_agents. Output (stdout, one line):
#   [{"id":"default","gw":<port>,"dash":9119},{"id":"<profile>","gw":<port>,"dash":<port>},...]
# Skips profiles with missing port info (warning on stderr) — same rule as 06.
set -uo pipefail

detect_agents() {
  local hermes_env="${HERMES_ENV_FILE:-$HOME/.hermes/.env}"
  local profiles_dir="${PROFILES_DIR:-$HOME/.hermes/profiles}"
  local unit_dir="${SYSTEMD_USER_DIR:-$HOME/.config/systemd/user}"
  local default_dash=9119
  local default_port prof_env prof_name gw_port unit dash_port
  local entries=()

  default_port="$(grep '^API_SERVER_PORT=' "${hermes_env}" | cut -d= -f2-)"
  entries+=("$(printf '{"id":"default","gw":%s,"dash":%s}' "${default_port}" "${default_dash}")")

  shopt -s nullglob
  for prof_env in "${profiles_dir}"/*/.env; do
    [[ -f "${prof_env}" ]] || continue
    prof_name="$(basename "$(dirname "${prof_env}")")"
    gw_port="$(grep '^API_SERVER_PORT=' "${prof_env}" | cut -d= -f2- || true)"
    unit="${unit_dir}/hermes-dashboard-${prof_name}.service"
    if [[ -f "${unit}" ]]; then
      dash_port="$(grep -oE -- '--port [0-9]+' "${unit}" | awk '{print $2}' | head -1)"
    else
      dash_port=""
    fi
    if [[ -z "${gw_port}" || -z "${dash_port}" ]]; then
      echo "    skipping profile '${prof_name}' (missing port info)" >&2
      continue
    fi
    entries+=("$(printf '{"id":"%s","gw":%s,"dash":%s}' "${prof_name}" "${gw_port}" "${dash_port}")")
  done
  (IFS=,; printf '[%s]' "${entries[*]}")
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-detect-agents.sh`
Expected: `2/2 passed`

- [ ] **Step 5: Refactor 06 to use the lib**

In `scripts/06-install-stack.sh`, replace the detection block (lines 62–93, from `DEFAULT_PORT="$(grep ...` through `DETECTED="[$(IFS=,; echo "${det_entries[*]}")]"`) with:

```bash
. "${SCRIPT_DIR}/lib/detect-agents.sh"
DETECTED="$(HERMES_ENV_FILE="${HERMES_ENV}" detect_agents)"
```

(06 already defines `SCRIPT_DIR` and `HERMES_ENV`; `PROFILES_DIR`/`SYSTEMD_USER_DIR` fall back to the real paths.)

- [ ] **Step 6: Verify 06 still parses and existing tests pass**

Run: `bash -n scripts/06-install-stack.sh && bash tests/test-detect-agents.sh && bash tests/test-merge-agents.sh && bash tests/test-stack-env.sh`
Expected: all pass, no syntax errors

- [ ] **Step 7: Commit**

```bash
git add scripts/lib/detect-agents.sh tests/test-detect-agents.sh scripts/06-install-stack.sh
git commit -m "refactor(lib): extract agent/port detection from 06 into detect-agents.sh"
```

### Task 2: P3 — `scripts/lib/render-proxy-maps.py` + wiring into 05

**Files:**
- Create: `scripts/lib/render-proxy-maps.py`
- Create: `tests/test-render-proxy-maps.sh`
- Modify: `scripts/05-install-orchestrator.sh` (insert new step between step 3 and step 4)

**Interfaces:**
- Consumes: `detect_agents` JSON (Task 1) on **stdin**.
- Produces: writes `HERMES_GATEWAY_URLS` and `HERMES_DASHBOARD_URLS` (single-line JSON objects, `{agentId: "http://127.0.0.1:<port>"}`) into the env file at `$ORCH_ENV` (default `$HOME/.config/ollie-orchestrator/.env`). Preserve rule: an existing value is kept ONLY if it is valid JSON whose key set includes every detected agent id; otherwise regenerated. Prints `gateway-urls: kept|written` / `dashboard-urls: kept|written`.

- [ ] **Step 1: Write the failing test**

Create `tests/test-render-proxy-maps.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/assert.sh"
RENDER="$HERE/../scripts/lib/render-proxy-maps.py"
DETECTED='[{"id":"default","gw":8642,"dash":9119},{"id":"marketing-agent","gw":8643,"dash":9121}]'

test_fresh_render() {
  local env; env="$(mktemp)"
  printf 'ORCHESTRATOR_KEY=x\n' > "$env"
  printf '%s' "$DETECTED" | ORCH_ENV="$env" python3 "$RENDER" >/dev/null
  assert_eq "gateway map" \
    "$(grep '^HERMES_GATEWAY_URLS=' "$env" | cut -d= -f2-)" \
    '{"default": "http://127.0.0.1:8642", "marketing-agent": "http://127.0.0.1:8643"}'
  assert_eq "dashboard map" \
    "$(grep '^HERMES_DASHBOARD_URLS=' "$env" | cut -d= -f2-)" \
    '{"default": "http://127.0.0.1:9119", "marketing-agent": "http://127.0.0.1:9121"}'
  assert_count "no duplicate gateway key" "$env" HERMES_GATEWAY_URLS 1
  assert_eq "other keys intact" "$(grep -c '^ORCHESTRATOR_KEY=x$' "$env")" "1"
}

test_covering_custom_value_kept() {
  local env; env="$(mktemp)"
  printf 'HERMES_GATEWAY_URLS={"default": "http://127.0.0.1:8642", "marketing-agent": "http://127.0.0.1:8643", "extra": "http://127.0.0.1:9999"}\n' > "$env"
  local before; before="$(grep '^HERMES_GATEWAY_URLS=' "$env")"
  printf '%s' "$DETECTED" | ORCH_ENV="$env" python3 "$RENDER" >/dev/null
  assert_eq "superset value kept byte-identical" "$(grep '^HERMES_GATEWAY_URLS=' "$env")" "$before"
}

test_stale_partial_map_regenerated() {
  local env; env="$(mktemp)"
  printf 'HERMES_GATEWAY_URLS={"default": "http://127.0.0.1:8642"}\n' > "$env"
  printf '%s' "$DETECTED" | ORCH_ENV="$env" python3 "$RENDER" >/dev/null
  assert_eq "stale map regenerated" \
    "$(grep '^HERMES_GATEWAY_URLS=' "$env" | cut -d= -f2-)" \
    '{"default": "http://127.0.0.1:8642", "marketing-agent": "http://127.0.0.1:8643"}'
}

test_idempotent() {
  local env; env="$(mktemp)"
  printf '%s' "$DETECTED" | ORCH_ENV="$env" python3 "$RENDER" >/dev/null
  local a; a="$(cat "$env")"
  printf '%s' "$DETECTED" | ORCH_ENV="$env" python3 "$RENDER" >/dev/null
  assert_eq "second run zero drift" "$(cat "$env")" "$a"
}

test_fresh_render
test_covering_custom_value_kept
test_stale_partial_map_regenerated
test_idempotent
finish
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-render-proxy-maps.sh`
Expected: FAIL (file not found)

- [ ] **Step 3: Write the renderer**

Create `scripts/lib/render-proxy-maps.py`:

```python
#!/usr/bin/env python3
"""render-proxy-maps.py — write HERMES_GATEWAY_URLS / HERMES_DASHBOARD_URLS
into the orchestrator .env from the detect-agents JSON on stdin.

An existing value is kept only if it is valid JSON covering every detected
agent id (operators may add extra entries); a stale/partial/invalid value is
regenerated — a partial map is exactly the chat-503 failure mode.
"""
import json, os, sys, tempfile

ORCH_ENV = os.environ.get("ORCH_ENV", os.path.expanduser("~/.config/ollie-orchestrator/.env"))


def read_lines(path):
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as f:
        return f.read().splitlines()


def current_value(lines, key):
    val = None
    for line in lines:
        if line.startswith(key + "="):
            val = line[len(key) + 1:]
    return val


def set_key(lines, key, value):
    out, replaced = [], False
    for line in lines:
        if line.startswith(key + "="):
            if not replaced:
                out.append(f"{key}={value}")
                replaced = True
            # drop duplicate occurrences
        else:
            out.append(line)
    if not replaced:
        out.append(f"{key}={value}")
    return out


def covers(existing, ids):
    try:
        parsed = json.loads(existing)
    except (TypeError, ValueError):
        return False
    return isinstance(parsed, dict) and set(ids) <= set(parsed.keys())


def main():
    agents = json.loads(sys.stdin.read())
    ids = [a["id"] for a in agents]
    maps = {
        "HERMES_GATEWAY_URLS": json.dumps({a["id"]: f"http://127.0.0.1:{a['gw']}" for a in agents}),
        "HERMES_DASHBOARD_URLS": json.dumps({a["id"]: f"http://127.0.0.1:{a['dash']}" for a in agents}),
    }
    lines = read_lines(ORCH_ENV)
    for key, rendered in maps.items():
        label = "gateway-urls" if "GATEWAY" in key else "dashboard-urls"
        if covers(current_value(lines, key), ids):
            print(f"{label}: kept")
            continue
        lines = set_key(lines, key, rendered)
        print(f"{label}: written")
    os.makedirs(os.path.dirname(ORCH_ENV), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(ORCH_ENV))
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    os.replace(tmp, ORCH_ENV)


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-render-proxy-maps.sh`
Expected: `4/4 passed` — if the "second run zero drift" test fails on trailing newlines, fix the writer, not the test.

- [ ] **Step 5: Wire into 05**

In `scripts/05-install-orchestrator.sh`, insert after step 3 (after line 60, the `HERMES_GATEWAY_KEY` write) and before `echo "==> step 4: restart orchestrator + verify"`:

```bash
echo "==> step 3b: render agent proxy maps into orchestrator .env"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/lib/detect-agents.sh"
detect_agents | python3 "${SCRIPT_DIR}/lib/render-proxy-maps.py"
```

(05 has no `SCRIPT_DIR` today — define it as shown; keep the definition near the top with the other vars if cleaner.)

- [ ] **Step 6: Verify + commit**

Run: `bash -n scripts/05-install-orchestrator.sh && bash tests/test-render-proxy-maps.sh`
Expected: pass

```bash
git add scripts/lib/render-proxy-maps.py tests/test-render-proxy-maps.sh scripts/05-install-orchestrator.sh
git commit -m "feat(orchestrator-install): P3 — render HERMES_GATEWAY_URLS/DASHBOARD_URLS from installed profiles"
```

### Task 3: P4 — `scripts/lib/ensure-dashboard-token.sh` + wiring into 05

**Files:**
- Create: `scripts/lib/ensure-dashboard-token.sh`
- Create: `tests/test-ensure-dashboard-token.sh`
- Modify: `scripts/05-install-orchestrator.sh` (extend step 3b block from Task 2)

**Interfaces:**
- Consumes: nothing from other tasks (standalone).
- Produces: `HERMES_DASHBOARD_TOKEN=<urlsafe token>` in `$ORCH_ENV`; for every `hermes-dashboard*.service` in `$SYSTEMD_USER_DIR`, a drop-in `<unit>.d/session-token.conf` (mode 600) containing `[Service]` + `Environment=HERMES_DASHBOARD_SESSION_TOKEN=<same token>`. Env overrides: `ORCH_ENV`, `SYSTEMD_USER_DIR`, `ENSURE_TOKEN_NO_RESTART=1` (skip daemon-reload/restarts — tests and callers that restart later).

- [ ] **Step 1: Write the failing test**

Create `tests/test-ensure-dashboard-token.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/assert.sh"
ENSURE="$HERE/../scripts/lib/ensure-dashboard-token.sh"

setup_dir() {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/units"
  printf '[Service]\nExecStart=hermes dashboard --host 127.0.0.1 --port 9119\n' > "$d/units/hermes-dashboard.service"
  printf '[Service]\nExecStart=hermes -p m dashboard --host 127.0.0.1 --port 9121\n' > "$d/units/hermes-dashboard-m.service"
  printf '[Service]\nExecStart=hermes gateway\n' > "$d/units/hermes-gateway.service"
  echo "$d"
}

test_generates_and_drops_in() {
  local d; d="$(setup_dir)"
  ORCH_ENV="$d/orch.env" SYSTEMD_USER_DIR="$d/units" ENSURE_TOKEN_NO_RESTART=1 bash "$ENSURE" >/dev/null
  local tok; tok="$(grep '^HERMES_DASHBOARD_TOKEN=' "$d/orch.env" | cut -d= -f2-)"
  assert_eq "token nonempty (len>=32)" "$([[ ${#tok} -ge 32 ]] && echo yes)" "yes"
  assert_eq "drop-in default" "$(cat "$d/units/hermes-dashboard.service.d/session-token.conf")" \
    "$(printf '[Service]\nEnvironment=HERMES_DASHBOARD_SESSION_TOKEN=%s' "$tok")"
  assert_eq "drop-in profile" "$(cat "$d/units/hermes-dashboard-m.service.d/session-token.conf")" \
    "$(printf '[Service]\nEnvironment=HERMES_DASHBOARD_SESSION_TOKEN=%s' "$tok")"
  assert_eq "gateway untouched" "$([[ -d "$d/units/hermes-gateway.service.d" ]] && echo yes || echo no)" "no"
  assert_eq "drop-in mode 600" "$(stat -c %a "$d/units/hermes-dashboard.service.d/session-token.conf")" "600"
}

test_reuses_existing_token_and_is_idempotent() {
  local d; d="$(setup_dir)"
  printf 'HERMES_DASHBOARD_TOKEN=stable-token-value-0123456789abcdef\n' > "$d/orch.env"
  ORCH_ENV="$d/orch.env" SYSTEMD_USER_DIR="$d/units" ENSURE_TOKEN_NO_RESTART=1 bash "$ENSURE" >/dev/null
  local a; a="$(cat "$d/orch.env" "$d/units/hermes-dashboard.service.d/session-token.conf")"
  ORCH_ENV="$d/orch.env" SYSTEMD_USER_DIR="$d/units" ENSURE_TOKEN_NO_RESTART=1 bash "$ENSURE" >/dev/null
  assert_eq "reused + zero drift" "$(cat "$d/orch.env" "$d/units/hermes-dashboard.service.d/session-token.conf")" "$a"
  assert_eq "existing value kept" "$(grep -c 'stable-token-value' "$d/orch.env")" "1"
}

test_generates_and_drops_in
test_reuses_existing_token_and_is_idempotent
finish
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-ensure-dashboard-token.sh`
Expected: FAIL (file not found)

- [ ] **Step 3: Write the lib**

Create `scripts/lib/ensure-dashboard-token.sh`:

```bash
#!/usr/bin/env bash
# ensure-dashboard-token.sh — stable dashboard session token, everywhere it must match.
# Reuses HERMES_DASHBOARD_TOKEN from the orchestrator .env if present, else generates
# one. Writes it to the orchestrator .env AND as a session-token.conf drop-in for every
# hermes-dashboard*.service unit. Without the matching drop-in the dashboard randomizes
# its session token each restart and every management call 401s (S75 incident).
# Env: ORCH_ENV, SYSTEMD_USER_DIR, ENSURE_TOKEN_NO_RESTART=1 (skip systemctl).
set -uo pipefail

ORCH_ENV="${ORCH_ENV:-$HOME/.config/ollie-orchestrator/.env}"
UNIT_DIR="${SYSTEMD_USER_DIR:-$HOME/.config/systemd/user}"

mkdir -p "$(dirname "${ORCH_ENV}")"
touch "${ORCH_ENV}"

TOKEN="$(grep '^HERMES_DASHBOARD_TOKEN=' "${ORCH_ENV}" | tail -1 | cut -d= -f2- || true)"
if [[ -z "${TOKEN}" ]]; then
  TOKEN="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
  echo "HERMES_DASHBOARD_TOKEN=${TOKEN}" >> "${ORCH_ENV}"
  echo "dashboard-token: generated"
else
  echo "dashboard-token: reused"
fi

changed_units=()
shopt -s nullglob
for unit in "${UNIT_DIR}"/hermes-dashboard*.service; do
  unit_name="$(basename "${unit}")"
  dropdir="${UNIT_DIR}/${unit_name}.d"
  conf="${dropdir}/session-token.conf"
  want="$(printf '[Service]\nEnvironment=HERMES_DASHBOARD_SESSION_TOKEN=%s' "${TOKEN}")"
  if [[ -f "${conf}" && "$(cat "${conf}")" == "${want}" ]]; then
    continue
  fi
  mkdir -p "${dropdir}"
  printf '%s' "${want}" > "${conf}"
  chmod 600 "${conf}"
  changed_units+=("${unit_name}")
  echo "drop-in written: ${unit_name}"
done

if [[ "${ENSURE_TOKEN_NO_RESTART:-0}" == "1" ]]; then
  exit 0
fi
if [[ ${#changed_units[@]} -gt 0 ]]; then
  systemctl --user daemon-reload
  for u in "${changed_units[@]}"; do
    systemctl --user restart "${u}" || echo "warning: restart ${u} failed" >&2
  done
fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-ensure-dashboard-token.sh`
Expected: `2/2 passed`

- [ ] **Step 5: Wire into 05 + commit**

Extend the Task-2 block in `scripts/05-install-orchestrator.sh`:

```bash
echo "==> step 3c: ensure stable dashboard session token + drop-ins"
ENSURE_TOKEN_NO_RESTART=1 bash "${SCRIPT_DIR}/lib/ensure-dashboard-token.sh"
systemctl --user daemon-reload
for u in "${HOME}/.config/systemd/user"/hermes-dashboard*.service; do
  [[ -f "$u" ]] && systemctl --user restart "$(basename "$u")" || true
done
```

(05 restarts dashboards itself after daemon-reload; `ENSURE_TOKEN_NO_RESTART=1` avoids a double restart. Note dashboards recompile their SPA on restart — 20-40s to rebind; that's known-normal.)

Run: `bash -n scripts/05-install-orchestrator.sh && bash tests/test-ensure-dashboard-token.sh`

```bash
git add scripts/lib/ensure-dashboard-token.sh tests/test-ensure-dashboard-token.sh scripts/05-install-orchestrator.sh
git commit -m "feat(orchestrator-install): P4 — stable dashboard session token + per-unit drop-ins"
```

### Task 4: Re-render maps + drop-ins when a profile is added (03 hook)

**Files:**
- Modify: `scripts/03-install-profile.sh` (after line 171, `systemctl --user enable --now hermes-dashboard-${NAME}`, before the verification block at line 173)

**Interfaces:**
- Consumes: `detect_agents` (Task 1), `render-proxy-maps.py` (Task 2), `ensure-dashboard-token.sh` (Task 3) — exact invocations below.

- [ ] **Step 1: Add the hook**

Insert into `scripts/03-install-profile.sh` after the `enable --now` line:

```bash
echo "==> step 6b: refresh orchestrator proxy maps + dashboard token for the new agent"
. "${SCRIPT_DIR}/lib/detect-agents.sh"
detect_agents | python3 "${SCRIPT_DIR}/lib/render-proxy-maps.py"
bash "${SCRIPT_DIR}/lib/ensure-dashboard-token.sh"
if systemctl --user is-active --quiet ollie-orchestrator; then
  systemctl --user restart ollie-orchestrator
fi
```

(03 defines `SCRIPT_DIR` already — verify; if not, add the standard `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` near the top. The orchestrator restart picks up the new maps; skipped when the orchestrator isn't installed yet — 03 can legitimately run before 05 on a fresh manual install.)

- [ ] **Step 2: Verify + commit**

Run: `bash -n scripts/03-install-profile.sh && bash tests/test-detect-agents.sh && bash tests/test-render-proxy-maps.sh && bash tests/test-ensure-dashboard-token.sh`
Expected: pass

```bash
git add scripts/03-install-profile.sh
git commit -m "feat(profile-install): re-render proxy maps + token drop-ins after adding a profile"
```

### Task 5: S1 — `scripts/11-install-supabase.sh`

**Files:**
- Create: `scripts/11-install-supabase.sh`
- Create: `scripts/lib/supabase-env.sh` (the testable core)
- Create: `tests/test-supabase-env.sh`

**Interfaces:**
- Consumes: stdin `KEY=VALUE` lines (from Fleet or a human): `SUPABASE_URL=...`, `SUPABASE_SERVICE_ROLE_KEY=...`. Flag `--verify-only`: no stdin; reads existing keys from `$ORCH_ENV`, exits 0 with `SKIP` if absent (safe on update paths for boxes without Supabase).
- Produces (lib `supabase-env.sh`): `supabase_validate_inputs URL KEY` (exit 1 + message on empty/malformed/multiline); `supabase_write_orch_env URL KEY` (insert-or-replace both keys in `$ORCH_ENV`, chmod 600); `supabase_schema_probe_url URL` (prints `<url>/rest/v1/user_roles?select=user_id&limit=1`).
- Produces (script): env applied + schema verified + orchestrator restarted + healthz confirmed, or non-zero exit with an actionable message.

- [ ] **Step 1: Write the failing test**

Create `tests/test-supabase-env.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/assert.sh"
. "$HERE/../scripts/lib/supabase-env.sh"

test_validate_rejects_partial_and_malformed() {
  local rc
  (supabase_validate_inputs "" "key") >/dev/null 2>&1; rc=$?
  assert_eq "empty url rejected" "$rc" "1"
  (supabase_validate_inputs "https://abc.supabase.co" "") >/dev/null 2>&1; rc=$?
  assert_eq "empty key rejected" "$rc" "1"
  (supabase_validate_inputs "http://abc.supabase.co" "k") >/dev/null 2>&1; rc=$?
  assert_eq "non-https rejected" "$rc" "1"
  (supabase_validate_inputs "https://supabase.internal.lan:8443" "k") >/dev/null 2>&1; rc=$?
  assert_eq "self-hosted https origin accepted" "$rc" "0"
  (supabase_validate_inputs "https://abc.supabase.co/extra/path" "k") >/dev/null 2>&1; rc=$?
  assert_eq "url with path rejected" "$rc" "1"
  (supabase_validate_inputs "https://abc.supabase.co" "$(printf 'a\nb')") >/dev/null 2>&1; rc=$?
  assert_eq "multiline key rejected" "$rc" "1"
  (supabase_validate_inputs "https://abc.supabase.co" "sk-ok") >/dev/null 2>&1; rc=$?
  assert_eq "valid pair accepted" "$rc" "0"
}

test_write_orch_env_idempotent_and_600() {
  local d; d="$(mktemp -d)"
  export ORCH_ENV="$d/orch.env"
  printf 'ORCHESTRATOR_KEY=x\n' > "$ORCH_ENV"
  supabase_write_orch_env "https://abc.supabase.co" "svc-key-1"
  assert_count "one URL line" "$ORCH_ENV" SUPABASE_URL 1
  assert_count "one key line" "$ORCH_ENV" SUPABASE_SERVICE_ROLE_KEY 1
  assert_eq "mode 600" "$(stat -c %a "$ORCH_ENV")" "600"
  local a; a="$(cat "$ORCH_ENV")"
  supabase_write_orch_env "https://abc.supabase.co" "svc-key-1"
  assert_eq "re-run zero drift" "$(cat "$ORCH_ENV")" "$a"
  supabase_write_orch_env "https://abc.supabase.co" "svc-key-2"
  assert_eq "replace on new creds" "$(grep '^SUPABASE_SERVICE_ROLE_KEY=' "$ORCH_ENV" | cut -d= -f2-)" "svc-key-2"
  assert_count "still one key line" "$ORCH_ENV" SUPABASE_SERVICE_ROLE_KEY 1
  unset ORCH_ENV
}

test_probe_url() {
  assert_eq "probe url" "$(supabase_schema_probe_url "https://abc.supabase.co")" \
    "https://abc.supabase.co/rest/v1/user_roles?select=user_id&limit=1"
}

test_validate_rejects_partial_and_malformed
test_write_orch_env_idempotent_and_600
test_probe_url
finish
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-supabase-env.sh`
Expected: FAIL (lib not found)

- [ ] **Step 3: Write the lib**

Create `scripts/lib/supabase-env.sh`:

```bash
#!/usr/bin/env bash
# supabase-env.sh — testable core for 11-install-supabase.sh. Source, don't exec.
set -uo pipefail

supabase_validate_inputs() {
  local url="$1" key="$2"
  if [[ -z "${url}" || -z "${key}" ]]; then
    echo "error: SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are both required" >&2; return 1
  fi
  if [[ ! "${url}" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?/?$ ]]; then
    echo "error: SUPABASE_URL must be an https origin with no path — hosted (https://<ref>.supabase.co) or self-hosted (got: ${url})" >&2; return 1
  fi
  if [[ "${key}" == *$'\n'* || "${key}" == *" "* ]]; then
    echo "error: SUPABASE_SERVICE_ROLE_KEY must be a single-line value" >&2; return 1
  fi
  return 0
}

_supabase_set_env_key() {
  local file="$1" k="$2" v="$3"
  if grep -q "^${k}=" "${file}" 2>/dev/null; then
    sed -i "s|^${k}=.*|${k}=${v}|" "${file}"
  else
    echo "${k}=${v}" >> "${file}"
  fi
}

supabase_write_orch_env() {
  local url="${1%/}" key="$2"
  local env_file="${ORCH_ENV:-$HOME/.config/ollie-orchestrator/.env}"
  mkdir -p "$(dirname "${env_file}")"
  touch "${env_file}"
  _supabase_set_env_key "${env_file}" SUPABASE_URL "${url}"
  _supabase_set_env_key "${env_file}" SUPABASE_SERVICE_ROLE_KEY "${key}"
  chmod 600 "${env_file}"
}

supabase_schema_probe_url() {
  printf '%s/rest/v1/user_roles?select=user_id&limit=1' "${1%/}"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-supabase-env.sh`
Expected: `3/3 passed`

- [ ] **Step 5: Write the script**

Create `scripts/11-install-supabase.sh`:

```bash
#!/usr/bin/env bash
# 11-install-supabase.sh — apply per-instance Supabase config to the orchestrator
# and verify the project is provision-ready.
#
# Run as: the service user (ollie by default)
# Idempotent: safe to re-run; same creds = no-op apart from the restart.
#
# Input (stdin, KEY=VALUE lines — stdin so the secret never appears in argv):
#   SUPABASE_URL=https://<ref>.supabase.co
#   SUPABASE_SERVICE_ROLE_KEY=<service role key>
# Or: --verify-only  (no stdin; verify existing config, SKIP cleanly if none)
#
# The project must already be provision-ready per
# docs/runbooks/supabase-ollie-core-provisioning.md (runbook SQL + JWT hook +
# Google provider). PostgREST cannot run DDL, so this script VERIFIES the
# schema — it does not create it.
set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  echo "error: run as the service user, not root" >&2
  exit 1
fi
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/lib/supabase-env.sh"
ORCH_ENV="${ORCH_ENV:-$HOME/.config/ollie-orchestrator/.env}"

MODE="apply"
[[ "${1:-}" == "--verify-only" ]] && MODE="verify"

if [[ "${MODE}" == "apply" ]]; then
  SUPABASE_URL="" ; SUPABASE_SERVICE_ROLE_KEY=""
  while IFS='=' read -r k v; do
    case "${k}" in
      SUPABASE_URL) SUPABASE_URL="${v}" ;;
      SUPABASE_SERVICE_ROLE_KEY) SUPABASE_SERVICE_ROLE_KEY="${v}" ;;
    esac
  done
  supabase_validate_inputs "${SUPABASE_URL}" "${SUPABASE_SERVICE_ROLE_KEY}"
else
  SUPABASE_URL="$(grep '^SUPABASE_URL=' "${ORCH_ENV}" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
  SUPABASE_SERVICE_ROLE_KEY="$(grep '^SUPABASE_SERVICE_ROLE_KEY=' "${ORCH_ENV}" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
  if [[ -z "${SUPABASE_URL}" || -z "${SUPABASE_SERVICE_ROLE_KEY}" ]]; then
    echo "SKIP: no Supabase config on this box (nothing to verify)"
    exit 0
  fi
fi

echo "==> step 1: verify the Supabase project is provision-ready"
PROBE_URL="$(supabase_schema_probe_url "${SUPABASE_URL}")"
CODE="$(curl -s -o /dev/null -w '%{http_code}' -m 15 \
  -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
  "${PROBE_URL}" || echo "000")"
if [[ "${CODE}" != "200" ]]; then
  echo "error: schema probe returned HTTP ${CODE} — the project is not provision-ready." >&2
  echo "       Run the runbook first: docs/runbooks/supabase-ollie-core-provisioning.md" >&2
  echo "       (SQL Editor: supabase/ollie-core/0001..0006 in order, then register the" >&2
  echo "        custom_access_token_hook and enable the Google provider.)" >&2
  exit 1
fi
echo "    schema probe → 200 ✓"

if [[ "${MODE}" == "apply" ]]; then
  echo "==> step 2: write SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY to orchestrator .env"
  supabase_write_orch_env "${SUPABASE_URL}" "${SUPABASE_SERVICE_ROLE_KEY}"
fi

echo "==> step 3: restart orchestrator + verify"
systemctl --user restart ollie-orchestrator
set +e
for i in $(seq 1 10); do
  HEALTH=$(curl -s -m 5 http://localhost:9123/healthz || echo "")
  [[ "${HEALTH}" == *'"status":"ok"'* ]] && break
  sleep 2
done
set -e
if [[ "${HEALTH:-}" != *'"status":"ok"'* ]]; then
  echo "error: orchestrator did not come back healthy after restart" >&2
  exit 1
fi
echo
echo "✓ Supabase config applied + verified (orchestrator healthy)."
```

- [ ] **Step 6: Verify + commit**

Run: `bash -n scripts/11-install-supabase.sh && bash tests/test-supabase-env.sh`
Expected: pass

```bash
git add scripts/11-install-supabase.sh scripts/lib/supabase-env.sh tests/test-supabase-env.sh
git commit -m "feat(install): S1 — 11-install-supabase.sh applies orchestrator Supabase config + verifies provision-ready schema"
```

### Task 6: P6 helper — `scripts/lib/seed-operator-role.py`

**Files:**
- Create: `scripts/lib/seed-operator-role.py`
- Create: `tests/test_seed_operator_role.py` (pytest, mirrors `test_fleetctl.py` loader style)

**Interfaces:**
- Consumes: `$ORCH_ENV` containing `SUPABASE_URL` + `SUPABASE_SERVICE_ROLE_KEY` (Task 5 must have run).
- Produces: CLI `python3 seed-operator-role.py --email <email> --instance-id <id> [--print-uid]`. Resolves the Supabase auth user by email (case-insensitive) via `GET {url}/auth/v1/admin/users?per_page=200` (paginate until empty page, max 10 pages); creates the user via `POST {url}/auth/v1/admin/users` with `{"email": ..., "email_confirm": true}` if absent; upserts `POST {url}/rest/v1/user_roles` body `[{"instance_id","user_id","tier":"platform_operator"}]` with `Prefer: resolution=merge-duplicates`. `--print-uid` prints the resolved uid and skips the upsert (used by the gate). Exit 1 with message if orchestrator env lacks Supabase keys. Pure helpers exposed for tests: `find_user(users, email)`, `build_role_payload(instance_id, user_id)`, `load_supabase_env(path)`.

- [ ] **Step 1: Write the failing test**

Create `tests/test_seed_operator_role.py`:

```python
import os, tempfile, unittest
from importlib.machinery import SourceFileLoader

HERE = os.path.dirname(os.path.abspath(__file__))
SEED_PATH = os.path.join(HERE, "..", "scripts", "lib", "seed-operator-role.py")


def load_mod():
    return SourceFileLoader("seed_operator_role", SEED_PATH).load_module()


class TestHelpers(unittest.TestCase):
    def test_find_user_case_insensitive(self):
        m = load_mod()
        users = [{"id": "u1", "email": "JB@Example.com"}, {"id": "u2", "email": "x@y.z"}]
        self.assertEqual(m.find_user(users, "jb@example.com"), "u1")
        self.assertIsNone(m.find_user(users, "absent@example.com"))

    def test_build_role_payload(self):
        m = load_mod()
        self.assertEqual(
            m.build_role_payload("inst-1", "u1"),
            [{"instance_id": "inst-1", "user_id": "u1", "tier": "platform_operator"}],
        )

    def test_load_supabase_env(self):
        m = load_mod()
        with tempfile.NamedTemporaryFile("w", suffix=".env", delete=False) as f:
            f.write("OTHER=x\nSUPABASE_URL=https://abc.supabase.co\nSUPABASE_SERVICE_ROLE_KEY=sk\n")
        url, key = m.load_supabase_env(f.name)
        self.assertEqual(url, "https://abc.supabase.co")
        self.assertEqual(key, "sk")

    def test_load_supabase_env_missing_raises(self):
        m = load_mod()
        with tempfile.NamedTemporaryFile("w", suffix=".env", delete=False) as f:
            f.write("OTHER=x\n")
        with self.assertRaises(SystemExit):
            m.load_supabase_env(f.name)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest tests/test_seed_operator_role.py -v`
Expected: FAIL (file not found)

- [ ] **Step 3: Write the helper**

Create `scripts/lib/seed-operator-role.py`:

```python
#!/usr/bin/env python3
"""seed-operator-role.py — resolve-or-create the operator's Supabase auth user
by email and upsert their platform_operator row for this instance.

Fleet's user ids are Fleet-local, so identity is keyed on EMAIL. Creating the
auth user with email_confirm=true lets a later Google sign-in auto-link (the
proven sandbox pattern). Idempotent: merge-duplicates upsert.

Usage: seed-operator-role.py --email <email> --instance-id <id> [--print-uid]
Env:   ORCH_ENV (default ~/.config/ollie-orchestrator/.env)
"""
import argparse, json, os, sys, urllib.error, urllib.request

ORCH_ENV = os.environ.get("ORCH_ENV", os.path.expanduser("~/.config/ollie-orchestrator/.env"))


def load_supabase_env(path):
    url = key = ""
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                if line.startswith("SUPABASE_URL="):
                    url = line.split("=", 1)[1].strip().rstrip("/")
                elif line.startswith("SUPABASE_SERVICE_ROLE_KEY="):
                    key = line.split("=", 1)[1].strip()
    except FileNotFoundError:
        pass
    if not url or not key:
        sys.exit("error: SUPABASE_URL/SUPABASE_SERVICE_ROLE_KEY missing from %s — run 11-install-supabase.sh first" % path)
    return url, key


def find_user(users, email):
    want = email.strip().lower()
    for u in users:
        if (u.get("email") or "").strip().lower() == want:
            return u["id"]
    return None


def build_role_payload(instance_id, user_id):
    return [{"instance_id": instance_id, "user_id": user_id, "tier": "platform_operator"}]


def _req(url, key, method="GET", body=None, extra_headers=None):
    headers = {"apikey": key, "Authorization": "Bearer " + key, "Content-Type": "application/json"}
    headers.update(extra_headers or {})
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    with urllib.request.urlopen(req, timeout=15) as resp:
        raw = resp.read().decode() or "null"
        return resp.status, json.loads(raw)


def resolve_or_create_uid(base, key, email):
    for page in range(1, 11):
        status, data = _req(f"{base}/auth/v1/admin/users?page={page}&per_page=200", key)
        users = data.get("users", data if isinstance(data, list) else [])
        uid = find_user(users, email)
        if uid:
            return uid
        if not users:
            break
    _, created = _req(f"{base}/auth/v1/admin/users", key, method="POST",
                      body={"email": email, "email_confirm": True})
    return created["id"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--email", required=True)
    ap.add_argument("--instance-id", required=True)
    ap.add_argument("--print-uid", action="store_true")
    args = ap.parse_args()

    base, key = load_supabase_env(ORCH_ENV)
    try:
        uid = resolve_or_create_uid(base, key, args.email)
        if args.print_uid:
            print(uid)
            return
        _req(f"{base}/rest/v1/user_roles", key, method="POST",
             body=build_role_payload(args.instance_id, uid),
             extra_headers={"Prefer": "resolution=merge-duplicates"})
    except urllib.error.HTTPError as e:
        sys.exit(f"error: Supabase API {e.code} on {e.url}: {e.read().decode()[:400]}")
    print(f"seeded platform_operator for {args.email} (uid {uid}) @ instance {args.instance_id}")


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python -m pytest tests/test_seed_operator_role.py -v`
Expected: 4 passed

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/seed-operator-role.py tests/test_seed_operator_role.py
git commit -m "feat(install): P6 helper — seed-operator-role.py resolves-or-creates operator by email, upserts platform_operator"
```

### Task 7: P7 — `scripts/check-box-config.sh`

**Files:**
- Create: `scripts/check-box-config.sh`
- Create: `tests/test-check-box-config.sh`

**Interfaces:**
- Consumes: `detect_agents` (Task 1); `seed-operator-role.py --print-uid` (Task 6) for the whoami probe.
- Produces: report-only gate. Env: `OPERATOR_EMAIL` (required for the whoami probe), `ORCH_ENV`, `STACK_ENV_FILE` (default `$HOME/hermes-stack/.env`), `SYSTEMD_USER_DIR`, `HERMES_ENV_FILE`, `PROFILES_DIR`, `CHECK_SKIP_LIVE=1` (skip systemd/docker/HTTP checks — unit tests). Prints one `PASS:`/`FAIL:` line per check; exit 0 all-pass, exit 1 otherwise with `GAPS: <n>` summary.

- [ ] **Step 1: Write the failing test**

Create `tests/test-check-box-config.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/assert.sh"
GATE="$HERE/../scripts/check-box-config.sh"

setup_healthy() {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/units/hermes-dashboard.service.d" "$d/profiles"
  printf 'API_SERVER_PORT=8642\n' > "$d/hermes.env"
  printf '[Service]\nExecStart=hermes dashboard --host 127.0.0.1 --port 9119\n' > "$d/units/hermes-dashboard.service"
  cat > "$d/orch.env" <<'EOF'
INSTANCE_ID=inst-1
SUPABASE_URL=https://abc.supabase.co
SUPABASE_SERVICE_ROLE_KEY=sk
HERMES_DASHBOARD_TOKEN=tok123
HERMES_GATEWAY_URLS={"default": "http://127.0.0.1:8642"}
HERMES_DASHBOARD_URLS={"default": "http://127.0.0.1:9119"}
EOF
  printf '[Service]\nEnvironment=HERMES_DASHBOARD_SESSION_TOKEN=tok123' > "$d/units/hermes-dashboard.service.d/session-token.conf"
  printf 'SUPABASE_URL=https://abc.supabase.co\nSUPABASE_ANON_KEY=anon\n' > "$d/stack.env"
  echo "$d"
}

run_gate() {
  local d="$1"
  ORCH_ENV="$d/orch.env" STACK_ENV_FILE="$d/stack.env" SYSTEMD_USER_DIR="$d/units" \
    HERMES_ENV_FILE="$d/hermes.env" PROFILES_DIR="$d/profiles" \
    OPERATOR_EMAIL=jb@example.com CHECK_SKIP_LIVE=1 bash "$GATE"
}

test_healthy_box_passes() {
  local d rc; d="$(setup_healthy)"
  run_gate "$d" >/dev/null; rc=$?
  assert_eq "healthy exit 0" "$rc" "0"
}

test_each_gap_flagged() {
  local d rc out
  d="$(setup_healthy)"; sed -i '/^INSTANCE_ID=/d' "$d/orch.env"
  out="$(run_gate "$d")"; rc=$?
  assert_eq "missing INSTANCE_ID exit 1" "$rc" "1"
  assert_eq "INSTANCE_ID named" "$(echo "$out" | grep -c 'FAIL: INSTANCE_ID')" "1"

  d="$(setup_healthy)"; sed -i 's|^HERMES_GATEWAY_URLS=.*|HERMES_GATEWAY_URLS={}|' "$d/orch.env"
  out="$(run_gate "$d")"; rc=$?
  assert_eq "incomplete map exit 1" "$rc" "1"
  assert_eq "map gap named" "$(echo "$out" | grep -c 'FAIL: HERMES_GATEWAY_URLS')" "1"

  d="$(setup_healthy)"; printf 'wrong' > "$d/units/hermes-dashboard.service.d/session-token.conf"
  out="$(run_gate "$d")"; rc=$?
  assert_eq "token mismatch exit 1" "$rc" "1"
  assert_eq "drop-in gap named" "$(echo "$out" | grep -c 'FAIL: session-token')" "1"

  d="$(setup_healthy)"; sed -i 's|--host 127.0.0.1|--host 0.0.0.0|' "$d/units/hermes-dashboard.service"
  out="$(run_gate "$d")"; rc=$?
  assert_eq "0.0.0.0 unit exit 1" "$rc" "1"

  d="$(setup_healthy)"; sed -i '/^SUPABASE_ANON_KEY=/d' "$d/stack.env"
  out="$(run_gate "$d")"; rc=$?
  assert_eq "stack anon gap exit 1" "$rc" "1"
}

test_healthy_box_passes
test_each_gap_flagged
finish
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-check-box-config.sh`
Expected: FAIL (gate not found)

- [ ] **Step 3: Write the gate**

Create `scripts/check-box-config.sh`:

```bash
#!/usr/bin/env bash
# check-box-config.sh — "done done" parity gate. Report-only: prints PASS/FAIL
# per check, exit 0 when the box has the full healthy config set, exit 1 with
# GAPS: <n> otherwise. Never mutates anything.
#
# Run as: the service user.  Env: OPERATOR_EMAIL (required unless CHECK_SKIP_LIVE=1),
# CHECK_SKIP_LIVE=1 (config-file checks only), plus the usual overridable roots.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/lib/detect-agents.sh"

ORCH_ENV="${ORCH_ENV:-$HOME/.config/ollie-orchestrator/.env}"
STACK_ENV_FILE="${STACK_ENV_FILE:-$HOME/hermes-stack/.env}"
UNIT_DIR="${SYSTEMD_USER_DIR:-$HOME/.config/systemd/user}"
SKIP_LIVE="${CHECK_SKIP_LIVE:-0}"

gaps=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; gaps=$((gaps+1)); }

orch_val() { grep "^$1=" "${ORCH_ENV}" 2>/dev/null | tail -1 | cut -d= -f2-; }
stack_val() { grep "^$1=" "${STACK_ENV_FILE}" 2>/dev/null | tail -1 | cut -d= -f2-; }

# 1. orchestrator .env required keys
for k in INSTANCE_ID SUPABASE_URL SUPABASE_SERVICE_ROLE_KEY HERMES_DASHBOARD_TOKEN; do
  if [[ -n "$(orch_val "$k")" ]]; then pass "$k set"; else fail "$k missing/empty in orchestrator .env"; fi
done

# 2. proxy maps cover every detected agent
DETECTED="$(detect_agents 2>/dev/null || echo '[]')"
for k in HERMES_GATEWAY_URLS HERMES_DASHBOARD_URLS; do
  MAP="$(orch_val "$k")"
  if MISSING="$(DETECTED="${DETECTED}" MAP="${MAP}" python3 - <<'PY'
import json, os, sys
try:
    ids = {a["id"] for a in json.loads(os.environ["DETECTED"])}
    m = json.loads(os.environ["MAP"] or "null")
    missing = sorted(ids - set(m.keys())) if isinstance(m, dict) else sorted(ids)
except Exception:
    missing = ["<unparseable>"]
print(",".join(missing)); sys.exit(1 if missing else 0)
PY
)"; then pass "$k covers all agents"; else fail "$k incomplete (missing: ${MISSING})"; fi
done

# 3. session-token drop-in per dashboard unit, matching the orchestrator token
TOKEN="$(orch_val HERMES_DASHBOARD_TOKEN)"
shopt -s nullglob
for unit in "${UNIT_DIR}"/hermes-dashboard*.service; do
  name="$(basename "${unit}")"
  conf="${UNIT_DIR}/${name}.d/session-token.conf"
  if [[ -f "${conf}" ]] && grep -q "HERMES_DASHBOARD_SESSION_TOKEN=${TOKEN}$" "${conf}"; then
    pass "session-token drop-in matches (${name})"
  else
    fail "session-token drop-in missing/mismatched (${name})"
  fi
  if grep -qE '^ExecStart=.*--host 0\.0\.0\.0' "${unit}"; then
    fail "stale --host 0.0.0.0 in ${name}"
  else
    pass "loopback bind (${name})"
  fi
done

# 4. stack .env login-gate keys
for k in SUPABASE_URL SUPABASE_ANON_KEY; do
  if [[ -n "$(stack_val "$k")" ]]; then pass "stack ${k} set"; else fail "stack ${k} missing (login gate will render empty)"; fi
done

# 5. live checks
if [[ "${SKIP_LIVE}" != "1" ]]; then
  for u in ollie-orchestrator hermes-gateway hermes-dashboard; do
    if systemctl --user is-active --quiet "${u}"; then pass "${u} active"; else fail "${u} not active"; fi
  done
  for c in cortex ollie-dashboard; do
    if docker ps --format '{{.Names}}' | grep -qx "${c}"; then pass "container ${c} running"; else fail "container ${c} not running"; fi
  done
  if [[ -z "${OPERATOR_EMAIL:-}" ]]; then
    fail "OPERATOR_EMAIL not provided — cannot run whoami probe"
  else
    UID_OUT="$(python3 "${SCRIPT_DIR}/lib/seed-operator-role.py" --email "${OPERATOR_EMAIL}" --instance-id unused --print-uid 2>/dev/null || true)"
    WHOAMI="$(curl -s -m 10 -H "X-Auth-User-Id: ${UID_OUT}" http://127.0.0.1:9123/v1/whoami || echo "")"
    if [[ -n "${UID_OUT}" ]] && REACH="$(WHOAMI="${WHOAMI}" python3 - <<'PY'
import json, os, sys
try:
    w = json.loads(os.environ["WHOAMI"])
    ok = bool(w.get("tier")) and bool(w.get("reachableAgentIds"))
except Exception:
    ok = False
sys.exit(0 if ok else 1)
PY
)"; then
      pass "whoami: operator has tier + reachable agents"
    else
      fail "whoami probe failed (uid='${UID_OUT}', response='${WHOAMI:0:120}')"
    fi
  fi
fi

echo
if [[ ${gaps} -eq 0 ]]; then
  echo "OK: box config is done-done"
  exit 0
fi
echo "GAPS: ${gaps}"
exit 1
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-check-box-config.sh`
Expected: all asserts pass (`N/N passed` from the harness; the file has 1 healthy-path assert + 8 gap asserts)

- [ ] **Step 5: Commit**

```bash
git add scripts/check-box-config.sh tests/test-check-box-config.sh
git commit -m "feat(install): P7 — check-box-config.sh done-done parity gate"
```

### Task 8: fleetctl — `check-config` verb + `verify-supabase-config` update step

**Files:**
- Modify: `templates/bin/ollie-fleetctl` (`build_update_steps` ~line 409, verb registration ~line 1328, new `cmd_check_config`)
- Modify: `README.md` ("## After a hermes update" section — required by `test_readme_matches_code`)
- Modify: `tests/test_fleetctl.py` (step-order tests), `tests/test-fleetctl-update.sh` (`has_step` list + the readme test's `for s in` list)

**Interfaces:**
- Consumes: `scripts/check-box-config.sh` (Task 7), `scripts/11-install-supabase.sh --verify-only` (Task 5).
- Produces: fleetctl verb `check-config` — stdin payload `{"operator_email": "<email>"}` (optional), runs the gate, emits `{"ok": bool, "gaps": int, "output": [lines]}` (Fleet's `runVerb<{ok, gaps, output}>` consumes this). Update step `verify-supabase-config` appended to the `orchestrator` component in `build_update_steps`.

- [ ] **Step 1: Write the failing tests**

In `tests/test_fleetctl.py`, extend the update-steps test class (pattern-match `test_update_stack_steps`):

```python
def test_update_orchestrator_includes_supabase_verify(self):
    mod = load_fleetctl()
    steps = mod.build_update_steps("orchestrator")
    names = [s[0] for s in steps]
    self.assertIn("verify-supabase-config", names)
    self.assertGreater(names.index("verify-supabase-config"), names.index("reinstall-orchestrator"))
    argv = dict((s[0], s[1]) for s in steps)["verify-supabase-config"]
    self.assertIn("11-install-supabase.sh", " ".join(argv))
    self.assertIn("--verify-only", argv)
```

And a `cmd_check_config` test (pattern-match existing verb tests — mock `run_cmd`):

```python
class TestCheckConfig(unittest.TestCase):
    def test_check_config_emits_ok_and_gaps(self):
        mod = load_fleetctl()
        with mock.patch.object(mod, "run_cmd") as rc:
            rc.return_value = (1, "PASS: INSTANCE_ID set\nFAIL: stack SUPABASE_ANON_KEY missing\nGAPS: 1\n", "")
            with mock.patch.object(sys, "stdin", io.StringIO('{"operator_email":"jb@x.com"}')):
                out = run_main(mod, ["check-config"])
        result = out[-1]
        self.assertFalse(result["ok"])
        self.assertEqual(result["gaps"], 1)
        self.assertIn("FAIL: stack SUPABASE_ANON_KEY missing", result["output"])
```

(Adjust `run_cmd` mock signature to whatever the module actually exposes — read the existing verb tests first and copy their mocking exactly.)

In `tests/test-fleetctl-update.sh`, add to the orchestrator `has_step` assertions: `has_step "verify-supabase-config"`, and add `11-install-supabase.sh` to the `test_readme_matches_code` `for s in` list.

- [ ] **Step 2: Run tests to verify they fail**

Run: `python -m pytest tests/test_fleetctl.py -k "supabase_verify or check_config" -v && bash tests/test-fleetctl-update.sh`
Expected: FAIL (step and verb don't exist)

- [ ] **Step 3: Implement in `templates/bin/ollie-fleetctl`**

In `build_update_steps`, append to the `orchestrator`/`all` block after `reinstall-orchestrator`:

```python
steps.append(("verify-supabase-config",
              ["bash", os.path.join(INSTALL_DIR, "scripts", "11-install-supabase.sh"), "--verify-only"],
              120))
```

Add the verb (near `cmd_set_dashboard_auth`):

```python
def cmd_check_config(args):
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        payload = {}
    env = dict(os.environ)
    email = str(payload.get("operator_email") or "").strip()
    if email:
        env["OPERATOR_EMAIL"] = email
    code, out, err = run_cmd(
        ["bash", os.path.join(INSTALL_DIR, "scripts", "check-box-config.sh")],
        timeout=180, env=env)
    lines = [l for l in (out or "").splitlines() if l.strip()]
    gaps = 0
    for l in lines:
        if l.startswith("GAPS:"):
            gaps = int(l.split(":", 1)[1].strip() or 0)
    emit({"ok": code == 0, "gaps": gaps, "output": lines})
```

(If the existing `run_cmd` does not take an `env=` kwarg, add it as an optional parameter defaulting to `None` and pass through to `subprocess.run` — check the existing definition first and follow its style.)

Register: `sub.add_parser("check-config", help="run the done-done parity gate")` and dispatch `elif args.verb == "check-config": cmd_check_config(args)`.

Update `README.md` "## After a hermes update" to include `11-install-supabase.sh --verify-only`.

- [ ] **Step 4: Run all fleetctl tests**

Run: `python -m pytest tests/test_fleetctl.py -v && bash tests/test-fleetctl-update.sh`
Expected: all pass (both suites — S74 lesson)

- [ ] **Step 5: Commit**

```bash
git add templates/bin/ollie-fleetctl README.md tests/test_fleetctl.py tests/test-fleetctl-update.sh
git commit -m "feat(fleetctl): check-config verb + verify-supabase-config update step"
```

---

## Repo: ollie-fleet

### Task 9: `access_state` column + `Instance` type

**Files:**
- Modify: `src/server/db.ts` (~line 138 ALTER loop)
- Modify: `src/shared/types.ts` (Instance type, ~line 26)
- Test: `tests/unit/db.test.ts`

**Interfaces:**
- Produces: `instances.access_state TEXT` (nullable; `NULL` = healthy/legacy, `'pending-tunnel'` = provisioned in tunnel mode, tunnel not yet verified). `Instance.access_state: 'pending-tunnel' | null`.

- [ ] **Step 1: Failing test** — in `tests/unit/db.test.ts` add:

```ts
it('instances has access_state column', () => {
  const cols = (getDb().prepare(`PRAGMA table_info(instances)`).all() as { name: string }[]).map(c => c.name)
  expect(cols).toContain('access_state')
})
```

- [ ] **Step 2: Run** `npx vitest run tests/unit/db.test.ts` — Expected: FAIL
- [ ] **Step 3: Implement** — append to the ALTER loop in `db.ts`: `` `ALTER TABLE instances ADD COLUMN access_state TEXT` ``; add `access_state: 'pending-tunnel' | null` to `Instance` in `src/shared/types.ts`.
- [ ] **Step 4: Run** `npx vitest run tests/unit/db.test.ts` — Expected: PASS
- [ ] **Step 5: Commit** `git add src/server/db.ts src/shared/types.ts tests/unit/db.test.ts && git commit -m "feat(db): instances.access_state column (pending-tunnel tracking)"`

### Task 10: Provision route + API client — new required fields

**Files:**
- Modify: `src/server/routes/provision.ts` (ProvisionBody + validation), `src/server/provision.ts` (ProvisionArgs only — flow lands in Task 11), `src/client/lib/api.ts:144-147`
- Test: `tests/unit/provision-route.test.ts`

**Interfaces:**
- Produces: `ProvisionBody` + `ProvisionArgs` gain `supabaseUrl: string`, `supabaseAnonKey: string`, `supabaseServiceRoleKey: string`, `cookieDomain?: string | null`, `accessMode: 'direct' | 'tunnel'`. Validation (400 with `{error}`): all three Supabase values required; `supabaseUrl` must match `^https:\/\/[A-Za-z0-9.-]+(:\d+)?\/?$` (any https origin — hosted or self-hosted; no path); keys must be single-line non-empty (`/^\S+$/`); `accessMode` must be exactly `'direct'` or `'tunnel'`.

- [ ] **Step 1: Failing tests** — in `tests/unit/provision-route.test.ts` (copy the existing auth/login helper pattern):

```ts
const good = {
  name: 'x', sshHost: '1.2.3.4', rootPassword: 'p',
  supabaseUrl: 'https://abc.supabase.co', supabaseAnonKey: 'anon.key.x',
  supabaseServiceRoleKey: 'service.key.x', accessMode: 'direct',
}

it('rejects provision without supabase creds', async () => {
  const res = await post('/api/provision', { ...good, supabaseUrl: undefined, supabaseAnonKey: undefined, supabaseServiceRoleKey: undefined })
  expect(res.status).toBe(400)
  expect((await res.json()).error).toMatch(/supabase/i)
})

it('rejects a non-https or path-carrying supabase url', async () => {
  expect((await post('/api/provision', { ...good, supabaseUrl: 'http://abc.supabase.co' })).status).toBe(400)
  expect((await post('/api/provision', { ...good, supabaseUrl: 'https://abc.supabase.co/extra' })).status).toBe(400)
  expect((await post('/api/provision', { ...good, supabaseUrl: 'https://supabase.internal.lan:8443' })).status).toBe(202)
})

it('rejects a missing/invalid accessMode', async () => {
  expect((await post('/api/provision', { ...good, accessMode: undefined })).status).toBe(400)
  expect((await post('/api/provision', { ...good, accessMode: 'both' })).status).toBe(400)
})

it('accepts a fully specified provision', async () => {
  const res = await post('/api/provision', good)
  expect(res.status).toBe(202)
})
```

(`post` = the file's existing authenticated-request helper; if it doesn't exist, build it from the `login()` pattern already in that file. The 202 test needs the same ssh/fleetctl mocks `provision.test.ts` uses — copy its `vi.mock` block.)

- [ ] **Step 2: Run** `npx vitest run tests/unit/provision-route.test.ts` — Expected: FAIL
- [ ] **Step 3: Implement** — extend `ProvisionBody`, add to the handler after the vertical check:

```ts
const supabaseUrl = body.supabaseUrl?.trim() ?? ''
const supabaseAnonKey = body.supabaseAnonKey?.trim() ?? ''
const supabaseServiceRoleKey = body.supabaseServiceRoleKey?.trim() ?? ''
const cookieDomain = body.cookieDomain?.trim() || null
const accessMode = body.accessMode
if (!supabaseUrl || !supabaseAnonKey || !supabaseServiceRoleKey)
  return c.json({ error: 'supabaseUrl, supabaseAnonKey, and supabaseServiceRoleKey are required — create the project per the runbook first' }, 400)
if (!/^https:\/\/[A-Za-z0-9.-]+(:\d+)?\/?$/.test(supabaseUrl))
  return c.json({ error: 'supabaseUrl must be an https origin with no path (hosted <ref>.supabase.co or self-hosted)' }, 400)
if (!/^\S+$/.test(supabaseAnonKey) || !/^\S+$/.test(supabaseServiceRoleKey))
  return c.json({ error: 'supabase keys must be single-line values' }, 400)
if (accessMode !== 'direct' && accessMode !== 'tunnel')
  return c.json({ error: "accessMode must be 'direct' or 'tunnel'" }, 400)
```

Pass all five through to `startProvision`; extend `ProvisionArgs` in `src/server/provision.ts` with the same fields; extend `api.provision`'s body type in `src/client/lib/api.ts`.

- [ ] **Step 4: Run** `npx vitest run tests/unit/provision-route.test.ts tests/unit/provision.test.ts` — Expected: PASS (existing provision.test.ts baseArgs will need the new required ProvisionArgs fields added — update its `baseArgs()` factory)
- [ ] **Step 5: Commit** `git commit -am "feat(provision): require supabase creds + access mode on the provision form API"`

### Task 11: Provision flow — stack env, 11-install, P5, P6, gate, external probe

**Files:**
- Modify: `src/server/provision.ts` (the step sequence), `src/server/enroll-core.ts` (`runStep` optional stdin)
- Test: `tests/unit/provision.test.ts`

**Interfaces:**
- Consumes: `runVerb`/`runCommand` stdin support (already exists on `runCommand` — `runVerb` passes `{stdin}`); `saveSupabaseConfig` + `buildSupabaseApplyPayload` from `src/server/lib/supabase-config.ts`; box scripts from install-repo Tasks 5–7.
- Produces: the new provision order (spec "Provision sequence"): 06 → **one combined stack-env append + single dashboard recreate** (creds + `SUPABASE_URL`/`SUPABASE_ANON_KEY`[/`SUPABASE_COOKIE_DOMAIN`] + `DASHBOARD_BIND=0.0.0.0` when direct) → 07/08/09 → **`11-install-supabase.sh` via stdin** → finalizeEnrollment → **P5 `INSTANCE_ID` write + orchestrator restart** → **P6 seed** → **gate** → direct-mode external probe / tunnel-mode `access_state` + runbook emit → done.

- [ ] **Step 1: Failing tests** — extend `tests/unit/provision.test.ts`'s order test (its `baseArgs()` now carries the Task-10 fields; use `accessMode: 'direct'`):

```ts
it('runs supabase install, instance-id write, seed, and gate after 09, in order', async () => {
  const opId = startProvision(baseArgs())
  await settle(opId)
  const cmds = mockRun.mock.calls.map(([, cmd]) => String(cmd))
  const idx = (s: string) => cmds.findIndex(c => c.includes(s))
  expect(idx('SUPABASE_ANON_KEY=')).toBeGreaterThan(idx('06-install-stack'))   // combined append
  expect(idx('DASHBOARD_BIND=0.0.0.0')).toBe(idx('SUPABASE_ANON_KEY='))        // same single append
  expect(idx('11-install-supabase.sh')).toBeGreaterThan(idx('09-install-identity-sync'))
  expect(idx('INSTANCE_ID=')).toBeGreaterThan(idx('11-install-supabase.sh'))
  expect(idx('seed-operator-role.py')).toBeGreaterThan(idx('INSTANCE_ID='))
  expect(idx('check-box-config.sh')).toBeGreaterThan(idx('seed-operator-role.py'))
})

it('fails the operation when the gate exits non-zero', async () => {
  mockRun.mockImplementation(async (_t: unknown, cmd: string) =>
    cmd.includes('check-box-config.sh') ? { code: 1, stdout: 'FAIL: x\nGAPS: 1', stderr: '' } : { code: 0, stdout: '', stderr: '' })
  const opId = startProvision(baseArgs())
  await settle(opId)
  expect(getOperation(opId)?.status).toBe('failed')
})

it('tunnel mode sets access_state=pending-tunnel and skips DASHBOARD_BIND', async () => {
  const opId = startProvision({ ...baseArgs(), accessMode: 'tunnel' })
  await settle(opId)
  const cmds = mockRun.mock.calls.map(([, cmd]) => String(cmd))
  expect(cmds.some(c => c.includes('DASHBOARD_BIND=0.0.0.0'))).toBe(false)
  const row = getDb().prepare(`SELECT access_state FROM instances`).get() as { access_state: string }
  expect(row.access_state).toBe('pending-tunnel')
})

it('passes the service-role key via stdin, never in the command line', async () => {
  const opId = startProvision(baseArgs())
  await settle(opId)
  const cmds = mockRun.mock.calls.map(([, cmd]) => String(cmd))
  expect(cmds.some(c => c.includes(baseArgs().supabaseServiceRoleKey))).toBe(false)
})
```

(The external-probe fetch is stubbed: `vi.stubGlobal('fetch', vi.fn(async () => ({ status: 401 })))` in beforeEach for direct-mode tests.)

- [ ] **Step 2: Run** — Expected: FAIL
- [ ] **Step 3: Implement in `src/server/provision.ts`:**

Replace the `dashboard-creds` step (lines 82–85) with the combined append:

```ts
emit({ event: 'progress', step: 'stack-env' })
const stackAppendLines = [
  `DASHBOARD_USER=${dashboardUser}`,
  `DASHBOARD_PASS=${dashboardPass}`,
  `SUPABASE_URL=${args.supabaseUrl.replace(/\/$/, '')}`,
  `SUPABASE_ANON_KEY=${args.supabaseAnonKey}`,
  ...(args.cookieDomain ? [`SUPABASE_COOKIE_DOMAIN=${args.cookieDomain}`] : []),
  ...(args.accessMode === 'direct' ? ['DASHBOARD_BIND=0.0.0.0'] : []),
].join('\n') + '\n'
const writeStackEnv = `printf '%s' ${shellQuote(stackAppendLines)} >> ~/hermes-stack/.env && docker compose -f ~/hermes-stack/docker-compose.yml up -d dashboard`
await runStep(svc, writeStackEnv, 'write stack env (creds + supabase + bind)', 120_000)
```

After step 09, add:

```ts
emit({ event: 'progress', step: 'supabase-config' })
const supabaseStdin = `SUPABASE_URL=${args.supabaseUrl.replace(/\/$/, '')}\nSUPABASE_SERVICE_ROLE_KEY=${args.supabaseServiceRoleKey}\n`
await runStep(svc, script('11-install-supabase.sh'), '11-install-supabase', 180_000, supabaseStdin)
```

Extend `runStep` in `enroll-core.ts` with an optional 5th param: `stdin?: string`, passed through as `runCommand(target, cmd, { timeoutMs, ...(stdin ? { stdin } : {}) })` (runCommand already supports `stdin` — `runVerb` uses it).

After `finalizeEnrollment` (which returns `{ instanceId }`):

```ts
emit({ event: 'progress', step: 'instance-id' })
const writeInstanceId = `f=~/.config/ollie-orchestrator/.env; grep -q '^INSTANCE_ID=' $f && sed -i 's|^INSTANCE_ID=.*|INSTANCE_ID=${instanceId}|' $f || echo 'INSTANCE_ID=${instanceId}' >> $f; XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user restart ollie-orchestrator`
await runStep(svc, writeInstanceId, 'write INSTANCE_ID', 60_000)

emit({ event: 'progress', step: 'seed-operator' })
await runStep(svc, `python3 ~/ollie-hermes-install/scripts/lib/seed-operator-role.py --email ${shellQuote(args.userEmail)} --instance-id ${shellQuote(instanceId)}`, 'seed operator role', 60_000)

emit({ event: 'progress', step: 'gate' })
await runStep(svc, `OPERATOR_EMAIL=${shellQuote(args.userEmail)} bash ~/ollie-hermes-install/scripts/check-box-config.sh`, 'done-done gate', 180_000)

if (args.accessMode === 'direct' && args.frontendUrl) {
  emit({ event: 'progress', step: 'frontend-probe' })
  const res = await fetch(args.frontendUrl, { signal: AbortSignal.timeout(10_000) }).catch(() => null)
  if (!res || (res.status !== 200 && res.status !== 401))
    throw new Error(`frontend_url not reachable from Fleet: ${args.frontendUrl} (got ${res ? res.status : 'no response'})`)
} else if (args.accessMode === 'tunnel') {
  getDb().prepare(`UPDATE instances SET access_state = 'pending-tunnel' WHERE id = ?`).run(instanceId)
  emit({ event: 'tunnel-runbook', steps: [
    'Add a cloudflared public hostname for this box -> http://localhost:3000',
    'See ollie-hermes-install docs/runbooks/hermes-dashboard-cloudflare.md for the Host/Origin rewrites',
    'Then run the Check Config action on the instance page to clear pending-tunnel',
  ] })
}
```

Also persist the pasted Supabase config to Fleet's DB so the Access tab shows it (after `finalizeEnrollment`, non-fatal try/catch like the existing copy-forward — which this supersedes for provision since explicit creds always exist):

```ts
try {
  saveSupabaseConfig({ id: instanceId, name: args.name, frontend_url: args.frontendUrl ?? null },
    { enabled: true, supabaseUrl: args.supabaseUrl, anonKey: args.supabaseAnonKey,
      serviceRoleKey: args.supabaseServiceRoleKey, cookieDomain: args.cookieDomain ?? undefined })
} catch (e) { console.warn(`[provision] supabase row save failed: ${(e as Error).message}`) }
```

- [ ] **Step 4: Run the full fleet suite** — `npm test` — Expected: PASS (fix any step-order/count assertions in existing tests that the new steps shift)
- [ ] **Step 5: Commit** `git commit -am "feat(provision): supabase apply + INSTANCE_ID + operator seed + done-done gate in the provision flow"`

### Task 12: Provision UI — new form fields + tunnel-runbook display

**Files:**
- Modify: `src/client/pages/Enroll.tsx` (`ProvisionNew`, lines 114–217)
- Test: `tests/unit/provision-form-logic.test.ts` (new — pure validation helper)

**Interfaces:**
- Consumes: `api.provision` extended body (Task 10).
- Produces: form fields `Supabase URL` (id `psburl`), `Supabase anon key` (id `psbanon`), `Supabase service-role key` (id `psbservice`, `type="password"`), `Cookie domain (optional)` (id `psbcookie`), `Access mode` select (id `paccess`, options `direct`/`tunnel`, no preselected value); a warning paragraph shown when `direct` is selected: *"Direct mode serves basic-auth over cleartext HTTP on a public IP — use only until the tunnel is up."*; client-side gate `provisionReady(fields): string | null` returning the first validation error or null (mirrors the server rules from Task 10); the done panel renders the `tunnel-runbook` event's steps when present.

- [ ] **Step 1: Failing test** — extract validation to `src/client/lib/provision-validate.ts` and test it:

```ts
import { provisionReady } from '../../src/client/lib/provision-validate'

const good = { name: 'x', sshHost: 'h', rootKey: 'k', supabaseUrl: 'https://abc.supabase.co',
  supabaseAnonKey: 'a', supabaseServiceRoleKey: 's', accessMode: 'direct' }

it('accepts a complete form', () => expect(provisionReady(good)).toBeNull())
it('requires supabase fields', () => expect(provisionReady({ ...good, supabaseUrl: '' })).toMatch(/supabase/i))
it('requires an access mode', () => expect(provisionReady({ ...good, accessMode: '' })).toMatch(/access mode/i))
it('rejects a bad supabase url', () => expect(provisionReady({ ...good, supabaseUrl: 'http://abc.supabase.co' })).toMatch(/https/))
it('accepts a self-hosted https origin', () => expect(provisionReady({ ...good, supabaseUrl: 'https://supabase.internal.lan:8443' })).toBeNull())
```

- [ ] **Step 2: Run** `npx vitest run tests/unit/provision-form-logic.test.ts` — Expected: FAIL
- [ ] **Step 3: Implement** — `src/client/lib/provision-validate.ts`:

```ts
export type ProvisionFields = {
  name: string; sshHost: string; rootKey?: string; rootPassword?: string
  supabaseUrl: string; supabaseAnonKey: string; supabaseServiceRoleKey: string
  accessMode: string
}

export function provisionReady(f: ProvisionFields): string | null {
  if (!f.name.trim() || !f.sshHost.trim()) return 'name and SSH host are required'
  if (!f.rootKey?.trim() && !f.rootPassword?.trim()) return 'a root credential is required'
  if (!f.supabaseUrl.trim() || !f.supabaseAnonKey.trim() || !f.supabaseServiceRoleKey.trim())
    return 'all three Supabase values are required — create the project per the runbook first'
  if (!/^https:\/\/[A-Za-z0-9.-]+(:\d+)?\/?$/.test(f.supabaseUrl.trim()))
    return 'Supabase URL must be an https origin with no path (hosted <ref>.supabase.co or self-hosted)'
  if (f.accessMode !== 'direct' && f.accessMode !== 'tunnel') return 'choose an access mode'
  return null
}
```

Then in `ProvisionNew`: add the five state vars, render with the existing `<Field>` pattern (service-role key uses `type="password"`), an access-mode `<select>` (copy `VerticalSelect`'s structure), the direct-mode warning `<p>`, call `provisionReady` before submit (show its message as the form error), pass the new fields into `api.provision`, and render `tunnel-runbook` event steps in the progress/done panel (the SSE handler already appends events — add a branch for `e.event === 'tunnel-runbook'`).

- [ ] **Step 4: Run** `npx vitest run && npx tsc --noEmit` — Expected: PASS + clean types
- [ ] **Step 5: Commit** `git commit -am "feat(ui): provision form collects supabase creds + access mode; shows tunnel runbook"`

### Task 13: On-demand gate action + pending-tunnel clearing

**Files:**
- Create: route handler in `src/server/routes/instances.ts` (or the file where per-instance actions live — follow `POST /:id/supabase/apply`'s home): `POST /api/instances/:id/check-config`
- Modify: `src/server/fleetctl.ts` (add `checkConfig` transport), `src/client/lib/api.ts`, `src/client/pages/InstanceDetail.tsx` (button + report display)
- Test: `tests/unit/check-config-route.test.ts`

**Interfaces:**
- Consumes: fleetctl `check-config` verb (Task 8): `runVerb<{ ok: boolean; gaps: number; output: string[] }>(t, ['check-config'], { stdin: JSON.stringify({ operator_email }), timeoutMs: 240_000 })`.
- Produces: `POST /api/instances/:id/check-config` → `{ ok, gaps, output, accessState }`. When the gate passes AND the instance is `pending-tunnel` AND `frontend_url` probes reachable (200/401 within 10s), clears `access_state` to `NULL`. Audits `'check-config'`.

- [ ] **Step 1: Failing test** (pattern-match `instance-supabase-routes.test.ts` — mock the fleetctl transport):

```ts
it('runs the gate and clears pending-tunnel when frontend answers', async () => {
  mockCheckConfig.mockResolvedValue({ ok: true, gaps: 0, output: ['OK: box config is done-done'] })
  vi.stubGlobal('fetch', vi.fn(async () => ({ status: 401 })))
  seedInstance({ access_state: 'pending-tunnel', frontend_url: 'https://olliegetbilled.jnow.io' })
  const res = await post(`/api/instances/${id}/check-config`, {})
  expect(res.status).toBe(200)
  const body = await res.json()
  expect(body.ok).toBe(true)
  expect(body.accessState).toBeNull()
})

it('keeps pending-tunnel when the gate fails', async () => {
  mockCheckConfig.mockResolvedValue({ ok: false, gaps: 2, output: ['FAIL: x', 'GAPS: 2'] })
  seedInstance({ access_state: 'pending-tunnel' })
  const body = await (await post(`/api/instances/${id}/check-config`, {})).json()
  expect(body.accessState).toBe('pending-tunnel')
})
```

- [ ] **Step 2: Run** — Expected: FAIL
- [ ] **Step 3: Implement** — transport in `fleetctl.ts`:

```ts
export const checkConfig = (t: SshTarget, operatorEmail: string | null) =>
  runVerb<{ ok: boolean; gaps: number; output: string[] }>(t, ['check-config'],
    { stdin: JSON.stringify(operatorEmail ? { operator_email: operatorEmail } : {}), timeoutMs: 240_000 })
```

Route: load instance (404 if absent), call `checkConfig(instanceTarget(i), c.get('userEmail'))`, then:

```ts
let accessState = i.access_state ?? null
if (result.ok && accessState === 'pending-tunnel' && i.frontend_url) {
  const res = await fetch(i.frontend_url, { signal: AbortSignal.timeout(10_000) }).catch(() => null)
  if (res && (res.status === 200 || res.status === 401)) {
    getDb().prepare(`UPDATE instances SET access_state = NULL WHERE id = ?`).run(i.id)
    accessState = null
  }
}
audit(c, 'check-config', i.id, i.name)
return c.json({ ...result, accessState })
```

Client: `api.checkConfig(id)` + an InstanceDetail "Check Config" button rendering `output` lines verbatim (monospace) and a `pending-tunnel` badge bound to `accessState`.

- [ ] **Step 4: Run** `npm test && npx tsc --noEmit` — Expected: PASS
- [ ] **Step 5: Commit** `git commit -am "feat(instances): on-demand done-done gate + pending-tunnel clearing"`

---

## Cross-repo finish

### Task 14: Pin bump, exposure-check note, and the GetBilled acceptance run

**Files:**
- Modify: `ollie-fleet/src/server/enroll-core.ts` (`INSTALL_REPO_REF` default, line 9)
- No code in install repo (uses its final master SHA)

**Interfaces:**
- Consumes: everything above, pushed.

- [ ] **Step 1:** Push `ollie-hermes-install` master; note the final SHA.
- [ ] **Step 2:** Set `INSTALL_REPO_REF` default in `enroll-core.ts:9` to that SHA; run `bash scripts/check-install-pin.sh ../ollie-hermes-install` in ollie-fleet — Expected: `OK`. Also update `tests/unit/install-ref.test.ts`'s pinned value.
- [ ] **Step 3:** `npm test` in ollie-fleet; push ollie-fleet; deploy fleet-prod (`git pull` + `bash /opt/ollie-fleet/scripts/provision-fleet-hetzner.sh` as root — verify with `systemctl status ollie-fleet`, not the provisioner's transient "health: UNREACHABLE" tail).
- [ ] **Step 4 (with John): acceptance run.** Create the GetBilled Supabase project + run the provisioning runbook (`docs/runbooks/supabase-ollie-core-provisioning.md`); wipe the IONOS box (fresh OS image); provision through the Fleet UI with real creds, `accessMode: direct` (tunnel later); verify with zero hand-applied config: login at `http://74.208.207.91:3000/`, chat round-trip with the default agent, one management-surface call (Skills list). **This is the definition of done.**
- [ ] **Step 5:** Run `bash scripts/check-box-exposure.sh 74.208.207.91 3000` from ollie-fleet — in direct mode :3000 is expected-open; record the accepted exposure in the instance notes until the tunnel lands.

## Verification tail (whole workstream)

- Install repo: `bash tests/test-detect-agents.sh && bash tests/test-render-proxy-maps.sh && bash tests/test-ensure-dashboard-token.sh && bash tests/test-supabase-env.sh && bash tests/test-check-box-config.sh && bash tests/test-stack-env.sh && bash tests/test-merge-agents.sh && bash tests/test-heal-dashboard-units.sh && bash tests/test-fleetctl-update.sh && python -m pytest tests/ -v`
- ollie-fleet: `npm test && npx tsc --noEmit`
- Acceptance: Task 14 Step 4.
