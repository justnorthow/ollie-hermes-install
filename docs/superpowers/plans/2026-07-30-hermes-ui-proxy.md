# Hermes UI Proxy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give operators the full native Hermes dashboard in a browser, via a token-injecting nginx reverse proxy bound to loopback on each box, reached over an SSH port-forward.

**Architecture:** A new `scripts/lib/ensure-hermes-ui-proxy.sh` discovers each `hermes-dashboard*.service` user unit, derives its listen port as `upstream + 100`, and renders one nginx server block per agent under `/etc/nginx/conf.d/`. Every block includes a single mode-600 `/etc/nginx/hermes-ui-auth.conf` holding the `Authorization: Bearer <token>` header line — mirroring the existing `cortex-auth.conf` pattern. `ensure-dashboard-token.sh` calls the new script at its end so token rotation can never drift.

**Tech Stack:** Bash (POSIX-ish, `set -uo pipefail`), nginx (host package), systemd user units, Python 3 for the fleetctl runbook, the repo's existing shell test harness (`tests/lib/assert.sh`) and stdlib `unittest`.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-30-hermes-dashboard-browser-access-design.md`. Read it before Task 1.
- Listen port = upstream dashboard port **+ 100**. `9119 → 9219`, `9121 → 9221`.
- All three header rewrites are mandatory and none may be dropped: `Authorization: Bearer <token>`, `Host: 127.0.0.1:<upstream>`, `Origin: http://127.0.0.1:<upstream>`.
- Every listener binds `127.0.0.1` only. Never `0.0.0.0`.
- Scripts must be idempotent: compare-then-write, reload nginx only on change.
- `XDG_RUNTIME_DIR=/run/user/1000` must be set for any `systemctl --user` call.
- Test env-override names follow the existing convention: `ORCH_ENV`, `SYSTEMD_USER_DIR`, plus new `NGINX_CONF_DIR`, `NGINX_AUTH_FILE`, `ENSURE_UI_PROXY_NO_RELOAD=1`.
- `chmod`/mode assertions must be capability-probed, not assumed — NTFS does not enforce POSIX modes and the suite runs on Windows. Copy the probe from `tests/test-ensure-dashboard-token.sh:27-33`.
- Shell tests prove emitted text only. The real gate is the sandbox acceptance run in Task 9.

## File Structure

| File | Responsibility |
|---|---|
| `scripts/lib/ensure-hermes-ui-proxy.sh` | **New.** Discover agents/ports, render auth file + shared map + per-agent server blocks, reload nginx on change. |
| `tests/test-hermes-ui-proxy.sh` | **New.** Shim tests for the above. |
| `scripts/lib/ensure-dashboard-token.sh` | **Modify.** Call the new script at its end so rotation re-renders. |
| `scripts/27-install-nginx.sh` | **New.** Install nginx, disable the default `:80` site. |
| `scripts/03-install-profile.sh:174-180` | **Modify.** Call the new script in the existing step 6b block. |
| `templates/bin/ollie-fleetctl` | **Modify.** Add `ensure-hermes-ui-proxy` to the `update hermes` runbook. |
| `tests/test_fleetctl.py:360-366` | **Modify.** Extend the asserted step list. |
| `scripts/check-box-config.sh` | **Modify.** New gate section 3b. |
| `tests/test-check-box-config.sh` | **Modify.** Cover the new gate. |
| `docs/runbooks/hermes-ui-proxy.md` | **New.** Operator instructions. |
| `ollie-hermes-frontend/src/components/Layout.tsx:179-199` | **Modify.** *(separate repo)* Role-gate the link, drop the `:9119` fallback. |

---

### Task 1: `ensure-hermes-ui-proxy.sh` — discovery, rendering, idempotency

**Files:**
- Create: `scripts/lib/ensure-hermes-ui-proxy.sh`
- Test: `tests/test-hermes-ui-proxy.sh`

**Interfaces:**
- Consumes: `HERMES_DASHBOARD_TOKEN` from the orchestrator `.env` (same key `ensure-dashboard-token.sh` writes); `hermes-dashboard*.service` units in `SYSTEMD_USER_DIR`.
- Produces: `${NGINX_AUTH_FILE}` (default `/etc/nginx/hermes-ui-auth.conf`); `${NGINX_CONF_DIR}/hermes-ui-map.conf`; `${NGINX_CONF_DIR}/hermes-ui-proxy-<agent>.conf` per agent. Agent id: `hermes-dashboard.service` → `default`; `hermes-dashboard-<id>.service` → `<id>`.

- [ ] **Step 1: Write the failing test**

Create `tests/test-hermes-ui-proxy.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/assert.sh"
ENSURE="$HERE/../scripts/lib/ensure-hermes-ui-proxy.sh"

setup_dir() {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/units" "$d/nginx"
  printf '[Service]\nExecStart=hermes dashboard --host 127.0.0.1 --port 9119\n' > "$d/units/hermes-dashboard.service"
  printf '[Service]\nExecStart=hermes -p real-estate dashboard --host 127.0.0.1 --port 9121\n' > "$d/units/hermes-dashboard-real-estate.service"
  printf '[Service]\nExecStart=hermes gateway\n' > "$d/units/hermes-gateway.service"
  printf 'HERMES_DASHBOARD_TOKEN=tok-abcdef0123456789\n' > "$d/orch.env"
  echo "$d"
}

run_ensure() {
  local d="$1"
  ORCH_ENV="$d/orch.env" SYSTEMD_USER_DIR="$d/units" \
  NGINX_CONF_DIR="$d/nginx" NGINX_AUTH_FILE="$d/nginx/hermes-ui-auth.conf" \
  ENSURE_UI_PROXY_NO_RELOAD=1 bash "$ENSURE" >/dev/null 2>&1
}

test_renders_both_agents_with_correct_ports() {
  local d; d="$(setup_dir)"; run_ensure "$d"
  assert_eq "default listens 9219" \
    "$(grep -c 'listen 127.0.0.1:9219;' "$d/nginx/hermes-ui-proxy-default.conf")" "1"
  assert_eq "default upstream 9119" \
    "$(grep -c 'proxy_pass http://127.0.0.1:9119;' "$d/nginx/hermes-ui-proxy-default.conf")" "1"
  assert_eq "real-estate listens 9221" \
    "$(grep -c 'listen 127.0.0.1:9221;' "$d/nginx/hermes-ui-proxy-real-estate.conf")" "1"
  assert_eq "real-estate upstream 9121" \
    "$(grep -c 'proxy_pass http://127.0.0.1:9121;' "$d/nginx/hermes-ui-proxy-real-estate.conf")" "1"
  assert_eq "gateway ignored" \
    "$([[ -f "$d/nginx/hermes-ui-proxy-gateway.conf" ]] && echo yes || echo no)" "no"
}

test_all_three_headers_present_per_agent() {
  local d; d="$(setup_dir)"; run_ensure "$d"
  assert_eq "auth file has bearer" \
    "$(cat "$d/nginx/hermes-ui-auth.conf")" \
    'proxy_set_header Authorization "Bearer tok-abcdef0123456789";'
  for a in default:9119 real-estate:9121; do
    n="${a%%:*}"; p="${a##*:}"
    assert_eq "$n includes auth file" \
      "$(grep -c 'include .*hermes-ui-auth.conf;' "$d/nginx/hermes-ui-proxy-$n.conf")" "1"
    assert_eq "$n rewrites Host" \
      "$(grep -c "proxy_set_header Host 127.0.0.1:$p;" "$d/nginx/hermes-ui-proxy-$n.conf")" "1"
    assert_eq "$n rewrites Origin" \
      "$(grep -c "proxy_set_header Origin http://127.0.0.1:$p;" "$d/nginx/hermes-ui-proxy-$n.conf")" "1"
  done
}

test_single_shared_map_no_duplicate_directive() {
  local d; d="$(setup_dir)"; run_ensure "$d"
  assert_eq "exactly one map file" \
    "$(grep -l 'map \$http_upgrade' "$d/nginx/"*.conf | wc -l | tr -d ' ')" "1"
  assert_eq "map lives in the shared file" \
    "$(grep -c 'map \$http_upgrade' "$d/nginx/hermes-ui-map.conf")" "1"
}

test_never_binds_public() {
  local d; d="$(setup_dir)"; run_ensure "$d"
  assert_eq "no 0.0.0.0 anywhere" \
    "$(grep -l '0\.0\.0\.0' "$d/nginx/"*.conf | wc -l | tr -d ' ')" "0"
}

test_idempotent_no_drift() {
  local d; d="$(setup_dir)"; run_ensure "$d"
  local a; a="$(cat "$d/nginx/"*.conf)"
  run_ensure "$d"
  assert_eq "second run identical" "$(cat "$d/nginx/"*.conf)" "$a"
}

test_auth_file_mode_600() {
  local d; d="$(setup_dir)"; run_ensure "$d"
  local probe; probe="$(mktemp)"; chmod 600 "$probe"
  if [[ "$(stat -c %a "$probe")" == "600" ]]; then
    assert_eq "auth file mode 600" "$(stat -c %a "$d/nginx/hermes-ui-auth.conf")" "600"
  else
    echo "SKIP: mode-600 assertion (filesystem does not enforce POSIX modes)"
  fi
  rm -f "$probe"
}

test_missing_token_fails_loudly() {
  local d; d="$(setup_dir)"
  printf '\n' > "$d/orch.env"
  ORCH_ENV="$d/orch.env" SYSTEMD_USER_DIR="$d/units" \
  NGINX_CONF_DIR="$d/nginx" NGINX_AUTH_FILE="$d/nginx/hermes-ui-auth.conf" \
  ENSURE_UI_PROXY_NO_RELOAD=1 bash "$ENSURE" >/dev/null 2>&1
  assert_eq "nonzero exit on missing token" "$?" "1"
  assert_eq "no conf written" \
    "$([[ -f "$d/nginx/hermes-ui-proxy-default.conf" ]] && echo yes || echo no)" "no"
}

test_renders_both_agents_with_correct_ports
test_all_three_headers_present_per_agent
test_single_shared_map_no_duplicate_directive
test_never_binds_public
test_idempotent_no_drift
test_auth_file_mode_600
test_missing_token_fails_loudly
finish
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-hermes-ui-proxy.sh`
Expected: FAIL — the script does not exist yet.

- [ ] **Step 3: Write the implementation**

Create `scripts/lib/ensure-hermes-ui-proxy.sh`:

```bash
#!/usr/bin/env bash
# ensure-hermes-ui-proxy.sh — loopback nginx proxy that injects the Hermes
# dashboard session token, so operators can use the FULL native dashboard in a
# browser over `ssh -L`. Hermes 0.19.0 requires an Authorization: Bearer header
# that a browser cannot send on navigation; this supplies it server-side.
#
# One listener per hermes-dashboard*.service, port = upstream + 100.
# The token lives in ONE mode-600 include file (mirrors cortex-auth.conf), so
# rotation rewrites one small file. ensure-dashboard-token.sh calls this script
# so the two can never drift.
#
# Env: ORCH_ENV, SYSTEMD_USER_DIR, NGINX_CONF_DIR, NGINX_AUTH_FILE,
#      ENSURE_UI_PROXY_NO_RELOAD=1 (skip nginx reload — tests).
set -uo pipefail

ORCH_ENV="${ORCH_ENV:-$HOME/.config/ollie-orchestrator/.env}"
UNIT_DIR="${SYSTEMD_USER_DIR:-$HOME/.config/systemd/user}"
NGINX_CONF_DIR="${NGINX_CONF_DIR:-/etc/nginx/conf.d}"
NGINX_AUTH_FILE="${NGINX_AUTH_FILE:-/etc/nginx/hermes-ui-auth.conf}"
PORT_OFFSET=100

# Use sudo only when we cannot write the target ourselves. Fail LOUDLY rather
# than half-applying: a proxy that renders without its auth file 401s on every
# call, which is worse than one that was never installed.
target_parent="$(dirname "${NGINX_AUTH_FILE}")"
if [[ -w "${NGINX_CONF_DIR}" || ! -e "${NGINX_CONF_DIR}" ]] && [[ -w "${target_parent}" ]]; then
  SUDO=""
else
  if ! sudo -n true 2>/dev/null; then
    echo "ensure-hermes-ui-proxy: FATAL — need write access to ${NGINX_CONF_DIR} and ${NGINX_AUTH_FILE}, and passwordless sudo is unavailable" >&2
    exit 1
  fi
  SUDO="sudo"
fi

TOKEN="$(grep '^HERMES_DASHBOARD_TOKEN=' "${ORCH_ENV}" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
if [[ -z "${TOKEN}" ]]; then
  echo "ensure-hermes-ui-proxy: FATAL — HERMES_DASHBOARD_TOKEN empty in ${ORCH_ENV}; run ensure-dashboard-token.sh first" >&2
  exit 1
fi

changed=0
write_if_changed() {  # $1=path  $2=content  $3=mode(optional)
  local path="$1" content="$2" mode="${3:-}"
  if [[ -f "${path}" ]] && [[ "$(${SUDO} cat "${path}" 2>/dev/null)" == "${content}" ]]; then
    return 0
  fi
  ${SUDO} mkdir -p "$(dirname "${path}")"
  printf '%s' "${content}" | ${SUDO} tee "${path}" >/dev/null
  [[ -n "${mode}" ]] && ${SUDO} chmod "${mode}" "${path}"
  changed=1
  echo "ensure-hermes-ui-proxy: wrote ${path}"
}

write_if_changed "${NGINX_AUTH_FILE}" \
  "$(printf 'proxy_set_header Authorization "Bearer %s";' "${TOKEN}")" 600

# Shared map. MUST be exactly one across all rendered files — nginx rejects a
# duplicate `map` with the same name, which only shows up once a SECOND agent
# exists. This is why acceptance requires two agents.
write_if_changed "${NGINX_CONF_DIR}/hermes-ui-map.conf" \
"$(cat <<'MAP'
map $http_upgrade $hermes_ui_conn_upgrade {
    default upgrade;
    ''      close;
}
MAP
)"

shopt -s nullglob
for unit in "${UNIT_DIR}"/hermes-dashboard*.service; do
  unit_name="$(basename "${unit}")"
  agent="${unit_name#hermes-dashboard}"; agent="${agent%.service}"; agent="${agent#-}"
  [[ -z "${agent}" ]] && agent="default"

  upstream="$(grep -oE '^ExecStart=.*--port[= ]+[0-9]+' "${unit}" | grep -oE '[0-9]+$' | tail -1)"
  if [[ -z "${upstream}" ]]; then
    echo "ensure-hermes-ui-proxy: skip ${unit_name} (no --port in ExecStart)" >&2
    continue
  fi
  listen=$(( upstream + PORT_OFFSET ))

  write_if_changed "${NGINX_CONF_DIR}/hermes-ui-proxy-${agent}.conf" \
"$(cat <<CONF
# Generated by ensure-hermes-ui-proxy.sh — do not edit by hand.
# Agent: ${agent}   loopback ${listen} -> Hermes dashboard ${upstream}
# Reach it with:  ssh -L ${listen}:127.0.0.1:${listen} ollie@<box>
server {
    listen 127.0.0.1:${listen};
    server_name _;

    large_client_header_buffers 8 32k;
    client_max_body_size 20m;

    location / {
        # The session token. Without it every API route 401s.
        include ${NGINX_AUTH_FILE};

        proxy_pass http://127.0.0.1:${upstream};

        # Hermes validates Host on EVERY request (400 otherwise) and CSRF-checks
        # Origin on /api/ws, /api/events and /api/pty (403 otherwise, and the
        # chat/events/log streams then silently never connect).
        proxy_set_header Host 127.0.0.1:${upstream};
        proxy_set_header Origin http://127.0.0.1:${upstream};

        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$hermes_ui_conn_upgrade;
        proxy_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
CONF
)"
done

if [[ "${ENSURE_UI_PROXY_NO_RELOAD:-0}" == "1" ]]; then
  exit 0
fi
if [[ "${changed}" == "1" ]]; then
  if ${SUDO} nginx -t 2>/dev/null; then
    ${SUDO} systemctl reload nginx || echo "ensure-hermes-ui-proxy: warning: nginx reload failed" >&2
  else
    echo "ensure-hermes-ui-proxy: FATAL — nginx -t rejected the rendered config; not reloading" >&2
    exit 1
  fi
fi
echo "ensure-hermes-ui-proxy: done (changed=${changed})"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-hermes-ui-proxy.sh`
Expected: all assertions PASS (mode-600 may print `SKIP:` on Windows — that is expected, not a failure).

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/ensure-hermes-ui-proxy.sh tests/test-hermes-ui-proxy.sh
git commit -m "feat(hermes-ui): token-injecting loopback nginx proxy per agent dashboard"
```

---

### Task 2: Couple token rotation so it cannot drift

**Files:**
- Modify: `scripts/lib/ensure-dashboard-token.sh` (append to end, after the restart block)
- Test: `tests/test-hermes-ui-proxy.sh` (add one test)

**Interfaces:**
- Consumes: Task 1's `ensure-hermes-ui-proxy.sh`.
- Produces: nothing new; guarantees that a token change re-renders `hermes-ui-auth.conf`.

- [ ] **Step 1: Write the failing test**

Append to `tests/test-hermes-ui-proxy.sh` (before the runner block at the bottom):

```bash
test_rotation_rerenders_auth_file() {
  local d; d="$(setup_dir)"; run_ensure "$d"
  assert_eq "initial bearer" "$(cat "$d/nginx/hermes-ui-auth.conf")" \
    'proxy_set_header Authorization "Bearer tok-abcdef0123456789";'
  printf 'HERMES_DASHBOARD_TOKEN=tok-ROTATED-9876543210\n' > "$d/orch.env"
  run_ensure "$d"
  assert_eq "auth file follows rotation" "$(cat "$d/nginx/hermes-ui-auth.conf")" \
    'proxy_set_header Authorization "Bearer tok-ROTATED-9876543210";'
  assert_eq "server blocks unchanged by rotation" \
    "$(grep -c 'listen 127.0.0.1:9219;' "$d/nginx/hermes-ui-proxy-default.conf")" "1"
}

test_ensure_token_invokes_ui_proxy() {
  local d; d="$(setup_dir)"
  ORCH_ENV="$d/orch.env" SYSTEMD_USER_DIR="$d/units" \
  NGINX_CONF_DIR="$d/nginx" NGINX_AUTH_FILE="$d/nginx/hermes-ui-auth.conf" \
  ENSURE_UI_PROXY_NO_RELOAD=1 ENSURE_TOKEN_NO_RESTART=1 \
    bash "$HERE/../scripts/lib/ensure-dashboard-token.sh" >/dev/null 2>&1
  local tok; tok="$(grep '^HERMES_DASHBOARD_TOKEN=' "$d/orch.env" | cut -d= -f2-)"
  assert_eq "ui-proxy auth file written by token script" \
    "$(cat "$d/nginx/hermes-ui-auth.conf")" \
    "$(printf 'proxy_set_header Authorization "Bearer %s";' "$tok")"
}
```

Add both to the runner list at the bottom of the file.

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-hermes-ui-proxy.sh`
Expected: `test_rotation_rerenders_auth_file` passes (Task 1 already handles it); `test_ensure_token_invokes_ui_proxy` FAILS — `ensure-dashboard-token.sh` does not call the new script yet.

- [ ] **Step 3: Write the implementation**

Append to the very end of `scripts/lib/ensure-dashboard-token.sh`:

```bash
# The Hermes UI proxy embeds this token in an nginx include file. Re-render it
# here so a rotation can never leave the two out of step. No-op when the proxy
# script is absent (older boxes) — never fail the token path because of it.
UI_PROXY="$(dirname "${BASH_SOURCE[0]}")/ensure-hermes-ui-proxy.sh"
if [[ -f "${UI_PROXY}" ]]; then
  ORCH_ENV="${ORCH_ENV}" SYSTEMD_USER_DIR="${UNIT_DIR}" bash "${UI_PROXY}" \
    || echo "ensure-dashboard-token: warning: ui-proxy refresh failed" >&2
fi
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/test-hermes-ui-proxy.sh && bash tests/test-ensure-dashboard-token.sh`
Expected: both suites pass. The existing token suite must stay green — it asserts drop-in content that this change must not disturb.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/ensure-dashboard-token.sh tests/test-hermes-ui-proxy.sh
git commit -m "feat(hermes-ui): re-render proxy auth on token rotation"
```

---

### Task 3: `27-install-nginx.sh` — install nginx, disable the default site

**Files:**
- Create: `scripts/27-install-nginx.sh`
- Test: `tests/test-27-install-nginx.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: nginx installed and enabled; `/etc/nginx/sites-enabled/default` removed. Task 4 depends on nginx existing before `ensure-hermes-ui-proxy.sh` runs.

- [ ] **Step 1: Write the failing test**

Create `tests/test-27-install-nginx.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/assert.sh"
S="$HERE/../scripts/27-install-nginx.sh"

test_is_executable_bash() {
  assert_eq "file exists" "$([[ -f "$S" ]] && echo yes || echo no)" "yes"
  assert_eq "bash shebang" "$(head -1 "$S")" "#!/usr/bin/env bash"
}

test_removes_default_site() {
  # grep -c counts matching LINES, and the path legitimately appears on both the
  # existence check and the rm. Assert the removal specifically.
  assert_eq "rm -f on sites-enabled/default" \
    "$(grep -cE 'rm -f .*sites-enabled/default' "$S")" "1"
}

test_never_opens_public_ports() {
  assert_eq "no ufw allow 80/443" "$(grep -cE 'ufw +allow +(80|443)' "$S")" "0"
  assert_eq "no certbot/letsencrypt" "$(grep -ciE 'certbot|letsencrypt' "$S")" "0"
}

test_verifies_config_before_finishing() {
  assert_eq "runs nginx -t" "$(grep -c 'nginx -t' "$S")" "1"
}

test_is_executable_bash
test_removes_default_site
test_never_opens_public_ports
test_verifies_config_before_finishing
finish
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-27-install-nginx.sh`
Expected: FAIL — script does not exist.

- [ ] **Step 3: Write the implementation**

Create `scripts/27-install-nginx.sh`:

```bash
#!/usr/bin/env bash
# 27-install-nginx.sh — host nginx for the Hermes UI proxy (loopback only).
#
# NOTE this is NOT 22-install-caddy-vhosts.sh's situation. That script needs
# :80+:443 open and grey-cloud DNS for Let's Encrypt and MUST be skipped on a
# cloudflared box. This one binds loopback only, opens no ports, and therefore
# runs on EVERY box, cloudflared or not.
set -euo pipefail

if ! command -v nginx >/dev/null 2>&1; then
  echo "==> installing nginx"
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx
else
  echo "==> nginx already installed"
fi

# The stock default site listens on :80 on all interfaces. Nothing should claim
# :80 on these boxes — the front door is cloudflared.
if [[ -e /etc/nginx/sites-enabled/default ]]; then
  echo "==> removing stock nginx default site (:80 catch-all)"
  sudo rm -f /etc/nginx/sites-enabled/default
fi

sudo systemctl enable nginx >/dev/null 2>&1 || true

if sudo nginx -t; then
  sudo systemctl restart nginx
  echo "==> nginx active: $(systemctl is-active nginx)"
else
  echo "27-install-nginx: FATAL — nginx -t failed; not restarting" >&2
  exit 1
fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-27-install-nginx.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/27-install-nginx.sh tests/test-27-install-nginx.sh
git commit -m "feat(hermes-ui): install host nginx, loopback only, no public ports"
```

---

### Task 4: Wire into `03-install-profile.sh`

**Files:**
- Modify: `scripts/03-install-profile.sh:174-180`

**Interfaces:**
- Consumes: Tasks 1-3.
- Produces: fresh provisions get the proxy on the same path that establishes the token.

- [ ] **Step 1: Read the current block**

Run: `sed -n '170,182p' scripts/03-install-profile.sh`
Expected: the step 6b block ending with the `ollie-orchestrator` restart.

- [ ] **Step 2: Make the edit**

Replace line 177 (`bash "${SCRIPT_DIR}/lib/ensure-dashboard-token.sh"`) with:

```bash
bash "${SCRIPT_DIR}/lib/ensure-dashboard-token.sh"
# ensure-dashboard-token.sh calls ensure-hermes-ui-proxy.sh itself, but only
# renders config — nginx must exist first or the reload is a no-op on a box
# that has never run 27.
bash "${SCRIPT_DIR}/27-install-nginx.sh"
bash "${SCRIPT_DIR}/lib/ensure-hermes-ui-proxy.sh"
```

- [ ] **Step 3: Verify ordering by inspection**

Run: `sed -n '170,186p' scripts/03-install-profile.sh`
Expected: `27-install-nginx.sh` runs **before** `ensure-hermes-ui-proxy.sh`, and both after `ensure-dashboard-token.sh`.

- [ ] **Step 4: Run the full shell suite**

Run: `for f in tests/test-*.sh; do echo "== $f"; bash "$f" 2>&1 | tail -2; done`
Expected: all green. Budget ~3 minutes; `test-24-install-agent-apps.sh` alone takes ~2m37s on Windows — that is normal, not a hang.

- [ ] **Step 5: Commit**

```bash
git add scripts/03-install-profile.sh
git commit -m "feat(hermes-ui): install the UI proxy during profile install"
```

---

### Task 5: Add to the `update hermes` runbook

**Files:**
- Modify: `templates/bin/ollie-fleetctl`
- Modify: `tests/test_fleetctl.py:360-366`

**Interfaces:**
- Consumes: Task 1's script path `scripts/lib/ensure-hermes-ui-proxy.sh`.
- Produces: step name `ensure-hermes-ui-proxy`, emitted last in the `update hermes` progress stream.

- [ ] **Step 1: Write the failing test**

In `tests/test_fleetctl.py`, extend the asserted list in `test_update_hermes_runs_runbook_in_order`:

```python
        self.assertEqual(steps, ["git-pull-install-repo", "reinstall-fleetctl",
                                 "hermes-update", "reinstall-cortex-plugin",
                                 "repatch-cron-brain", "reinstall-souls",
                                 "reinstall-identity-sync", "heal-dashboard-units",
                                 "ensure-hermes-ui-proxy"])
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest tests/test_fleetctl.py::TestUpdateHeartbeat::test_update_hermes_runs_runbook_in_order -v`
Expected: FAIL — actual list is missing the final element.

- [ ] **Step 3: Write the implementation**

In `templates/bin/ollie-fleetctl`, find the `update hermes` runbook list containing `"heal-dashboard-units"` and append an entry immediately after it, following the exact shape of the neighbouring entries (same tuple/dict form, same script-invocation convention). It must run `scripts/lib/ensure-hermes-ui-proxy.sh` and be named `ensure-hermes-ui-proxy`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `python -m pytest tests/test_fleetctl.py -v`
Expected: all pass, including the ordering test.

- [ ] **Step 5: Commit**

```bash
git add templates/bin/ollie-fleetctl tests/test_fleetctl.py
git commit -m "feat(hermes-ui): refresh the UI proxy on update hermes"
```

---

### Task 6: `check-box-config.sh` gate

**Files:**
- Modify: `scripts/check-box-config.sh` (new section 3b, immediately after the session-token loop that ends near line 84)
- Modify: `tests/test-check-box-config.sh`

**Interfaces:**
- Consumes: Task 1's file names and the `orch_val` / `pass` / `fail` helpers already defined at `check-box-config.sh:26-31`.
- Produces: PASS/FAIL lines `hermes-ui-proxy conf present (<agent>)` and `hermes-ui-auth matches orchestrator token`.

- [ ] **Step 1: Write the failing test**

Add to `tests/test-check-box-config.sh`, following the fixture style already used in that file:

```bash
test_ui_proxy_gate_passes_when_rendered() {
  local d; d="$(setup_box)"   # existing helper in this file
  mkdir -p "$d/nginx"
  printf 'proxy_set_header Authorization "Bearer %s";' "$(grep '^HERMES_DASHBOARD_TOKEN=' "$d/orch.env" | cut -d= -f2-)" \
    > "$d/nginx/hermes-ui-auth.conf"
  printf 'server { listen 127.0.0.1:9219; }\n' > "$d/nginx/hermes-ui-proxy-default.conf"
  local out
  out="$(ORCH_ENV="$d/orch.env" SYSTEMD_USER_DIR="$d/units" STACK_ENV_FILE="$d/stack.env" \
        NGINX_CONF_DIR="$d/nginx" NGINX_AUTH_FILE="$d/nginx/hermes-ui-auth.conf" \
        CHECK_SKIP_LIVE=1 bash "$CHECK" 2>&1)"
  assert_eq "ui-proxy conf PASS" "$(echo "$out" | grep -c 'PASS: hermes-ui-proxy conf present (default)')" "1"
  assert_eq "auth token PASS" "$(echo "$out" | grep -c 'PASS: hermes-ui-auth matches orchestrator token')" "1"
}

test_ui_proxy_gate_fails_on_stale_token() {
  local d; d="$(setup_box)"
  mkdir -p "$d/nginx"
  printf 'proxy_set_header Authorization "Bearer STALE-TOKEN";' > "$d/nginx/hermes-ui-auth.conf"
  printf 'server { listen 127.0.0.1:9219; }\n' > "$d/nginx/hermes-ui-proxy-default.conf"
  local out
  out="$(ORCH_ENV="$d/orch.env" SYSTEMD_USER_DIR="$d/units" STACK_ENV_FILE="$d/stack.env" \
        NGINX_CONF_DIR="$d/nginx" NGINX_AUTH_FILE="$d/nginx/hermes-ui-auth.conf" \
        CHECK_SKIP_LIVE=1 bash "$CHECK" 2>&1)"
  assert_eq "stale token FAILs" "$(echo "$out" | grep -c 'FAIL: hermes-ui-auth stale')" "1"
}

test_ui_proxy_gate_passes_when_rendered
test_ui_proxy_gate_fails_on_stale_token
```

Register both in the runner list at the bottom of the file.

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-check-box-config.sh`
Expected: FAIL — the new PASS/FAIL lines are not emitted.

- [ ] **Step 3: Write the implementation**

Add near the top of `check-box-config.sh`, beside the other path defaults (after line 23):

```bash
NGINX_CONF_DIR="${NGINX_CONF_DIR:-/etc/nginx/conf.d}"
NGINX_AUTH_FILE="${NGINX_AUTH_FILE:-/etc/nginx/hermes-ui-auth.conf}"
```

Then insert section 3b immediately after the session-token `for unit in ...` loop:

```bash
# 3b. Hermes UI proxy — one conf per dashboard unit, auth file matching the token.
for unit in "${UNIT_DIR}"/hermes-dashboard*.service; do
  name="$(basename "${unit}")"
  agent="${name#hermes-dashboard}"; agent="${agent%.service}"; agent="${agent#-}"
  [[ -z "${agent}" ]] && agent="default"
  if [[ -f "${NGINX_CONF_DIR}/hermes-ui-proxy-${agent}.conf" ]]; then
    pass "hermes-ui-proxy conf present (${agent})"
  else
    fail "hermes-ui-proxy conf missing (${agent})"
  fi
done

if [[ -f "${NGINX_AUTH_FILE}" ]]; then
  if [[ "$(cat "${NGINX_AUTH_FILE}" 2>/dev/null)" == "$(printf 'proxy_set_header Authorization "Bearer %s";' "${TOKEN}")" ]]; then
    pass "hermes-ui-auth matches orchestrator token"
  else
    fail "hermes-ui-auth stale (does not match HERMES_DASHBOARD_TOKEN — rerun ensure-dashboard-token.sh)"
  fi
else
  fail "hermes-ui-auth missing (${NGINX_AUTH_FILE})"
fi
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/test-check-box-config.sh`
Expected: PASS, including pre-existing cases.

- [ ] **Step 5: Commit**

```bash
git add scripts/check-box-config.sh tests/test-check-box-config.sh
git commit -m "feat(hermes-ui): gate the UI proxy in check-box-config"
```

---

### Task 7: Operator runbook

**Files:**
- Create: `docs/runbooks/hermes-ui-proxy.md`

**Interfaces:**
- Consumes: port convention and file names from Task 1.
- Produces: nothing code-facing.

- [ ] **Step 1: Write the runbook**

Create `docs/runbooks/hermes-ui-proxy.md`:

```markdown
# Reaching the native Hermes dashboard

The `<box>-hermes.jnow.io` hostnames are being retired. The native Hermes
dashboard is now reached over an SSH port-forward to a loopback proxy that
injects the session token for you.

## Connect

    ssh -o IdentityAgent=none -i <key> -L 9219:127.0.0.1:9219 ollie@<box>

Then open <http://127.0.0.1:9219>.

Ports are `dashboard port + 100`:

| Agent | Dashboard | Forward |
|---|---|---|
| default | 9119 | 9219 |
| second agent | 9121 | 9221 |

Confirm a box's ports with:

    grep -h -oE '\-\-port[= ]+[0-9]+' ~/.config/systemd/user/hermes-dashboard*.service

## Why the plain forward to 9119 does not work

Hermes 0.19.0 requires an `Authorization: Bearer <session token>` header on its
API routes. A browser cannot send one on navigation, there is no query-param or
cookie fallback, and `/login` is disabled. Forwarding 9119 directly gives you
the SPA shell over a 401 wall. The proxy exists to supply that header.

## Troubleshooting

**Everything 401s.** The auth file is stale or missing. Run
`bash ~/ollie-hermes-install/scripts/lib/ensure-dashboard-token.sh`, which
re-renders it, then retry.

**Chat or the events feed will not connect, but pages load.** The `Origin`
rewrite is missing or nginx did not reload. Check with `sudo nginx -t` and
`grep Origin /etc/nginx/conf.d/hermes-ui-proxy-*.conf`. Note that nginx logs a
WebSocket as `101` only when it CLOSES, so a working chat shows **no** 101 —
check for `pty accepted` in `~/.hermes/logs/` instead.

**Connection refused on the forward.** `systemctl is-active nginx` on the box.

## After rotating the dashboard token

`ensure-dashboard-token.sh` re-renders the proxy auth file automatically. Verify
with `bash ~/ollie-hermes-install/scripts/check-box-config.sh | grep hermes-ui`.
```

- [ ] **Step 2: Commit**

```bash
git add docs/runbooks/hermes-ui-proxy.md
git commit -m "docs(hermes-ui): operator runbook for the SSH-forwarded dashboard"
```

---

### Task 8: Frontend — role-gate the Backend Settings link *(separate repo)*

**Files:**
- Modify: `ollie-hermes-frontend/src/components/Layout.tsx:179-199`
- Test: `ollie-hermes-frontend/src/components/Layout.test.tsx` (create if absent)

**Interfaces:**
- Consumes: nothing from Tasks 1-7. Independent, bundled per the operator's request.
- Produces: `HermesDashboardLink` renders `null` unless `hermesUiUrl` is non-empty **and** the signed-in user is an operator.

⚠️ **Different repository.** `cd` to the frontend checkout. Do not commit this into `ollie-hermes-install`.

- [ ] **Step 1: Write the failing test**

Test that the component returns null when `hermesUiUrl` is empty (today it falls back to `http://<host>:9119`), and null for a non-operator role even when the URL is set. Follow the existing test conventions in that repo — check a neighbouring `*.test.tsx` for how `getBackendConfig` and the auth/role context are mocked, and mirror it rather than inventing a new pattern.

- [ ] **Step 2: Run test to verify it fails**

Run: `npm test -- Layout` in the frontend repo.
Expected: FAIL — the fallback currently produces a non-null href.

- [ ] **Step 3: Write the implementation**

Replace the body of `HermesDashboardLink` (currently lines 180-187) so that it:
- reads `cfg.hermesUiUrl` with **no** `|| http://${window.location.hostname}:9119` fallback
- returns `null` when that value is empty or the config throws
- returns `null` unless the current user's role is an operator role (use the same role source the app already uses for `account_admin` gating — do not introduce a second mechanism)

- [ ] **Step 4: Run tests to verify they pass**

Run: `npm test` in the frontend repo.
Expected: full suite green, not just the new file.

- [ ] **Step 5: Commit**

```bash
git add src/components/Layout.tsx src/components/Layout.test.tsx
git commit -m "fix(layout): role-gate Backend Settings and drop the dead :9119 fallback"
```

---

### Task 9: Sandbox acceptance — the real gate

**Files:** none. This is live verification.

⚠️ **Sandbox only** (`ollie@178.105.216.167`, key `~/.ssh/ollie_sandbox`). **Not Towns** — pilot pending. **Not prod** — live users.

- [ ] **Step 1: Deploy to sandbox**

```bash
ssh -o IdentityAgent=none -o IdentitiesOnly=yes -i ~/.ssh/ollie_sandbox ollie@178.105.216.167 \
  'cd ~/ollie-hermes-install && git pull --ff-only && bash scripts/27-install-nginx.sh && bash scripts/lib/ensure-hermes-ui-proxy.sh'
```
Expected: nginx active, two confs written (sandbox has multiple agents).

- [ ] **Step 2: Token injection works**

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:9219/api/files   # expect 200
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:9119/api/files   # expect 401
```
Both are required. The 401 proves the proxy is doing the work rather than Hermes being open.

- [ ] **Step 3: Second agent works**

Repeat Step 2 against the second agent's port. A single agent cannot exercise the discovery loop or the shared-`map` collision.

- [ ] **Step 4: WebSocket works — this is the surface that used to fail**

The `code=1006` failure was the **Hermes dashboard's own chat**, on the
`<box>-hermes.jnow.io` host — not the Ollie chat, which was never affected.
That surface is the exact thing this proxy restores, so this step is the
regression test for it.

Note the failure mode is now structurally impossible on this path rather than
merely fixed: the browser is talking to `127.0.0.1`, which carries no `jnow.io`
cookies at all, so the request cannot accumulate the ~27 KB of Supabase session
cookies that overflowed the handshake parser. Header size no longer scales with
how many boxes are signed in.

Forward the port, open chat in a browser, then on the box:
```bash
grep -h 'pty accepted' ~/.hermes/logs/*.log | tail -3
```
Expected: `pty accepted … mode=loopback cred=token`. Do **not** look for `101` in the nginx access log — nginx logs that only on close, so a working chat shows none.

- [ ] **Step 5: Rotation test — the one most likely to be skipped**

Rotate `HERMES_DASHBOARD_TOKEN` in `~/.config/ollie-orchestrator/.env`, re-run `ensure-dashboard-token.sh`, restart `ollie-orchestrator`, then repeat Steps 2-4. Also confirm the OLD token now 401s directly against 9119.

- [ ] **Step 6: Gate and durability**

```bash
bash ~/ollie-hermes-install/scripts/check-box-config.sh | grep hermes-ui   # expect PASS
sudo reboot   # then re-run Step 2 once back
```

- [ ] **Step 7: Record the acceptance result**

Append pass/fail per step to `.superpowers/sdd/progress.md` with the actual commands and output. If any step fails, STOP — do not roll out to prod or Towns.

---

## Rollout after acceptance

Not tasks — operator decisions requiring sign-off:

1. Sandbox soak, then prod, then Towns.
2. Bump `INSTALL_REPO_REF` in `ollie-fleet/src/server/enroll-core.ts:9` so newly provisioned boxes get this. It is pinned to `b55ba29` and is already several commits behind.
3. Task 8 needs a frontend image rebuild, a `FRONTEND_IMAGE` pin bump in `06-install-stack.sh`, and the S72-gated targeted `docker compose up -d dashboard` swap per box — verify `SUPABASE_URL` and `SUPABASE_ANON_KEY` are non-empty **first**.
4. Retire the `-hermes` hostnames fleet-wide once this is proven, and correct the stale "no auth of its own" comment at `generate-hermes-host.sh:4-5`.

## Self-review notes

- **Spec coverage:** ensure script → T1; rotation coupling → T2; nginx install and default-site removal → T3; `03-install-profile.sh` wiring → T4; `update hermes` wiring → T5; `check-box-config.sh` gate → T6; runbook → T7; the related `HermesDashboardLink` item → T8; every verification bullet → T9. The deferred public phase and the Unix-socket hardening are explicit non-goals and correctly have no task.
- **Type/name consistency:** `hermes-ui-auth.conf`, `hermes-ui-map.conf`, `hermes-ui-proxy-<agent>.conf`, `$hermes_ui_conn_upgrade`, `ensure-hermes-ui-proxy`, `NGINX_CONF_DIR`, `NGINX_AUTH_FILE`, `ENSURE_UI_PROXY_NO_RELOAD` are used identically in every task.
- **Known gap, accepted:** Task 5 Step 3 describes the fleetctl edit rather than quoting it, because the surrounding runbook-entry shape was not read during planning. The implementer must open the file and match the neighbouring entries. Same for Task 8 Step 3's role source. Both are marked in-task.
