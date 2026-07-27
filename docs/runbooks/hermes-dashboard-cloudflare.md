# Expose a box's Hermes dashboard (Backend Settings link)

The native Hermes dashboard binds `127.0.0.1:9119` (loopback, no auth). To make
the frontend's "Backend Settings" link work, publish it at the root of a
dedicated, Access-gated Cloudflare hostname. `cloudflared` runs on the host, so
it reaches the loopback dashboard directly; serving at the hostname root keeps
the dashboard's absolute `/assets/...` paths working.

Per box (example values for `ollie.jnow.io` → hostname `ollie-hermes.jnow.io`):

1. **Confirm Hermes is on loopback:** `ss -tlnp | grep 9119` shows
   `127.0.0.1:9119` and the service is not restart-looping. (Boxes built before
   this change need the loopback unit fix — `systemctl --user restart
   hermes-dashboard` after the install repo is updated.)

2. **Add a tunnel public hostname** (Zero Trust → Networks → Tunnels → the box's
   tunnel → Published application routes → Add):
   - Subdomain `ollie-hermes`, domain `jnow.io`
   - Service: `HTTP` → `localhost:3000` — **not** `:9119`. The dashboard's
     nginx container (port 3000) owns this hostname via `server_name`: it
     applies the auth gate and rewrites Host/Origin to `127.0.0.1:9119`
     (the loopback dashboard rejects any other Host — "Invalid Host
     header", a DNS-rebinding guard; see
     ollie-hermes-frontend scripts/generate-hermes-host.sh). Pointing the
     route straight at `:9119` bypasses both the auth gate and the
     rewrites and gets that error.
   - ⚠️ The original design doc
     (`ollie-fleet/docs/superpowers/specs/2026-06-27-hermes-dashboard-link-design.md`)
     still says `localhost:9119`. It is **stale on this point** — this runbook is
     the corrected, validated version.

3. **Add a Cloudflare Access application** (Zero Trust → Access → Applications →
   Add → Self-hosted):
   - Application domain: `ollie-hermes.jnow.io`
   - Policy: Allow, Include → Emails ending in `@jnow.io` (Google login).

4. **Point the link at it (Fleet):** open the instance in Fleet → set
   **Hermes UI URL** to `https://ollie-hermes.jnow.io` → Save. Fleet writes
   **both** `HERMES_UI_URL` (the link the frontend renders) and
   `HERMES_UI_HOSTNAME` (derived from it — what makes `generate-hermes-host.sh`
   emit the server block at all) into the box `.env`, then recreates the
   dashboard. Setting only the URL leaves the hostname falling through to the
   Ollie SPA.

5. **Share the session cookie with the new hostname.** Required on any box using
   the Supabase cookie gate, and the step most often missed — without it the
   hostname returns a bare nginx `401 Authorization Required`.

   ```sh
   # Guard FIRST. Recreating the dashboard with either of these blank is the
   # S72 login-outage class.
   grep -cE '^(SUPABASE_URL|SUPABASE_ANON_KEY)=.+' ~/hermes-stack/.env   # expect 2

   # Replace if present, append if absent — the key is optional in
   # docker-compose.yml, so a fresh box may not have it in .env at all and a
   # bare `sed -i` would silently no-op.
   grep -q '^SUPABASE_COOKIE_DOMAIN=' ~/hermes-stack/.env \
     && sed -i 's|^SUPABASE_COOKIE_DOMAIN=.*|SUPABASE_COOKIE_DOMAIN=.jnow.io|' ~/hermes-stack/.env \
     || echo 'SUPABASE_COOKIE_DOMAIN=.jnow.io' >> ~/hermes-stack/.env
   grep '^SUPABASE_COOKIE_DOMAIN=' ~/hermes-stack/.env   # confirm before recreating

   docker compose -f ~/hermes-stack/docker-compose.yml up -d --force-recreate dashboard
   ```

   Then **sign out of the main dashboard and sign back in.** An already-issued
   cookie is *not* retrofitted — it has to be re-issued carrying the `Domain`
   attribute, which only happens on a fresh sign-in. Skip this and the 401
   persists, and it looks like the config change didn't take.

   Why: with `SUPABASE_COOKIE_DOMAIN` empty, `supabaseClient.ts` omits
   `cookieOptions`, so the `@supabase/ssr` session cookie is host-only to the
   main dashboard hostname and is never sent to the `-hermes` sibling. The
   `auth_request` to the orchestrator's `/v1/auth/validate` then sees no cookie
   and denies. The Supabase branch of `generate-auth.sh` has no
   `error_page 401` redirect (the oauth2 branch does), so you get a raw nginx
   401 instead of a login page.

   Trade-off: the cookie is then sent to every `*.jnow.io` host. Each box runs
   its own Supabase with its own JWT signer, so a cookie minted on one box never
   validates on another — but it does travel.

6. **Verify:**
   - `curl -s https://<dashboard-host>/config.js | grep -E 'hermesUiUrl|cookieDomain'`
     → both present and non-empty.
   - Incognito to `https://ollie-hermes.jnow.io` → Cloudflare Access Google
     challenge → after login the Hermes dashboard renders fully (CSS/JS load).
   - In Ollie, hard-refresh, click **Backend Settings** → opens that hostname.
   - The raw box IP still exposes only `:22` (no `:9119`).

## Known gap

`HermesDashboardLink` (`ollie-hermes-frontend/src/components/Layout.tsx`) has no
role gate — **every** signed-in user sees **Backend Settings**, including
customer-side users. Since the Access policy allows only `@jnow.io`, they hit a
Cloudflare Access wall on click. Accepted as a papercut rather than widening the
policy (that would hand customers raw Hermes admin); the real fix is to gate the
link on `platform_operator`.
