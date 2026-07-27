# Installing agent apps (24-install-agent-apps.sh)

Order: `24-install-agent-apps.sh <profile>` → `25-install-app-bridge.sh <name>:<port>` (root).

## Ingress: caddy vs cloudflared — pick ONE

`22-install-caddy-vhosts.sh` is for **caddy-fronted boxes only**: it installs
caddy, needs :80/:443 open, and uses Let's Encrypt HTTP-01, so hostnames must
resolve directly to the box (Cloudflare **DNS-only / grey-cloud**).

On a **cloudflared** box, skip 22. Publish each hostname as a tunnel public
hostname in Cloudflare Zero Trust instead, and leave :80/:443 closed:

| Hostname | Tunnel service |
|---|---|
| `sb-<app>-<instance>.<domain>` | `http://localhost:<kong_port>` |

Supabase hostnames must be the single-level dash form (`sb-foo`), because
Cloudflare Universal SSL covers only one subdomain level.

An embedded tile app does **not** need its own public hostname: it is proxied
same-origin through the dashboard at `/apps/<name>/` via `<NAME>_BASE_URL`
(set automatically by 24) plus the socat bridge from 25.

## Prerequisites

- An agent whose id equals the profile (e.g. `real-estate`). 24 auto-creates it
  from the manifest's `agent` block when absent; if the manifest has no such
  block, create it in Fleet's Agents tab first.
- `ORCHESTRATOR_KEY` (and `HIA_SSO_SECRET` for SSO) in the file passed as
  `ORCH_ENV_FILE`. On boxes where the orchestrator reads its own env file, that
  is `~/.config/ollie-orchestrator/.env`, **not** `~/hermes-stack/.env` — pass it
  explicitly.
- The app image staged on the box as a `docker save` tarball (`IMAGE_TARBALL`).
