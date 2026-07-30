# Cookie isolation for the Hermes backend hostnames — Design

**Date:** 2026-07-29
**Status:** **DECIDED 2026-07-29 — Option A.** John's call. Rollout: Towns first
(before Joseph authenticates), then jnow prod + sandbox. GetBilled deferred.
Three corrections found during the decision review are folded in below and
marked ⚠️ CORRECTED.
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

⚠️ **CORRECTED 2026-07-29 (decision review) — the `-hermes` hostname is the ONLY
path to the management surface, which makes deleting it worth more than this
section claimed.** The main dashboard host already blocks that surface:
`ollie-hermes-frontend/nginx.conf:48-62` returns 403 for
`/hermes-proxy/api/sessions` and for
`/hermes-proxy/api/(skills|cron|config|env|model|profiles|logs|analytics|dashboard/plugins|dashboard/plugin-providers|providers/oauth)`.
Those regex blocks are matched in file order and outrank the `/hermes-proxy/`
prefix block, so a signed-in member on the main host gets 403 on all of them.
`generate-hermes-host.sh` builds a **separate server block** publishing the
dashboard at `/` with none of those guards — it bypasses every one.

⚠️ **UNVERIFIED, and no option here closes it:** `/api/files` is not in that
blocklist. If the Hermes Files tab reads it, it is reachable through
`/hermes-proxy` on the MAIN host today by any signed-in user. Check on a box
before assuming goal 3 is fully met.

Verified 2026-07-29: unauthenticated requests to `towns-hermes.jnow.io`,
`ollie-hermes.jnow.io` and `billie-hermes.getbilled.io` all return a bare `401`
from the origin, **not** a Cloudflare Access challenge. Despite the runbook
requiring an Access application, none of the three has one.

🛑 **CORRECTED 2026-07-30 by direct measurement on Towns — "this is a live
exposure" was WRONG, and the whole section overstates the severity.** Hermes
0.19.0 requires a **bearer session token** for its management surface. Measured
against `127.0.0.1:9119` on the Towns box:

| Attempt | `/api/files`, `/api/env`, `/api/skills`, `/api/config` |
|---|---|
| no credential | **401** |
| bogus bearer token | **401** |
| genuine loopback peer, no token | **401** |
| `?token=` / `?session_token=` / `?access_token=` / `?key=` | **401** |
| 5 cookie-name variants | **401** |
| `Authorization: Bearer <HERMES_DASHBOARD_SESSION_TOKEN>` | **200** |

`/login` serves *"Sign-in unavailable — Hermes Agent"*, and `hermes dashboard
--insecure` is now documented as *"DEPRECATED / NO-OP … as of the June 2026
hardening it no longer disables authentication."*

**And the hermes-host nginx block explicitly strips the credential**
(`proxy_set_header Authorization "";`) while injecting none of its own. So a
signed-in customer reaching `<box>-hermes.jnow.io` gets the SPA shell and **401
on every management call**. They cannot read Files, Keys, Config, MCP, Skills or
Logs.

**Where this spec's error came from:** `generate-hermes-host.sh:4-5` still
describes the dashboard as *"loopback 127.0.0.1:9119, no auth of its own"* —
true when written in June, falsified by the June 2026 hardening and 0.19.0. The
comment was never updated and this spec inherited it. Same stale assumption
behind the 2026-07-28 session-token bug: that was this identical 401 wall
surfacing on the orchestrator path.

**Consequence for priority:** Joseph onboarding was gated on this as a live
admin exposure. It is not one. That gate is lifted. Removing the hostname
remains correct — a redundant public surface, and removing it is what permits
unsetting the cookie domain — but it is hygiene plus the header fix, not an
incident response.

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

🛑 **CORRECTED 2026-07-30 — the SSH port-forward does NOT give browser access.**
Per the measured table above, a browser at `http://127.0.0.1:9119` over the
forward hits the identical 401 wall: it cannot send an `Authorization: Bearer`
header, there is no query-param or cookie fallback, and `/login` is disabled.
**The operator path in this option as originally written does not work.**

The admin path that DOES work, and is already correctly gated, is the
orchestrator's `/v1/agents/{agent}/dashboard` proxy — it injects the token
server-side behind an `account_admin+` check, and it is what `nginx.conf:52-62`
routes the management surface to. That is the 2026-07-28 fix
(`0d8caf5` / `12e69e5`). Second path: the `hermes` CLI on the box over plain
SSH. Neither needs a public hostname. **Option A's step 1 should read "operators
use the Ollie UI's gated admin surface, or the CLI over SSH" — not the
port-forward.**

- **Cookie domain:** can be unset immediately — the sibling host is gone.
- **Goal 3:** satisfied absolutely; there is no public path to reach. (Note it
  was already satisfied in practice by the bearer-token requirement.)
- **Code change:** none. Remove hostname, unset one env var, recreate dashboard.
- **Cost:** operators lose a browser bookmark that was already returning 401s on
  every management call. Real admin access is unaffected — it runs through the
  orchestrator proxy inside Ollie.
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
- ⚠️ **CORRECTED:** the original draft said "does not fix chat — header size is
  unchanged," which contradicts this option's own first bullet. If the cookie
  domain is unset (which B allows, since Access replaces the Supabase gate on
  this host), cookies become host-only and the bloat goes away under B too.
  **B's honest downsides are cost and single-gate risk, not chat.**
- **Cost/availability caveat:** the 2026-06-27 decision to reuse the Supabase
  gate instead of Access was made because Access "requires a paid plan John
  won't use." Re-verify current plan coverage before choosing B.

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

1. ⚠️ **ANSWERED 2026-07-29 — and the answer is NO, the link does not
   disappear.** `ollie-hermes-frontend/src/components/Layout.tsx:185` reads
   `href = cfg.hermesUiUrl || \`http://${window.location.hostname}:9119\``, and
   the component returns `null` only when `href === '#'` (i.e. only if
   `getBackendConfig()` throws). With config present and `hermesUiUrl` cleared,
   it falls back to `http://<box>.jnow.io:9119`. **Security impact: nil** — 9119
   is loopback-bound, host-firewalled, and has no tunnel route. **Pilot-UX
   impact: real** — Joseph sees a "Backend Settings" link that dead-ends.
   The other half of step 2 IS correct: `generate-hermes-host.sh:23` early-exits
   and emits an empty conf when `HERMES_UI_HOSTNAME` is unset.
2. **`HermesDashboardLink` role gate — now required, not optional.** Because of
   (1), Option A leaves a visibly broken link for customer-side users. Fold both
   into one commit in `ollie-hermes-frontend/src/components/Layout.tsx`:
   role-gate the link to operators AND drop the `:9119` fallback so it renders
   nothing when `hermesUiUrl` is unset. Not a blocker for the Towns rollout
   (the link is dead, not dangerous) — ship it with the next frontend deploy.
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
