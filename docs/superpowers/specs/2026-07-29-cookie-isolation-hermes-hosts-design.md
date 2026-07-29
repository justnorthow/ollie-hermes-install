# Cookie isolation for the Hermes backend hostnames — Design

**Date:** 2026-07-29
**Status:** Draft — awaiting review
**Scope:** How the native Hermes dashboard is exposed per box, and the fleet-wide
Supabase cookie domain that exposure currently forces.

## Problem

Every Ollie box sets `SUPABASE_COOKIE_DOMAIN=.jnow.io`, so each box's Supabase
session cookie is sent to **every** `*.jnow.io` host. Request header size
therefore grows linearly with the number of boxes an operator has signed into,
and components fail one by one as they cross their own limits.

Two failures on 2026-07-29, hours apart, same root cause:

| Symptom | Component | Limit crossed |
|---|---|---|
| Pop Bys tile flashed "Opening", then vanished | Node app server (`/apps/popbys/sso`) | Node default **16 KB** → HTTP 431 |
| Hermes chat `code=1006`, "events feed disconnected" | Hermes WS handshake (`/api/pty`) | handshake parser at **~27 KB** → HTTP 400 |

The second one is instructive. `tcpdump` on the box loopback showed the browser's
handshake arriving **intact** — `Sec-Websocket-Key: nsvirmCKDtLIFKfYYWA4nA==`,
`Upgrade: websocket`, `Connection: Upgrade`. Nothing stripped it. But the request
spanned ~27 KB because one `Cookie` header carried three boxes' sessions:

```
sb-sb-ollie-auth-token.0/.1          jnow prod
sb-sb-towns-auth-token.0/.1          Towns
sb-sb-olliesandbox-auth-token.0/.1   sandbox
+ sb-127-auth-token-code-verifier, _ga*, cf_clearance
```

`Sec-Websocket-Key` is sent *after* `Cookie`, so the parser gave up before
reaching it and reported it missing — which reads exactly like a proxy stripped
it. Deleting the two unrelated boxes' cookies fixed chat immediately
(`pty accepted peer=127.0.0.1 mode=loopback cred=token`).

Cost of the misleading error: an evening spent eliminating Cloudflare Access,
cache rules, cloudflared versions, Bot Fight Mode, HTTP/3, Workers Routes, zone
WebSockets, Managed Transforms, plan tier, plus a tunnel-route recreate and a
Hermes update. All irrelevant.

### Why the cookie is domain-wide at all

Exactly one reason. `towns.jnow.io` (dashboard) and `towns-hermes.jnow.io`
(native Hermes dashboard) are **siblings**, so a host-only cookie on the first is
not sent to the second, and the `-hermes` host reuses the same nginx Supabase
gate. `ollie-hermes-frontend/src/config.ts` says so directly:

> the Domain attribute for the Supabase session cookie, so the login is shared
> across sibling `*.jnow.io` hostnames — notably the dedicated Hermes-dashboard
> hostname, which reuses this same auth gate.

Nothing else depends on it.

### Second problem, same cause

`generate-hermes-host.sh` includes `/etc/nginx/auth.conf` (the Supabase gate) but
applies **no role check**. Combined with the domain-wide cookie, any user who
signs into a box's main dashboard can reach that box's native Hermes dashboard —
Files, Keys, Config, MCP, Skills, Logs.

Verified 2026-07-29: unauthenticated requests to `towns-hermes.jnow.io`,
`ollie-hermes.jnow.io` and `billie-hermes.getbilled.io` all return a bare `401`
from the origin, **not** a Cloudflare Access challenge. Despite the runbook
requiring an Access application, none of the three has one. So for a pilot
customer signing into their own box, this is a live exposure — not theoretical.

## Goals

1. Session cookies scoped to a single box (`Domain` unset ⇒ host-only).
2. Header size independent of how many boxes an operator has signed into.
3. Customer-side users cannot reach the native Hermes dashboard.
4. No regression to the Pop Bys tile, the SSO handoff, or operator access.

## Non-goals

- Reducing Supabase's own cookie size (chunked JWTs are upstream behaviour).
- Fixing the Hermes handshake parser's header limit (upstream).
- Reworking `/apps/*` tile SSO, which is orthogonal.

## Options

### A. Remove the public `-hermes` hostname; operators use SSH port-forward ✅ recommended

Delete the `<name>-hermes` tunnel route and DNS record. Operators reach the
dashboard over SSH:

```
ssh -o IdentityAgent=none -i <key> -L 9119:127.0.0.1:9119 ollie@<box>
# browse http://127.0.0.1:9119
```

- **Cookie domain:** can be unset immediately — the sibling host is gone.
- **Goal 3:** satisfied absolutely; there is no public path to reach.
- **Chat:** works today over loopback (verified: `101` + live TUI stream). It is
  also the only configuration where Hermes chat is *known* to work on a jnow box.
- **Code change:** none. Remove hostname, unset one env var, recreate dashboard.
- **Cost:** operators need SSH. Both current operators already SSH to these boxes
  daily.
- **Bonus:** removes the surface that consumed this entire investigation.

### B. Keep the hostname; gate it with Cloudflare Access instead of the Supabase cookie

Add a real Access application to each `-hermes` host (the runbook already assumes
one exists — it does not), then drop `include /etc/nginx/auth.conf` from the
hermes-host server block so no Supabase cookie is needed there.

- **Cookie domain:** can be unset.
- **Goal 3:** satisfied via the Access policy (`@jnow.io`).
- **Code change:** `generate-hermes-host.sh` in `ollie-hermes-frontend` needs a
  toggle to omit the auth include; new frontend image; redeploy per box.
- **Risk:** Access becomes the *only* gate. Must verify an unauthenticated
  request is challenged **before** removing the Supabase layer, not after — the
  script's own comment warns the block is "only as protected as the dashboard's
  configured auth."
- **Does not fix chat.** The 1006 returns as soon as an operator signs into a
  second box, because header size is unchanged for that hostname.

### C. Nest the hostnames

Serve the backend as `hermes.towns.jnow.io`, so `SUPABASE_COOKIE_DOMAIN=.towns.jnow.io`
covers the pair without leaking to other boxes.

- Architecturally cleanest; keeps the public hostname and the Supabase gate.
- **Blocked on cost:** two-level subdomains are not covered by Cloudflare
  Universal SSL; needs Advanced Certificate Manager. This is almost certainly why
  the fleet already standardises on single-level names (`sb-towns`, `towns-hermes`).
- Still no role check, so goal 3 needs separate work.

## Recommendation

**Option A.** It resolves all four goals, requires no code change, costs nothing,
and eliminates rather than mitigates the failure mode. B and C both keep a public
admin surface alive and leave chat broken for multi-box operators.

## Implementation (Option A)

Per box, in order:

1. **Announce** — operators lose the bookmark; hand them the SSH command first.
2. **Fleet** — clear the instance's *Hermes UI URL* field. `set-hermes-ui-url`
   with an empty value clears both `HERMES_UI_URL` and `HERMES_UI_HOSTNAME`,
   which makes `generate-hermes-host.sh` emit an empty conf (feature is off by
   default when unset).
3. **Cloudflare** — delete the `<name>-hermes` public hostname from the tunnel.
   Deleting the route removes the auto-created proxied CNAME.
4. **Cookie domain** — unset `SUPABASE_COOKIE_DOMAIN` in `~/hermes-stack/.env`.
   **Guard first:** `grep -cE '^(SUPABASE_URL|SUPABASE_ANON_KEY)=.+' ~/hermes-stack/.env`
   must return 2 — recreating the dashboard with either blank is the S72
   login-outage class.
5. **Recreate** the dashboard: `docker compose -f ~/hermes-stack/docker-compose.yml up -d --force-recreate dashboard`
6. **Operators re-sign-in** — existing cookies carry `Domain=.jnow.io` and are
   not retrofitted; they must be re-issued host-only. Old ones should be deleted
   from the browser or they keep inflating headers.

Then update, in `ollie-hermes-install`:

- `docs/runbooks/hermes-dashboard-cloudflare.md` — replace the publish procedure
  with the SSH-forward procedure, retaining the history of why.
- `scripts/check-box-config.sh` — the session-token drop-in gate still applies
  (the orchestrator proxy uses it); the `-hermes` hostname checks do not.

## Verification

- `curl -s https://<dashboard-host>/config.js | grep cookieDomain` → empty.
- Browser: exactly one `sb-sb-<box>-auth-token.*` pair present per host.
- Pop Bys tile still opens (SSO handoff is the largest remaining request).
- Hermes chat over the SSH forward: `~/.hermes/logs/*.log` shows
  `pty accepted … mode=loopback cred=token`. **Note:** nginx logs a WebSocket as
  `101` only when it *closes*, so an open, working chat shows no `101` — check
  the Hermes log or established connections on `:9119` instead.
- `https://<name>-hermes.jnow.io` no longer resolves.

## Rollback

Re-add the tunnel public hostname, restore `SUPABASE_COOKIE_DOMAIN=.jnow.io`,
recreate the dashboard, sign in again. Nothing is destroyed; the DNS record is
recreated automatically by re-adding the route.

## Open questions

1. **Joseph's access** — does removing the hostname fully close it, or does the
   dashboard SPA link to `hermesUiUrl` in a way that still leaks the target? The
   link renders from config and disappears when unset, but verify in-browser as
   the customer rather than assume.
2. **`HermesDashboardLink` role gate** — worth adding regardless
   (`ollie-hermes-frontend/src/components/Layout.tsx`), so the link is
   operator-only even if a hostname is published later.
3. **GetBilled** — `billie-hermes.getbilled.io` works today precisely because
   that zone carries one box's cookie. Same treatment for consistency, or leave
   it as the working reference?
4. **Header-limit belt and braces — resolved: do it in the install script.**
   `NODE_OPTIONS=--max-http-header-size=65536` is set by hand on Towns and
   sandbox Pop Bys. It should be a default in `23-install-app-server.sh` so
   every app server gets it on install.

   This matters more than it first appeared: a parallel workstream is making the
   Railway-hosted apps (HIA, and others) **portable onto each box** rather than
   multi-tenant. Those land through this same script, so setting the default now
   means every ported app inherits the fix and nobody rediscovers this per app.
   Setting `NODE_OPTIONS` on Railway for HIA is therefore throwaway work and
   probably not worth doing if the port is near.

   ⚠️ **Cross-session coordination:** that workstream touches
   `23-install-app-server.sh`, `24-install-agent-apps.sh` and the agent-apps
   manifests — the same files this change would edit. Sequence the two, or land
   the `NODE_OPTIONS` default *inside* that workstream rather than here, to avoid
   conflicting edits in a shared checkout.
