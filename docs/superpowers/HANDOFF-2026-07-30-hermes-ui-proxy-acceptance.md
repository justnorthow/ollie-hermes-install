# HANDOFF — Hermes UI proxy: sandbox acceptance run

**Written:** 2026-07-30, end of the build session.
**For:** a fresh session with no memory of the build.
**Your job:** run the acceptance on the **sandbox only**, then report. Nothing is deployed yet.

---

## 1. Why this exists

Retiring the public `<box>-hermes.jnow.io` hostname (cookie-isolation work, same night) left
operators with **no browser path to the native Hermes dashboard**. A plain `ssh -L` to 9119
does not work: **Hermes 0.19.0 requires an `Authorization: Bearer <session token>` header**
that a browser cannot send on navigation — no query-param fallback, no cookie fallback,
`/login` disabled. Measured directly on Towns, all forms returned 401; only the bearer header
returned 200.

This branch adds a **token-injecting nginx reverse proxy on the host, bound to loopback**, one
listener per agent dashboard at **upstream port + 100** (`9119→9219`, `9121→9221`), reached
over an SSH forward. The token stays on the host beside systemd and never enters a container.

John currently has **no Hermes dashboard chat on any box** until this ships. That is the
functional gap being closed.

Design spec: `docs/superpowers/specs/2026-07-30-hermes-dashboard-browser-access-design.md`
Plan: `docs/superpowers/plans/2026-07-30-hermes-ui-proxy.md` (Task 9 is the acceptance)
Full build ledger: `.superpowers/sdd/2026-07-30-hermes-ui-proxy/progress.md`

---

## 2. State — read before touching anything

**Code is complete, reviewed, pushed. NOT deployed. No box has been touched.**

| What | Where |
|---|---|
| Main branch | `ollie-hermes-install` **`feat/hermes-ui-proxy`**, 16 commits, base `0cfb52a`, HEAD `32d0637` — pushed |
| Frontend companion | `ollie-hermes-frontend` **`feat/hermes-dashboard-link-gate`**, `a42d4ff` — pushed |
| Local worktree | `D:\ohi-hermes-ui` |
| Suites at HEAD | proxy 39/39 · check-box-config 70/70 · 27-install-nginx 10/10 · pytest 106 pass / 1 **pre-existing** fail |

The 1 pytest failure is `test_update_hermes_pipes_yes_into_hermes_update`. It fails identically
at the branch base `0cfb52a` — pre-existing, out of scope, do not try to fix it.

### What the branch contains

- `scripts/lib/ensure-hermes-ui-proxy.sh` — discovers `hermes-dashboard*.service` units, derives
  ports, renders `hermes-ui-auth.conf` (mode 600, the bearer line), a single shared
  `hermes-ui-map.conf`, and one `hermes-ui-proxy-<agent>.conf` per agent. Compare-then-write;
  reloads nginx only on change; **a failed reload is fatal**.
- `scripts/27-install-nginx.sh` — installs nginx, removes the stock `:80` default site, uses
  `reload-or-restart` behind an `nginx -t` gate.
- `scripts/lib/ensure-dashboard-token.sh` — now calls the proxy script **before** the
  `ENSURE_TOKEN_NO_RESTART` early exit, so rotation can never drift.
- `scripts/03-install-profile.sh` + `scripts/05-install-orchestrator.sh` — both install nginx
  before the token script. **05 matters most: `03` is optional (README step 5) and a default
  single-profile box never runs it.**
- `templates/bin/ollie-fleetctl` — `update hermes` runbook gained `install-nginx` then
  `ensure-hermes-ui-proxy`; `_create_dashboard_unit` now renders the proxy for new agents.
- `scripts/check-box-config.sh` — new gate sections 3b (files/content) and 3c (liveness, behind
  `CHECK_SKIP_LIVE`).
- `docs/runbooks/hermes-ui-proxy.md` — operator instructions.

---

## 3. Access

```bash
# SANDBOX — the only box you may touch
ssh -o IdentityAgent=none -o IdentitiesOnly=yes -i ~/.ssh/ollie_sandbox ollie@178.105.216.167
```

The **same** `~/.ssh/ollie_sandbox` key also opens Towns (`ollie@204.168.152.243`) and Fleet
(`root@167.233.35.141`). That is not documented anywhere else — the Obsidian SSH doc has the
Towns IP but no key body.

> 🚫 **DO NOT touch Towns** — Joseph Towns' pilot box.
> 🚫 **DO NOT touch jnow prod** (`46.224.81.84`) — live users.
> 🚫 **DO NOT touch GetBilled** (`74.208.207.91`).

### Getting the branch onto the sandbox

⚠️ **`git pull` will NOT get you this branch.** Fleet pins `INSTALL_REPO_REF` to `b55ba29`
(`ollie-fleet/src/server/enroll-core.ts:9`) and **detaches** each box's `~/ollie-hermes-install`
to that ref. You must check out explicitly:

```bash
cd ~/ollie-hermes-install
git fetch origin feat/hermes-ui-proxy
git checkout feat/hermes-ui-proxy
git log --oneline -1        # expect 32d0637
```

**Record the ref it was on first** (`git rev-parse HEAD`) so you can restore it.

---

## 4. The acceptance run

Sandbox has multiple agents already (`real-estate`, `olivia-marketing`, `prospecting-agent`),
which satisfies the two-agent requirement natively — **one agent cannot exercise the discovery
loop or the duplicate-`map` nginx hazard.**

### 4.1 Install

```bash
bash scripts/27-install-nginx.sh
bash scripts/lib/ensure-hermes-ui-proxy.sh
systemctl is-active nginx
ls -l /etc/nginx/conf.d/hermes-ui-*.conf /etc/nginx/hermes-ui-auth.conf
```
Expect: nginx active, one `hermes-ui-proxy-<agent>.conf` per dashboard unit, exactly **one**
`hermes-ui-map.conf`, auth file **mode 600 root-owned**.

### 4.2 Token injection works — the core claim

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:9219/api/files   # expect 200
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:9119/api/files   # expect 401
```
**Both are required.** The 401 proves the proxy is doing the work rather than Hermes being open.
Repeat for the second agent's port (`upstream + 100`).

### 4.3 File modes — never once executed in any test

Every mode assertion **SKIPs on the Windows dev box** (NTFS has no POSIX modes), so mode
enforcement is proven only by argument until now. The sandbox is Linux:

```bash
stat -c '%a %U %n' /etc/nginx/hermes-ui-auth.conf        # expect 600 root
sudo chmod 644 /etc/nginx/hermes-ui-auth.conf
bash scripts/lib/ensure-hermes-ui-proxy.sh               # must NOT print "wrote ..."
stat -c '%a %n' /etc/nginx/hermes-ui-auth.conf           # expect 600 again
```
A mode-only correction must restore 600 **without** a content write and therefore without an
nginx reload.

### 4.4 No-op rerun

```bash
bash scripts/lib/ensure-hermes-ui-proxy.sh   # expect "done (changed=0)"
systemctl show nginx -p ActiveEnterTimestamp # unchanged across the rerun
```

### 4.5 WebSocket — the surface that used to fail

The `code=1006` failure was the **Hermes dashboard's own chat**, not the Ollie chat (Ollie chat
was never affected — do not use it as a regression test). Forward the port from your machine:

```bash
ssh -o IdentityAgent=none -i ~/.ssh/ollie_sandbox -L 9219:127.0.0.1:9219 ollie@178.105.216.167
# browse http://127.0.0.1:9219, open chat
```
Then on the box:
```bash
grep -h 'pty accepted' ~/.hermes/logs/*.log | tail -3   # expect: mode=loopback cred=token
```
⚠️ **Do NOT look for a `101` in the nginx access log.** nginx logs a WebSocket as `101` only
when it **CLOSES**, so a working chat shows none. This cost a previous session hours.

### 4.6 Token rotation

```bash
# rotate
python3 -c 'import secrets; print(secrets.token_urlsafe(32))'   # put in orchestrator .env
# then
XDG_RUNTIME_DIR=/run/user/1000 bash scripts/lib/ensure-dashboard-token.sh
systemctl --user restart ollie-orchestrator
```
Re-run 4.2 and 4.5. The **old** token must now 401 directly against 9119.
`XDG_RUNTIME_DIR` is required or it fails "Failed to connect to bus: No medium found".

### 4.7 The gate — run it as `ollie`, NOT root

```bash
OPERATOR_EMAIL=jb@jnow.io bash scripts/check-box-config.sh | grep hermes-ui
```
Expect `PASS` for each conf and `PASS: hermes-ui-auth matches orchestrator token`.

⚠️ **Running as root hides the bug this check exists for.** The final review found the gate read
a root-owned mode-600 file as `ollie`, silently got empty, and reported `stale` on every healthy
box — sending operators into a loop that could not converge. It now does a privileged read. This
step is the only thing that verifies that fix on a real filesystem.

### 4.8 Negative liveness — gate must FAIL

```bash
sudo systemctl stop nginx
OPERATOR_EMAIL=jb@jnow.io bash scripts/check-box-config.sh | grep hermes-ui   # expect FAIL
sudo systemctl start nginx
```
The gate previously **failed open** here: correct files plus a dead nginx reported PASS.

### 4.9 Forced reload failure — must be fatal

Break the nginx config out-of-band, rotate the token, re-run `ensure-dashboard-token.sh`.
The proxy script must **exit non-zero** and the gate must FAIL. If it degrades to a warning,
nginx keeps serving the **pre-rotation** token indefinitely while the gate says healthy —
the permanent-401 scenario this design exists to prevent. Restore the config afterwards.

### 4.10 New agent via the API, not script 03

```bash
ollie-fleetctl agents create ...        # NOT 03-install-profile.sh
ls /etc/nginx/conf.d/hermes-ui-proxy-*.conf   # the new agent must appear
```

### 4.11 ⭐ THE UPGRADE PATH — most important, and easiest to skip

`update hermes` on a box provisioned **before** this branch is the only step that would have
caught the Critical that would otherwise have broken updates on **all four boxes at once**:
the update runbook called the proxy script but nothing on that path installed nginx, so
`nginx -t` was command-not-found, the script exited 1, and `cmd_update` aborted the whole update.

```bash
ollie-fleetctl update hermes
```
Must complete, and the progress stream must show `install-nginx` **before**
`ensure-hermes-ui-proxy`.

### 4.12 Durability

```bash
sudo reboot
# after it returns, repeat 4.2
```

---

## 5. Known landmines

- **`test-check-box-config.sh` takes ~4.5 minutes.** It is SLOW, not hung. Two caps at 60s and
  120s during the build looked exactly like an infinite loop. Never cap below 6 minutes; redirect
  to a file rather than piping to `tail`.
- **Never run the shell suites concurrently** — that produced a false flake in `test-23`.
- **Do not benchmark under concurrent load.** A runtime "regression" during the build was inflated
  by background agents; controlled repeats disagreed.
- **`XDG_RUNTIME_DIR=/run/user/1000`** for anything touching `systemctl --user`.
- **The container's nginx and the host's nginx are different instances.** `generate-hermes-host.sh`
  renders inside the dashboard *container*; this proxy is *host* nginx. They do not conflict.
- Sandbox still has `HERMES_UI_HOSTNAME=olliesandbox-hermes.jnow.io` set, so that public host
  returns a fail-closed 401. That is expected and unrelated.

## 6. If something fails

**Stop. Do not roll forward to Towns or prod.** Record what failed with the actual command and
output, append it to `.superpowers/sdd/2026-07-30-hermes-ui-proxy/progress.md`, and report.

Rollback on the sandbox:
```bash
cd ~/ollie-hermes-install && git checkout <the ref you recorded in §3>
sudo rm -f /etc/nginx/conf.d/hermes-ui-*.conf /etc/nginx/hermes-ui-auth.conf
sudo systemctl reload-or-restart nginx
```
Nothing in this branch modifies Supabase, agent data, or the dashboard container.

## 7. After acceptance passes

Not yours to do without John's say-so:
1. Merge both branches (`superpowers:finishing-a-development-branch`).
2. **Bump `INSTALL_REPO_REF`** in `ollie-fleet/src/server/enroll-core.ts:9` — pinned to `b55ba29`
   and several commits behind; until it moves, newly provisioned boxes do not get this.
3. Frontend needs an image rebuild, a `FRONTEND_IMAGE` pin bump in `06-install-stack.sh`, and the
   S72-gated `docker compose up -d dashboard` swap per box — **verify `SUPABASE_URL` and
   `SUPABASE_ANON_KEY` are non-empty first**.
4. Then Towns, then prod.
5. Retire the `-hermes` hostnames fleet-wide and fix the stale "no auth of its own" comment at
   `generate-hermes-host.sh:4-5`.

## 8. Two parked findings — real, deliberately not fixed

- `_create_dashboard_unit` discards `run_cmd`'s rc, so a fatal proxy render during
  `agents create` is silent. The gate catches it next run and fails closed.
- Provisioning now hard-fails if a future Hermes changes `/api/files`' path or status. Accepted:
  it is what the spec asked the gate to assert, and fail-open is the worse failure.

## 9. One habit worth carrying in

**Six of the defects in this build were in the plan, not the implementations** — every one from
reasoning about a written artifact instead of checking the running system. The two Criticals were
found only by the final whole-branch review, and one was invisible to the entire test suite.

Before believing any check here passes: confirm it would fail if the thing it tests were broken.
