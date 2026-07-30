# Browser access to the native Hermes dashboard — Design

**Date:** 2026-07-30 (UTC; John's local evening of 2026-07-29)
**Status:** Design approved by John 2026-07-30 — awaiting spec review, then implementation plan
**Scope:** How an operator reaches the full native Hermes dashboard in a browser,
after the `<box>-hermes.jnow.io` public hostname was deleted.

## Problem

The `2026-07-29-cookie-isolation-hermes-hosts-design.md` work deleted the public
`<box>-hermes.jnow.io` hostname (executed on Towns 2026-07-30). That closed the
cookie-bloat problem at source, but it left operators with **no browser path to
the native Hermes dashboard at all**.

The fallbacks proposed at the time do not hold up:

- **`ssh -L 9119:127.0.0.1:9119` then browse `http://127.0.0.1:9119`** — does not
  work. Hermes 0.19.0 requires an `Authorization: Bearer <session token>` header
  on its API routes; a browser cannot send one on navigation. Measured on Towns:
  no credential, a bogus token, a genuine loopback peer, four query-param forms
  (`?token=`, `?session_token=`, `?access_token=`, `?key=`) and five cookie-name
  variants ALL return **401**. `/login` serves "Sign-in unavailable". The port
  forward yields the SPA shell over a 401 wall.
- **"Use the Ollie UI's gated agent settings."** `AgentManagementClient` wraps a
  fixed ~20 methods (skills, cron, config, env, logs, usage, model, profiles,
  plugins, memory providers, oauth). The native dashboard exposes considerably
  more — including a Files browser with no equivalent at all — and it grows with
  every Hermes release. Chasing parity is a treadmill.
- **"Use the `hermes` CLI over SSH."** Rejected by John: these are UI-shaped
  configuration surfaces and a terminal is not an acceptable substitute.

## Goals

1. Full native Hermes dashboard, in a browser, including surfaces the Ollie UI
   does not wrap.
2. Zero public admin surface — nothing a pilot customer on the box can reach.
3. No reintroduction of a fleet-wide Supabase cookie domain.
4. Survives `update hermes`, reprovisions, reboots, and token rotation.
5. Automatically covers new agents, without a hand-maintained port registry.

## Non-goals

- The public/remote access phase. Deliberately deferred to its own spec; see
  *Deferred: the public phase*.
- Per-user identity **inside** Hermes. A shared session token means everyone who
  reaches the proxy gets full Hermes admin. Not solvable without upstream
  support, and explicitly accepted for the local phase.
- Reaching parity in the Ollie UI. This design removes the need.

## Chosen approach

**A token-injecting reverse proxy, bound to loopback on the box, one listener per
agent dashboard, shipped in `ollie-hermes-install` and implemented with nginx
installed on the host.** Operators reach it over an SSH port-forward.

```
browser → ssh -L 9219:127.0.0.1:9219 → box 127.0.0.1:9219
                                            │  hermes-ui-proxy (host nginx)
                                            │   + Authorization: Bearer <session token>
                                            │   + Host:   127.0.0.1:9119
                                            │   + Origin: http://127.0.0.1:9119
                                            ↓
                                       127.0.0.1:9119   native Hermes dashboard
```

### Why the header rewrites are all mandatory

Learned the hard way in June 2026 and documented in the working
`hermes-host.conf`; none is optional:

| Header | Why |
|---|---|
| `Authorization: Bearer <token>` | Without it every API route 401s. This is the line the deleted hermes-host block was missing — it *cleared* `Authorization` and injected nothing. |
| `Host` → `127.0.0.1:9119` | Hermes validates Host on every request and returns 400 (`"Invalid Host header"`) otherwise. |
| `Origin` → `http://127.0.0.1:9119` | Hermes CSRF-checks Origin on `/api/ws`, `/api/events` and `/api/pty`. Without it those 403 and the chat/events/log streams silently never connect, while ordinary GETs look fine. |

Plus WebSocket upgrade passthrough, `proxy_buffering off`, and long
read/send timeouts, or streaming endpoints appear to hang.

### Ports

Listener port = upstream dashboard port **+ 100**: `9119 → 9219` (default agent),
`9121 → 9221` (real-estate). Derived from the ports already in the
`hermes-dashboard*.service` units, so there is no registry to keep in sync and new
agents are covered automatically.

### Binding

TCP on `127.0.0.1` only. Nothing binds a public interface; SSH is what bridges the
operator's machine to the box. No DNS record, no tunnel route, no cookie
involvement.

## Rejected alternatives

**Extend `generate-hermes-host.sh` in the frontend image.** Reuses tested
machinery and would make the later public phase a config flip. Rejected because
it requires passing `HERMES_DASHBOARD_SESSION_TOKEN` **into the dashboard
container**, where it does not currently live. That permanently widens the blast
radius of a container compromise — today a compromised frontend container can
proxy to Hermes but cannot authenticate to it. Paying a permanent security cost
for a convenience is the wrong trade, and the chosen approach keeps the token on
the host beside systemd where it already is, including for the future public
phase.

**Extend the orchestrator to serve the whole dashboard.** Architecturally the
best home: the orchestrator already holds the token and already enforces
`account_admin` on `/v1/agents/{id}/dashboard/{subpath}`, and serving under the
main host would be same-origin, avoiding every cookie problem and working
publicly and locally at once. Rejected for now on a concrete blocker: **the
Hermes SPA loads assets by absolute path** (`src="/assets/index-DlCSsYR-.js"`,
verified on the box), which is exactly why a dedicated hostname-at-root exists.
Served under `/hermes/<agent>/` those requests collide with the Ollie SPA's own
`/assets/`. Resolving it needs `sub_filter` rewriting of Hermes' HTML and JS —
fragile, and liable to break unpredictably on Hermes upgrades. Worth
prototyping before the public phase; not worth blocking on now.

## Implementation

### New: `scripts/lib/ensure-hermes-ui-proxy.sh`

Shaped after the existing `ensure-dashboard-token.sh`:

1. Read `HERMES_DASHBOARD_TOKEN` from `~/.config/ollie-orchestrator/.env` — the
   same single source of truth the systemd drop-ins use.
2. Discover agent dashboards and their ports by parsing `--port` out of
   `~/.config/systemd/user/hermes-dashboard*.service`.
3. Write `/etc/nginx/hermes-ui-auth.conf` — root-owned, mode 600, containing one
   line:
   `proxy_set_header Authorization "Bearer <token>";`
4. Render `/etc/nginx/conf.d/hermes-ui-proxy-<agent>.conf` per agent, each
   `include`ing the auth file.
5. **Compare-then-write**; `systemctl reload nginx` only when something changed.

Step 3 deliberately mirrors the `cortex-auth.conf` pattern already in the
frontend container: the secret lives in one small file that rotation rewrites,
rather than being embedded across larger configs.

### nginx on the host

An apt package install. The install step must **disable nginx's default `:80`
site**, since these are cloudflared boxes with a ":22 only" posture and nothing
should claim `:80`. This is a smaller version of the hazard documented for
`22-caddy` (which apt-installs Caddy, needs `:80`+`:443` open and grey-cloud DNS,
and must be skipped on a cloudflared box) — the difference is that our listeners
bind loopback only and never need inbound ports.

### Privilege

`ensure-dashboard-token.sh` runs as `ollie` and writes only under `$HOME`. This
script additionally writes `/etc/nginx/**` and reloads nginx, so those specific
operations run via `sudo`. The `ollie` user has passwordless sudo (verified on
Towns with `sudo -n true`). The script must fail loudly, not silently skip, if
`sudo -n` is unavailable — a half-applied proxy that 401s is worse than one that
was never installed.

### Wiring

- **`03-install-profile.sh`**, which already calls `lib/ensure-dashboard-token.sh`,
  so fresh provisions get the proxy on the same path that establishes the token.
- **The `update hermes` heal step**, next to the existing `heal-dashboard-units`,
  so updates cannot strand it.
- **`check-box-config.sh`**: new gate asserting the per-agent conf exists and
  matches expected, `/etc/nginx/hermes-ui-auth.conf` matches the orchestrator's
  current token, nginx is active, and the proxy answers 200 on `/api/files`.

nginx itself is installed by a new step in the same install path. It is **not**
added to `22-caddy-*`, which is skipped entirely on cloudflared boxes — this must
run on every box, cloudflared or not.

⚠️ **`XDG_RUNTIME_DIR=/run/user/1000` must be set** when this or any sibling
script touches `systemctl --user`, or it fails with "Failed to connect to bus: No
medium found." This has bitten the dashboard-token script before.

### Token rotation

The token appears in nginx config, so a rotation that does not re-render it
silently breaks the proxy. **`ensure-dashboard-token.sh` calls
`ensure-hermes-ui-proxy.sh` at its end**, guarded to no-op when the proxy is not
installed. One source of truth, and drift becomes impossible rather than merely
unlikely.

This is not hypothetical: the token was rotated on Towns on 2026-07-30 after
being leaked into a session transcript, by editing the orchestrator `.env` and
re-running `ensure-dashboard-token.sh`. That exact procedure must keep the proxy
working.

## Security boundary

Stated plainly, because it does shift.

Today a local process on the box must **read the mode-600 drop-in** to reach the
Hermes admin surface. After this change, any local process only needs to connect
to `127.0.0.1:9219` — no credential at all.

On a single-tenant box where the `ollie` user already has passwordless sudo
(verified on Towns), this is not a meaningful escalation for anyone who already
has a shell. It is nonetheless a real reduction in defense-in-depth, and it is
recorded here rather than glossed.

**Accepted for the local phase. Must be revisited for the public phase**, where
the outer gate stops being "has SSH to this box."

### Hardening to evaluate later, not in v1

Have nginx `listen unix:/run/hermes-ui-proxy/<agent>.sock` (mode 0600) instead of
a TCP port, forwarded with `ssh -L 9219:/run/hermes-ui-proxy/default.sock`. Then
no TCP port exists on the box at all and reachability is filesystem-permission
scoped. Deferred because Windows OpenSSH client support for Unix-socket
forwarding needs confirming first, and John's workstation is Windows 11.

## Verification

**Sandbox first. Not Towns — it has a pilot pending.**

1. `curl -o /dev/null -w '%{http_code}' http://127.0.0.1:9219/api/files` → **200**.
   Proves injection. The same call direct to `:9119` must still return 401.
2. `curl http://127.0.0.1:9219/` → 200, serves the SPA.
3. **WebSocket check.** Open chat through the forward and confirm
   `pty accepted … mode=loopback cred=token` in `~/.hermes/logs/`. Do **not**
   look for a `101` in the nginx access log — nginx logs a WebSocket as `101`
   only when it *closes*, so a working chat shows none.
4. **Rotation test.** Rotate `HERMES_DASHBOARD_TOKEN`, re-run
   `ensure-dashboard-token.sh`, then repeat 1–3. This is the test that catches
   the drift bug and the one most likely to be skipped.
5. `check-box-config.sh` passes the new gate.
6. Unit survives a reboot and an `update hermes`.
7. Second agent (`real-estate` on `:9221`) works, not just the default — a single
   agent cannot exercise the discovery loop.

Shim tests on the ensure script prove only what text it emits. That is precisely
how a fake `.env` fixture carried the `PGRST_DB_SCHEMAS` fiction through three
tasks and two reviews in the 2026-07-29 stage-1 work. **The sandbox run is the
real gate.**

## Deferred: the public phase

Remote/bookmarkable access is a separate spec. Its central problem is not
plumbing but authorization: injecting a shared token means anyone past the outer
gate gets full Hermes admin, so the gate must carry real identity. Likely shape
is Cloudflare Access in front of a hostname that proxies to *this* service —
which keeps the token on the host and out of the container, the same property
that decided the local design. The `generate-hermes-host.sh` comment claiming the
dashboard has "no auth of its own" (lines 4-5) is stale since the June 2026
hardening and must be corrected as part of that work.

## Related open items

- `HermesDashboardLink` (`ollie-hermes-frontend/src/components/Layout.tsx:185`)
  falls back to `http://<host>:9119` when `hermesUiUrl` is empty, so clearing the
  field leaves a dead link visible to every signed-in user — including pilot
  customers. One commit: role-gate the link and drop the fallback. Once this
  design ships, that link has a correct target again only for operators, so the
  role gate is still required.
- jnow prod and sandbox still set `SUPABASE_COOKIE_DOMAIN=.jnow.io`; the
  header-bloat fix is not complete until they are done too.
