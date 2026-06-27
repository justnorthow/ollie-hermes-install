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
   - Service: `HTTP` → `localhost:9119`

3. **Add a Cloudflare Access application** (Zero Trust → Access → Applications →
   Add → Self-hosted):
   - Application domain: `ollie-hermes.jnow.io`
   - Policy: Allow, Include → Emails ending in `@jnow.io` (Google login).

4. **Point the link at it (Fleet):** open the instance in Fleet → set
   **Hermes UI URL** to `https://ollie-hermes.jnow.io` → Save. Fleet writes
   `HERMES_UI_URL` to the box `.env` and recreates the dashboard.

5. **Verify:**
   - Incognito to `https://ollie-hermes.jnow.io` → Cloudflare Access Google
     challenge → after login the Hermes dashboard renders fully (CSS/JS load).
   - In Ollie, hard-refresh, click **Backend Settings** → opens that hostname.
   - The raw box IP still exposes only `:22` (no `:9119`).
