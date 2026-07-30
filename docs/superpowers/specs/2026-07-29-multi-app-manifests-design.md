# Multi-app agent manifests

Date: 2026-07-29
Base: `ebf096a` (origin/main)
Branch: `feat/multi-app-manifests`
Status: **SUPERSEDED by `2026-07-30-multi-app-agent-apps-design.md`**

> ## ⚠ SUPERSEDED — read the 2026-07-30 spec instead
>
> This spec assumes each app has its own Supabase stack and its own public
> hostnames. `2026-07-29-single-supabase-app-schemas-design.md` deletes that
> architecture, and its stage 1 has shipped (`a98a96f`).
>
> **Wrong here:** `SB_HOST_<NAME>` and `APP_HOST_<NAME>`, the three-way resolution
> order built around them, the carry-forward from each app's own stack `.env`, and
> the caddy vhost step. Apps are now schemas in the core stack, served same-origin
> under `/apps/<name>/`; there are no per-app hosts to resolve.
>
> **Still true:** the app-name filter (now load-bearing, not a convenience),
> `IMAGE_TARBALL_<NAME>`, per-app `server.env`, the app-bridge reachability check,
> the `NODE_OPTIONS` install default, removing the `APP_COUNT > 1` guard, and the
> per-iteration-locals discipline — which guards one value now instead of three.
>
> Kept as a stub because STATE.md and the 2026-07-29 handoff both cite this path.
> Full text: `git show f49726c -- <this file>`.

## Problem

`scripts/24-install-agent-apps.sh` refuses any manifest with more than one app:

```
error: multi-app manifests are not yet supported (APP_HOST/SB_HOST/IMAGE_TARBALL are
single-app; add per-app host fields to the manifest schema first)
```

`apps/real-estate.json` therefore holds only `popbys`. Adding Home Inspection Advisor on
2026-07-29 broke the whole profile — including Pop Bys installs — and was reverted
(`ebf096a`). Newsletter Studio is blocked identically, being the third app for the same
profile.

HIA currently exists on the sandbox only because it was installed by hand, driving scripts
20, 23 and 25 directly. That is not a repeatable install.

### The guard's own advice is wrong

The error tells the reader to add per-app host fields to the manifest. But hosts are
**instance-specific, not app-specific**: HIA's Supabase host is `sb-hia-sandbox.jnow.io`
on the sandbox and would be `sb-hia-towns.jnow.io` on Towns. The manifest is shared by
every instance, so hosts cannot live there. They must stay operator input.

### What the guard was hiding

`SB_HOST` and `APP_HOST` are assigned **inside** the per-app loop by the carry-forward at
`24-install-agent-apps.sh:169-170`. With more than one app and the guard removed, app 0's
values persist into app 1, so the second app silently inherits the first app's Supabase
host and site URL. Removing the guard without fixing this is the trap in this work.

## Non-goals

- Automating script 24 during provisioning. Nothing calls it today — it is operator-run,
  and this change does not alter that.
- Changing scripts 20 or 25. This is 24, the manifest schema, and one default in 23.
- Moving hosts into the manifest, for the reason above.

## Design

### 1. Two input paths

**App-name filter.** `24-install-agent-apps.sh <profile> [app-name]`. Given a name, only
that app is installed; an unknown name is an error listing the manifest's app names.

**Per-app stdin keys.** `SB_HOST_<NAME>`, `APP_HOST_<NAME>`, `IMAGE_TARBALL_<NAME>`, where
`<NAME>` is the app name uppercased with non-alphanumerics replaced by `_` (`hia` →
`SB_HOST_HIA`).

### 2. Resolution order, per app

For each of the three values, in order:

1. the per-app stdin key
2. carry-forward from **that app's own** stack `.env` (`SUPABASE_PUBLIC_URL` / `SITE_URL`)
3. the bare stdin key (`SB_HOST`, `APP_HOST`, `IMAGE_TARBALL`)

Resolution happens into **per-iteration locals**. The shared stdin variables are never
reassigned, which is what fixes the leak.

**The bare fallback is legal only when exactly one app is being installed** — either a
single-app manifest, or a multi-app manifest narrowed by the filter. When two or more apps
are in play, a value with no per-app key and no carry-forward is an error naming the app
and the key it wants. Without this rule the natural failure is silent and bad: two apps
handed the same host and the same image.

### 3. `server.env` in the manifest

Per-app static environment, merged into the existing `APP_ENV_*` passthrough:

```json
"server": {
  "app_port": 8110,
  "container_port": 3000,
  "health_path": "/apps/hia/api/health",
  "env": { "NODE_OPTIONS": "--max-http-header-size=65536" }
}
```

Operator stdin `APP_ENV_<KEY>` wins on conflict. Absent `env` behaves exactly as today.

Operator stdin `APP_ENV_<KEY>` wins; a manifest `server.env` key overrides the install
default below.

### 3b. `NODE_OPTIONS` is an install DEFAULT, not a per-app field

An earlier draft put `NODE_OPTIONS=--max-http-header-size=65536` only in each app's
`server.env`. That is wrong, and a parallel session working on the cookie-domain problem
made the better argument: it reproduces today's failure mode in a new location. Today the
value is folklore applied by hand on the box; a per-app manifest field would make it
folklore that every future manifest author has to remember. A default is correct-by-
construction — a new Node app gets it without anyone knowing it exists.

So `scripts/23-install-app-server.sh` sets `NODE_OPTIONS=--max-http-header-size=65536`
when nothing else supplies one. Manifest `server.env` and operator stdin both still
override it.

Why it is needed at all: Node's default 16KB header limit is smaller than what a real
browser sends to these boxes. Every box sets `SUPABASE_COOKIE_DOMAIN=.jnow.io`, so each
box's chunked Supabase session cookie goes to every `*.jnow.io` host and the request grows
with each box an operator has signed into. Pop Bys' SSO handoff broke at exactly that
threshold on 2026-07-29, as did HIA's. Any ported app with an SSO handoff — a long JWT in
the query string plus every cookie — hits it on first use.

Setting it on a non-Node container is harmless (the variable is simply ignored), so the
default costs nothing for a future app that is not Node.

**This default is defensive, not a fix for the underlying cause.** The parallel session's
cookie-isolation work would make session cookies host-only, which removes the pressure at
source. If that lands, this default becomes belt-and-braces rather than load-bearing —
still worth having, because it is free and because the failure it prevents (HTTP 431,
blank tile, no useful client-side error) is expensive to diagnose.

### 4. App-bridge reachability check

After the app server step, probe `http://172.17.0.1:<app_port><health_path>`. On failure,
emit a WARNING naming the exact remedy:

```
sudo bash scripts/25-install-app-bridge.sh <name>:<app_port>
```

This mirrors the Supabase-bridge check already at `24-install-agent-apps.sh:336`, which
probes `172.17.0.1:<kong_port>`. Nothing checks the **app** bridge today, and its absence
is what produced a 502 for HIA on 2026-07-29: script 23 binds the app to `127.0.0.1` only,
while the dashboard container reaches tile apps over the docker0 gateway.

The check increments `WARNINGS`, so the run ends in `⚠` rather than a false `✓`. Script 24
cannot install the bridge itself — 25 installs system services and needs root, while 24
refuses to run as root — so it prints, exactly as it already does for caddy.

### 5. Remove the guard

With the above in place, `APP_COUNT > 1` is supported and the guard at lines 62-66 goes.

## Testing

`tests/test-24-install-agent-apps.sh` exists and is where these go:

- a per-app key wins over carry-forward
- carry-forward stays scoped to its own app — a two-app run does NOT give app 1 app 0's host
  (the regression the guard was hiding)
- the bare fallback works for a single app
- the bare fallback ERRORS when two apps are in play, naming the app and key
- the filter installs only the named app
- an unknown app name errors and lists the valid names
- `server.env` reaches the rendered app `.env`
- operator `APP_ENV_<KEY>` overrides a manifest `server.env` key of the same name
- a missing app bridge warns, names the 25 command, and suppresses the `✓` banner

## Acceptance

1. Re-land the HIA entry in `apps/real-estate.json` — **only after** 24 supports it, so main
   never again carries the broken combination.
2. On the sandbox, install HIA through the manifest path
   (`24-install-agent-apps.sh real-estate hia`), replacing today's hand-driven install.
3. Confirm the tile still loads and SSO still works, and that `_app_migrations` and the
   proxy maps are unchanged — i.e. the scripted path reproduces the hand-built state.
4. Confirm Pop Bys is untouched by a run that names `hia`.

## Known limitation

Installing every app for a vertical in one command requires the operator to have every host
and image ready at once — in practice, DNS for all of them before any of them. The filter
exists so that is never forced.
