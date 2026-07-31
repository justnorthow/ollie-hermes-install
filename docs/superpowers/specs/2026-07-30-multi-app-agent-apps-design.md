# Multi-app agent apps on one Supabase — Design

**Date:** 2026-07-30
**Base:** `0cfb52a` (origin/main)
**Branch:** `feat/multi-app-manifests`
**Status:** Draft — awaiting review

**Supersedes** `2026-07-29-multi-app-manifests-design.md`, which was written against
per-app Supabase stacks. That architecture is being deleted by
`2026-07-29-single-supabase-app-schemas-design.md`, whose stage 1 has shipped
(`a98a96f`, `scripts/26-provision-app-schema.sh`). Roughly half the old spec — the
per-app host keys and the three-way resolution order built around them — no longer
describes anything that exists.

## Problem

`scripts/24-install-agent-apps.sh` refuses any manifest with more than one app:

```
error: multi-app manifests are not yet supported (APP_HOST/SB_HOST/IMAGE_TARBALL are
single-app; add per-app host fields to the manifest schema first)
```

`apps/real-estate.json` therefore holds only `popbys`. Adding Home Inspection Advisor
on 2026-07-29 broke the whole profile — including Pop Bys installs — and was reverted
(`ebf096a`, which is the correct state of main for that file). Newsletter Studio is
blocked identically, being the third app for the same profile.

HIA exists on the sandbox only because it was installed by hand, driving scripts 20,
23 and 25 directly. That is not a repeatable install, and it is what this work
replaces.

### The guard's own advice was wrong, twice

The error tells the reader to add per-app host fields to the manifest. That was wrong
when written, because hosts are **instance-specific, not app-specific**: HIA's Supabase
host would be `sb-hia-sandbox.jnow.io` on the sandbox and `sb-hia-towns.jnow.io` on
Towns, while the manifest is shared by every instance.

It is now wrong a second time and more completely: **there are no per-app hosts at
all.** Apps become schemas in the core Supabase and are served same-origin under
`/apps/<name>/`. `SB_HOST` and `APP_HOST` both cease to exist as concepts.

### What the guard was hiding

`SB_HOST` and `APP_HOST` were assigned **inside** the per-app loop by the carry-forward
at `24-install-agent-apps.sh:169-170`. With more than one app and the guard removed,
app 0's values persisted into app 1.

Deleting the hosts does not delete this bug. `IMAGE_TARBALL` is resolved the same way
and remains per-app, and a leaked tarball is worse than a leaked host: **app 0's image
installs under app 1's name and port, and passes app 1's health check.** The
per-iteration-locals discipline is the fix, and it now guards one value instead of
three.

## Scope

This is not "add multi-app support to script 24." It is **the install path after
consolidation** — script 24 rewritten once to install N apps as schemas in the core
stack. Removing the `APP_COUNT > 1` guard falls out of that rather than being the point
of it.

Landing multi-app support on the *stack*-based script 24 is not an option. With
`SB_HOST_<NAME>` deleted, a two-app run against the stack path has no way to give app 1
a Supabase host, so removing the guard would do nothing useful. The guard removal and
the schema repoint are one change.

### Precondition — this lands with the app-side cutover

The rewritten 24 can only install an app whose image is already schema-aware:

- its Supabase client is constructed with `db: { schema: '<name>' }`
- it reads `SUPABASE_APP_KEY`, not `SUPABASE_SERVICE_ROLE_KEY`
- it has no `/sso` route

That is stage 3 of the single-Supabase design. So this spec is the **install-path half
of stage 3**, not a separate change that precedes it.

The consequence is an operational hazard worth stating plainly: between this rewrite
and the last app's cutover, an unfiltered `24 <profile>` run is unsafe, because it
would try to install a not-yet-cut-over app against a schema. The app-name filter is
what makes a staged migration possible.

### Ordering — Pop Bys before HIA

Cut **Pop Bys** over first, even though HIA is the app with the hand-install to
replace. Pop Bys has 0 rows on both boxes, so its cutover is nearly free, and it is
currently the real-estate manifest's *only* app. Once it is cut over the manifest
contains no un-cut-over app, and the hazard above is gone before HIA is ever
re-landed. HIA (2 auth users, 0 reports) follows, and re-landing its manifest entry is
the acceptance event.

## Non-goals

- **Automating script 24 during provisioning.** Nothing calls it today — it is
  operator-run, and this does not change that.
- **Stage 2's data migration.** Row copying and owner-UUID remapping are separate.
- **Stage 4's retirement** of app stacks, hostnames and tunnel routes. The stacks stay
  up during this work, which is what makes rollback cheap.
- **A per-app anon key.** The shared-anon-key gap is real (see Risks) but stage 1
  scoped the structural fix out, and that holds here.
- **The HIA `clear-database` bug** (`src/app/api/admin/clear-database/route.ts:104,108`
  queries a non-existent `ai_cache` inside `catch {}`). Real, unrelated.

## Design

### 1. Script 24, step by step

| Step | Today | After |
|---|---|---|
| 1/5 | `20-install-app-stack.sh` — a full Supabase stack per app | `26-provision-app-schema.sh` — schema, `<name>_owner`, grants, PostgREST registration, owner JWT. New `SUB26` injection seam beside `SUB20`/`SUB23`. |
| 2/5 | inline loop → the app stack's db as `supabase_admin`, tracked in `public._app_migrations` | extracted to `scripts/lib/app-migrations.sh` → the **core** db as `<name>_owner`, tracked in `<name>._migrations`, single-transaction apply preserved, then the RLS gate |
| 3/5 | `SUPABASE_URL=https://<sb_host>`, internal `172.17.0.1:<kong_port>`, anon + `SERVICE_ROLE_KEY` from the app's stack `.env`, plus `HIA_SSO_SECRET` | core's public URL, internal `172.17.0.1:8000`, core's `ANON_KEY`, `SUPABASE_APP_KEY` from `~/supabase-stack/app-keys/<name>.jwt`, `SUPABASE_DB_SCHEMA=<name>`. No service-role key, no SSO secret. |
| 4/5 | tile registration + `<NAME>_BASE_URL` into the dashboard stack `.env` | unchanged except the `config.sso` flag — see below |
| 5/5 | caddy print for `<app_host>:<app_port>` and `<sb_host>:<kong_port>`, then per-app bridges `<name>:<app_port>` and `<name>-sb:<kong_port>` | **no caddy step at all.** One bridge per app (`<name>:<app_port>`) plus **one box-wide** core-kong bridge. |

Step 1 is a substitution, not an addition: script 26 has the same contract as 20 — run
as the service user, `KEY=VALUE` on stdin, idempotent — so it drops into the same seam.

`STACK_ENV_FILE` and `ORCH_ENV_FILE` handling is unchanged, including the existing
distinction between them and the warnings for a stack compose file that does not pass
`<NAME>_BASE_URL` through to the dashboard.

**`config.sso` is deliberately undecided here.** Script 24 hardcodes
`'config': {'url': …, 'sso': True}` in the tile payload. After the SSO collapse the app
has no `/sso` route, so `sso: True` is at best inert and at worst causes the dashboard
to attempt a token exchange. What the dashboard actually does with that flag lives in
`ollie-hermes-frontend`, which I have not read. Resolving it is the first task of the
implementation plan, not a guess in this spec.

### 2. Migrations retarget to core

The image-bundled migration runner is the inline loop at
`24-install-agent-apps.sh:202-214`. It moves to `scripts/lib/app-migrations.sh` and
changes target:

- **Connection:** the core stack's `db` service, not the app stack's.
- **Role:** `<name>_owner`, so every object the migration creates is owned by the app's
  role and inherits the default privileges script 26 installed. Running as
  `supabase_admin` would create tables the PostgREST roles cannot reach.
- **Tracker:** `<name>._migrations`, replacing `public._app_migrations`. Per-schema, so
  three apps no longer contend for one table.
- **Unchanged:** filename-sorted apply, skip-if-applied, and the single-transaction
  apply where the migration file and its tracker `INSERT` travel in one `psql -1`
  invocation so a mid-file failure rolls back both.

Extraction is the point of doing it this way. The runner applies SQL as a privileged
role and now carries the RLS gate, and inside script 24 it is reachable only through a
full install. Stage 1 shipped two Criticals that a direct test would have caught.

**`21-migrate-app.sh` is not involved.** The stage-1 spec's install-path section says
21 "retargets to core, runs as `<name>_owner`, tracks in `<name>._migrations`". It does
not: 21 imports a *hosted* Supabase project (`HOSTED_DB_URL`, `pg_dump --schema-only`,
storage porting) into a local app stack, and never touches `_app_migrations`. Once app
stacks stop existing, 21 drops out of the app-install path entirely.

### 3. The RLS gate — fail closed

After an app's migrations, in the same lib:

```sql
SELECT relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = '<name>' AND c.relkind = 'r' AND NOT c.relrowsecurity;
```

Any row aborts the run, naming the tables.

This is the only thing standing between app A's browser bundle and app B's data. Every
app is handed the *same* core `ANON_KEY`, and `anon`/`authenticated` hold `USAGE` on
every app schema plus DML on its tables — they must, because those are the roles that
serve user-context requests. Under per-app stacks cross-app reach was structurally
impossible; after consolidation it is policy-dependent, and the policy is RLS.

Fail closed rather than warn, for two reasons. Script 24 is where new tables appear, so
it is the only place that sees every table at the moment it is created. And a warning
in a long install log is exactly how the `NODE_OPTIONS` folklore survived unnoticed for
months.

**It costs nothing today.** Measured against every `create table` and every
`enable row level security` in all three apps' migrations:

| App | Tables | RLS enabled | Gap |
|---|---|---|---|
| Pop Bys | 15 | 15 | — |
| HIA | 5 | 5 | — |
| Newsletter | 3 | 2 | `sso_used_tokens` |

The single gap is deleted by the SSO collapse, which lands with the cutover this spec
depends on. So the gate passes for all three apps on day one — measured, not assumed.

### 4. Manifest schema

```json
{
  "name": "hia",
  "server": {
    "app_port": 8110,
    "container_port": 3000,
    "health_path": "/apps/hia/api/health",
    "env": { "SOME_APP_SETTING": "value" }
  },
  "tile": { "label": "…", "icon": "…", "description": "…", "order": 20 }
}
```

- **`stack: { kong_port, email_enabled }` is deleted.** No stack, no kong, no per-app
  email configuration.
- **`server.env` is new and optional** — per-app static environment, merged into the
  existing `APP_ENV_*` passthrough. Operator stdin `APP_ENV_<KEY>` wins on conflict. An
  absent or empty `env` behaves exactly as today.
- **`name` must match `^[a-z][a-z0-9]*$`**, validated in 24 before any install work.

That last rule closes a latent trap. Script 26 requires `^[a-z][a-z0-9_]*$` — a
Postgres identifier, hyphens invalid. Script 25 requires `^[a-z][a-z0-9-]*$` — a
systemd unit name, underscores invalid. An app named `foo_bar` breaks the bridge;
`foo-bar` breaks the schema. Today's names (`popbys`, `hia`) satisfy both by luck.
Validating the intersection makes a bad name fail at parse time instead of
half-installing.

### 5. Per-app operator input

`SB_HOST_<NAME>` and `APP_HOST_<NAME>` do not exist — there are no per-app hosts. What
remains is `IMAGE_TARBALL_<NAME>`, where `<NAME>` is the app name uppercased
(`hia` → `IMAGE_TARBALL_HIA`), resolved into a **per-iteration local**:

1. `IMAGE_TARBALL_<NAME>` from stdin
2. `APP_IMAGE` from `~/apps/<name>/.env` — the existing re-run path
3. bare `IMAGE_TARBALL` — **legal only when exactly one app is in play**, meaning a
   single-app manifest or a run narrowed by the filter

With two or more apps in play, a value with no per-app key and no `.env` is an error
naming the app and the key it wants. Without that rule the natural failure is silent
and bad: two apps handed the same image.

The shared stdin variable is never reassigned. That is the whole leak fix.

### 6. App-name filter

`24-install-agent-apps.sh <profile> [app-name]`. Given a name, only that app is
installed; an unknown name is an error listing the manifest's app names.

The filter was a convenience in the old spec. It is now load-bearing: it is what allows
one app to be cut over while another still runs on its stack, and it is the only safe
way to run 24 during the transition.

### 7. Bridges and reachability

Core kong binds `127.0.0.1:8000` (`templates/supabase/docker-compose.yml:131`), so an
app container cannot reach it directly, and it cannot use the public URL server-side
either — on a cloudflared box that resolves to Cloudflare's edge, which bot-challenges
non-browser clients with HTTP 403 and breaks auth on every route.

So the N per-app `<name>-sb:<kong_port>` bridges collapse into **one box-wide bridge**
for core kong, and 24 probes it **once per run** rather than once per app:

```
sudo bash scripts/25-install-app-bridge.sh core-sb:8000
```

Each app still needs its own app bridge, and 24 gains the check that never existed:

```
sudo bash scripts/25-install-app-bridge.sh <name>:<app_port>
```

Probed at `http://172.17.0.1:<app_port><health_path>`. Its absence is exactly what
502'd HIA on 2026-07-29 — script 23 binds the app to `127.0.0.1` only, while the
dashboard container reaches tile apps over the docker0 gateway, so every loopback
health check passed while the tile was dead. On failure this warns, names the remedy,
and increments `WARNINGS` so the run ends in `⚠` rather than a false `✓`. Script 24
cannot install bridges itself: 25 needs root and 24 refuses to run as root.

### 8. `NODE_OPTIONS` as an install default

`scripts/23-install-app-server.sh` sets
`NODE_OPTIONS=--max-http-header-size=65536` when nothing else supplies one. Manifest
`server.env` and operator stdin both override it.

Node's default 16KB header limit is smaller than what a real browser sends these boxes,
because `SUPABASE_COOKIE_DOMAIN=.jnow.io` sends every box's chunked Supabase cookie to
every `*.jnow.io` host. Pop Bys' SSO handoff broke at exactly that threshold on
2026-07-29, as did HIA's, and the symptom is expensive: HTTP 431, a blank tile, no
client-side error.

A default rather than a manifest field, because a per-app field reproduces today's
failure mode in a new location — folklore every future manifest author has to remember,
instead of folklore nobody needs to know about. Setting it on a non-Node container is
harmless.

**This is now belt-and-braces rather than load-bearing.** Tile-only serving plus the
cookie-isolation work removes the pressure at source. Keep it because it is free and
the failure it prevents is expensive to diagnose.

### 9. Remove the guard

With the above in place, `APP_COUNT > 1` is supported and the guard at
`24-install-agent-apps.sh:62-66` goes.

## Testing

**`scripts/lib/app-migrations.sh` — direct unit tests it never had inside 24:**

- applies in filename order
- skips an already-applied migration
- creates its tracker in `<name>._migrations`, not `public`
- a mid-file failure rolls back the tracker `INSERT` with it, leaving no
  partially-applied file recorded as done and no applied file unrecorded
- objects are created owned by `<name>_owner`

**The RLS gate, in both directions.** The failing direction is the one that matters: a
fixture schema with one deliberately RLS-less table must abort the run and name that
table. A gate that has only ever been seen to pass proves nothing — three probes lied
in the 2026-07-29 session for exactly this reason. Test the failing case first, then
the passing case.

**`tests/test-24-install-agent-apps.sh`:**

- `IMAGE_TARBALL_<NAME>` wins over the `~/apps/<name>/.env` carry-forward
- a two-app run does **not** give app 1 app 0's image — the regression the guard was
  hiding
- bare `IMAGE_TARBALL` works for one app
- bare `IMAGE_TARBALL` **errors** with two apps in play, naming the app and the key
- the filter installs only the named app
- an unknown app name errors and lists the valid names
- a manifest `name` violating `^[a-z][a-z0-9]*$` fails at parse, before any install
- `server.env` reaches the rendered app `.env`
- operator `APP_ENV_<KEY>` overrides a manifest `server.env` key of the same name
- a missing app bridge warns, names the 25 command, and suppresses the `✓`
- the core-kong bridge is probed **once**, not once per app
- **closed-whitelist assertion on the rendered app environment:**
  `SUPABASE_APP_KEY` present, `SERVICE_ROLE` absent in any form. Stage 1 learned that a
  narrow grep is too weak — `test-26` replaced a `TRIGGER` grep with a closed
  whitelist for the same reason.

Note for whoever runs these: `test-24` takes roughly 2m37s on Windows for its existing
93 cases. Budget the timeout generously — a previous session read that as a hang.

## Acceptance

**Step 1 is not delivered by this spec's implementation plan.** Cutting an app over is
app-side work in `jnow-workspace` — the client gains `db: { schema }`, reads
`SUPABASE_APP_KEY`, and loses its `/sso` route — and it belongs to stage 3 of the
single-Supabase design. This spec's plan delivers steps 2 through 6. Step 1 is listed
because acceptance cannot begin without it, and because getting its order wrong
(HIA before Pop Bys) reintroduces the transition hazard described under Scope.

On the sandbox, in this order:

1. **Cut Pop Bys over** to schema `popbys` — 0 rows, so near-free. Tile still loads,
   data intact. *(Stage 3 app-side work; prerequisite, not part of this plan.)*
2. **Re-land the HIA entry** in `apps/real-estate.json` — only now, so main never again
   carries the broken combination.
3. **`24 real-estate hia`** replaces the hand-install: the tile loads, the session works
   with no SSO handoff at all, all 12 migrations land in `hia._migrations`, and the RLS
   gate returns empty.
4. **`24 real-estate` unfiltered**, both apps: both install, neither inherits the
   other's image, both app bridges present, core-kong bridge probed once.
5. **No app container holds core's `service_role` key** — `docker inspect` every one.
6. **Cross-schema access denied:** `SET ROLE hia_owner; SELECT … FROM popbys.contacts;`
   returns `permission denied`.

Steps 5 and 6 are what prove consolidation did not widen each app's blast radius from
"its own stack" to "the whole box". They are acceptance criteria, not nice-to-haves.

## Risks

**Rewriting the only working install path for a live app on two boxes.** Mitigated by
stage 4 being out of scope: the per-app stacks stay up, so rollback for Pop Bys is
repointing its env at the stack that still exists. Sandbox first, Towns after.

**PostgREST bounces once per app** in a multi-app run, because script 26 recreates
`rest` per invocation. Batching would mean changing shipped stage-1 code; accept the
blips and note them rather than reopen 26.

**The shared anon key stays the soft edge.** The gate covers migrations applied through
24. SQL applied by hand bypasses it, and so does any table created outside a migration.
The structural fix — a per-app anon key carrying a schema-scoped role — remains out of
scope.

**Core Supabase becomes a single point of failure for every app on the box.** Inherited
from the single-Supabase design, where it is accepted on the grounds that it already is
one for the dashboard.

## Corrections owed to the stage-1 spec

Measured while writing this. `2026-07-29-single-supabase-app-schemas-design.md` belongs
to a parallel session, so these are recorded rather than applied:

1. **`21-migrate-app.sh` does not apply image-bundled migrations.** Its install-path
   section assigns the migration retarget to 21, but 21 imports a hosted project. The
   retarget belongs to script 24.
2. **Pop Bys has a 14th table, `ollie_links`**
   (`pop-bys/app/supabase/migrations/0004_intake.sql:49`), absent from the runtime
   grant surface. It has RLS, so the gate is unaffected, but a hand-written grant list
   would have missed it.
3. **HIA's `report_pdfs` is a bucket, not also a table.** It appears in both columns of
   the grant-surface table; no migration creates a table by that name.
4. **Newsletter's `sso_used_tokens` has no RLS.** Harmless only because the SSO collapse
   deletes it — worth knowing, since it is the one row the RLS gate would return today.

Also worth recording for anyone reading app source on this machine:
`D:\workspaces\jnow\jnow-workspace` is checked out on `ai-governance-offering`, not
`main`, and is missing `0002_newsletter_drafts.sql`. Read app migrations from `main`,
not from that working tree.

## Known limitation

Installing every app for a vertical in one command requires the operator to have every
image ready at once. The filter exists so that is never forced.
