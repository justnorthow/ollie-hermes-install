# Single-Supabase app data architecture — Design

**Date:** 2026-07-29
**Status:** Draft — awaiting review
**Scope:** How app data and identity live on an Ollie box. Replaces per-app Supabase
stacks with Postgres schemas inside the one core stack.

## Problem

Every app installed on a box today brings a **complete Supabase stack** — db, kong,
auth, rest, storage. Measured:

| Box | Stacks | Containers | Memory available |
|---|---|---|---|
| Towns | `supabase` + `popbys` | 10 | 1.6 GiB of 3.7 |
| jnow prod | `supabase` + `hia` + `ns` | 15 | 1.7 GiB of 3.7 |

Each stack costs ~370 MiB (kong alone ~190 MiB), a hostname, a tunnel route, a
migration chain, and a backup story. Two more apps on the real-estate profile takes
a box to four stacks — roughly 1.5 GiB before the customer does anything.

The resource ceiling is the visible problem. The structural one is worse:

**Each stack has its own `auth.users`.** That is why Pop Bys SSO is must-exist with
no auto-provision, and why onboarding a customer means seeding them into every app
individually. Auto-provisioning isn't a missing feature — it's unbuildable while
identity is fragmented. Every app added multiplies the onboarding problem by one.

The multi-app manifest work makes adding apps *easier*, which brings this forward
rather than pushing it out.

## Decisions

Locked with John, 2026-07-29:

1. **One Supabase per box.** Apps become Postgres schemas inside the existing
   `supabase-*` core stack.
2. **Per-app `<name>_owner` role** owning only that schema.
3. **App runtime JWT carries `role: <name>_owner`, never `service_role`.**
4. **The SSO handoff is deleted.**
5. **No app gets `TRIGGER` on `auth.users`.** Profile rows are created lazily.
6. **This lands before Joseph's pilot.**

## Target architecture

One Supabase. Each app owns a schema (`popbys`, `hia`, `newsletter`), one shared
`auth.users`, apps served same-origin under `<box>/apps/<name>/`.

- **PostgREST** exposes schemas via `PGRST_DB_SCHEMAS=public,popbys,hia,…`; clients
  select with `createClient(url, key, { db: { schema: '<name>' } })`. Adding an app
  appends a schema and restarts `rest` — a brief blip.

  ⚠️ **`PGRST_DB_SCHEMAS` is a compose-level variable, not merely an `.env` key**, and
  stage 1 shipped two Criticals by assuming otherwise. Both are now fixed; recorded so
  the assumption is not made again:
  1. `templates/supabase/docker-compose.yml` originally hardcoded
     `- PGRST_DB_SCHEMAS=public` as a **literal**, the `rest` service has no
     `env_file:`, and `docker compose --env-file` only expands `${VAR}` references — it
     does not inject arbitrary `.env` keys into containers. Writing the key to `.env`
     therefore did nothing. The template must read `${PGRST_DB_SCHEMAS:-public}` (the
     `:-` form, so an unset *or empty* value still yields `public`), and
     `26-provision-app-schema.sh` refuses to run against a compose file lacking that
     reference.
  2. `lib/supabase-stack-env.sh` rewrites `.env` wholesale on every deploy and omitted
     the key from its carry-forward list, so a routine image-pin bump would have reset
     every registered schema and killed all apps' REST APIs at once, silently. It is
     now carried forward — deliberately **outside** that function's all-or-nothing
     secret integrity count, since a stack may legitimately not have it yet.

  The lesson generalises: `docker inspect <container>` shows the *effective* environment,
  which may come from a compose literal rather than `.env`. Confirm which.
- **Migrations** move into the app's schema, tracked in `<name>._migrations`
  (replacing the per-stack `public._app_migrations`), run as `<name>_owner`.
- **Storage** — one storage service, per-app buckets.
- **Runtime config channel survives and is still required.** Core's Supabase URL is
  per-box, so it still cannot be baked into a bundle. It gains the schema name.

### Roles and grants

`<name>_owner` gets:

- `USAGE` + `CREATE` on its own schema; owns its tables
- full DML on its own tables, `USAGE` on its sequences
- `USAGE` on schema `auth` and **`REFERENCES` on `auth.users`** — narrow and
  unavoidable; it is how app rows bind to identity, and it is the thing
  consolidation improves
- its own storage buckets only

and explicitly **not**: any *table* privilege in `public`, anything on another app's
schema, `storage.objects` beyond its own buckets, or `TRIGGER` on `auth.users`.

One precision, because the earlier "nothing on `public`" wording was wrong: every role
inherits ambient `USAGE` on schema `public` from the `PUBLIC` pseudo-role, and
`REVOKE ... FROM <role>` cannot remove it — that only strips ACL entries naming the role.
Verified on PG 15.8: `pg_namespace.nspacl` for `public` carries `=U/pg_database_owner`
(empty grantee = `PUBLIC`), and a grantless role reports `has_schema_privilege(…,'public','USAGE') = true`.
That ambient `USAGE` is **name resolution only** — the same grantless role reports
`false` for `SELECT` on `public.user_roles`, `false` for `SELECT` on `auth.users`, and
`false` for `CREATE` on `public`. So the isolation holds; it comes from never granting
table privileges, not from a revoke.

`GRANT <name>_owner TO authenticator` lets PostgREST switch into it.

**Where the app's key comes from.** Supabase's `anon` and `service_role` keys are
just long-lived JWTs signed with the project's JWT secret, carrying a `role` claim.
The app's key is the same thing with `role: <name>_owner`: minted at install time by
`24-install-agent-apps.sh` using core's JWT secret, written into the app's env as
`SUPABASE_APP_KEY`, and used everywhere the app previously used
`SUPABASE_SERVICE_ROLE_KEY`. The anon key is unchanged and still used for
user-context requests. Rotation is a re-mint plus a container recreate; the secret
never leaves the box.

**Core's `service_role` key stays with the dashboard and never reaches an app
container.** This is the point on which consolidation succeeds or fails: `service_role`
bypasses RLS by construction and reaches every schema plus `auth`. Scoping only the
*migration* role while the app still runs as `service_role` would take each app's
blast radius from "its own stack" to "the whole box" — strictly worse than today.
Routing the app through `<name>_owner` makes cross-schema access structurally
impossible **for that role**, and preserves "bypass RLS within my own schema".

It also ends up better than today: after the SSO collapse no app holds a credential
that can reach `auth.users` at all.

#### The isolation claim does NOT extend to the shared anon key

An earlier draft of this section claimed consolidation makes cross-schema access
"structurally impossible rather than policy-dependent" without qualification. Stage 1's
final review disproved the general form, and the correction matters:

Provisioning grants `anon`, `authenticated` and `service_role` `USAGE` on every app
schema plus DML on its future tables — they have to, because those are the roles that
serve user-context requests. But **every app is handed the same core `ANON_KEY`.** So
app A's browser bundle carries a key that can reach app B's schema.

Under per-app stacks that was structurally impossible. After consolidation it is
policy-dependent, and the policy is RLS. Two roles, two different guarantees:

| Role | Cross-schema reach | Enforced by |
|---|---|---|
| `<name>_owner` (the app's server key) | none | grants — structural |
| `anon` / `authenticated` (shared key) | every app schema | **RLS — policy** |

**Therefore RLS is mandatory, not advisory, on every table in every app schema.** This
gate must pass per app before its data moves, and again whenever a migration adds a
table:

```sql
SELECT relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = '<name>' AND c.relkind = 'r' AND NOT c.relrowsecurity;
```

Any row returned is a table readable by every app on the box via the shared anon key.
An empty result is the gate. A future hardening option, out of scope here, is a
per-app anon key carrying a schema-scoped role — that would make this structural too.

### Runtime grant surface

Enumerated from actual call sites:

| App | Tables | Storage buckets |
|---|---|---|
| HIA | `users`*, `reports`, `file_uploads`, `report_pdfs`, `ai_response_cache` | `inspection_pdfs`, `amendment_pdfs`, `report_pdfs` |
| Newsletter | `newsletter_drafts`, `voice_profiles` | — |
| Pop Bys | `workspaces`, `members`, `invites`, `contacts`, `plans`, `stops`, `routes`, `runs`, `intake_sessions`, `calendar_events`, `budgets`, `expenses`, `google_tokens` | — |

\* HIA's `users` is its **own profile table**, not `auth.users`. It becomes
`hia.users`. Easy to misread when writing grants.

**Do not grant on `ai_cache`** — it is not a table. The name appears only in a
comment banner, an index name (`idx_ai_cache_hash`), a cookie (`hia_use_ai_cache`),
and one dead query (see follow-ups).

## SSO collapse

The handoff exists only because the app and the dashboard were different Supabase
projects. Same project + same origin means the app uses the session that is already
there.

Deleted: `app/sso/route.ts` (HIA, Newsletter), `server/sso.ts` (Pop Bys),
`sso_used_tokens` and migration 0007, the `HIA_SSO_SECRET` wiring, the app-token
mint usage, and the must-exist mapping page.

Authorization is unchanged — RLS keyed on `auth.uid()`.

This is also what makes the role switch cheap. Every `auth.admin.*` call in all three
apps lives in exactly one file per app, and all three are SSO routes. After the
collapse **no app touches the `auth` schema at runtime**, so a schema-scoped role is
sufficient: a config change per app, not a refactor of call sites.

## The `auth.users` trigger

HIA creates a trigger on `auth.users`, in two files:

```
supabase/migrations/001_initial_schema.sql:105-106
supabase/bootstrap.sql:119-120
    drop trigger if exists on_auth_user_created on auth.users;
    create trigger on_auth_user_created …
```

Harmless under separate stacks. Against one shared `auth.users` it is not:

1. It runs app code on **every signup box-wide**, including the dashboard's — exactly
   the coupling schema isolation exists to prevent.
2. `on_auth_user_created` is the generic Supabase idiom, and the statement begins with
   `drop trigger if exists`. A second app copying the same idiom silently drops the
   first one's trigger. Last migration wins, destructively, without error.

Pop Bys creates no triggers on `auth.users`; its triggers are on its own tables.

**Resolution:** HIA creates its profile row lazily on first authenticated request. No
app role gets `TRIGGER` on `auth.users`. A core-owned dispatching trigger was
considered and rejected — it moves app-specific logic into ollie-core, which is the
same coupling pointing the other way. HIA has 2 users and 0 reports, so this is a
small change at the cheapest possible moment.

**Verified cost — one helper, no call-site changes.** The trigger function is a
two-column insert (`public.handle_new_user()` → `insert into public.users (id, email)`),
and it is the **only writer** of that table: no `insert` or `upsert` on `users` exists
anywhere in `src`. The profile row's only authorization use is `is_admin`, and every
gate is fail-closed:

```ts
const { data } = await supabase.from('users').select('is_admin').eq('id', userId).single()
return (data as { is_admin: boolean } | null)?.is_admin === true
```

A missing row yields `null` → `false` → redirect or 401. A not-yet-created profile can
therefore only *deny* access, never grant it — which is what makes lazy creation safe
rather than merely convenient. Nothing in the codebase sets `is_admin`; admin flags are
applied by hand in the database, and that is unchanged.

The change is an `ensureProfile(id, email)` upsert on first authenticated request,
running under the app's own role, plus deleting `handle_new_user()` and the trigger
from **both** `supabase/migrations/001_initial_schema.sql` and `supabase/bootstrap.sql`.

## Sequencing

This spec is **too large for one implementation plan**. The numbered stages below are
the decomposition: each is independently plannable, testable, and shippable, and they
must land in this order. Stage 3 repeats per app.

**Order matters, and one rule is load-bearing:**

> The SSO collapse lands **before or with** the role switch — never after.

Role switch first and the apps lose `auth` access they still need. Role switch later
and there is a window where they hold `service_role` for no reason.

1. **Schema + role provisioning** in the install path. Infrastructure only — no app
   touched, nothing user-visible, independently verifiable.
2. **Per app, per box: consolidate the data.** Create the schema, run that app's
   migrations into it, migrate its rows and remap owner UUIDs to core's `auth.users`.
   The app is still running on its old stack at this point.
3. **Per app: the cutover, in one cut.** Point the client at core's URL + anon key +
   `db.schema`, delete the SSO handoff, and switch the runtime key from `service_role`
   to the `<name>_owner` JWT. These three are interdependent and must land together.
4. Retire that app's stack, hostname, and tunnel route.
5. Onboard Joseph.

**An earlier draft of this spec had the SSO collapse as stage 1. That was wrong** — SSO
exists *because* the app and dashboard are separate Supabase projects, so deleting it
before consolidation leaves the app unable to authenticate anyone. The constraint it was
trying to honour ("SSO collapse before or with the role switch, never after") is
satisfied by stage 3, where both happen in the same cut.

## Data migration

| App | Data |
|---|---|
| Pop Bys (Towns + sandbox) | 1 workspace, 0 contacts, 0 runs, 0 expenses — nothing to move |
| HIA (prod) | 2 auth users, 0 reports |
| Newsletter (prod) | 3 auth users, 1 `newsletter_draft` |

Five auth users and one row. The users are the awkward part: RLS policies reference
their UUIDs, and those people almost certainly already exist in core's `auth.users`
as dashboard users — so consolidation **merges their identities**, which is the
upside. But the draft's owner UUID points at the `ns` stack's UUID for that person,
not core's, so it needs a remap. One row today; not trivial later.

## Install path changes

- `20-install-app-stack.sh` no longer runs per app.
- `24-install-agent-apps.sh` drops the stack step, gains schema + role provisioning,
  and points the app at core's URL and anon key plus its schema name.
- Operator input loses `SB_HOST` entirely — one fewer hostname, tunnel route, and
  thing to get wrong per app.
- `21-migrate-app.sh` retargets to core, runs as `<name>_owner`, tracks in
  `<name>._migrations`.

## Coordination with the multi-app manifest work

Branch `feat/multi-app-manifests` is held at base `ebf096a`; nothing merged.

**Survives:** the app-name filter, `IMAGE_TARBALL_<NAME>`, per-app `server.env`, the
app-bridge reachability check, `APP_COUNT > 1` guard removal, and the `NODE_OPTIONS`
default in `23`.

**Dies:** `SB_HOST_<NAME>`, carry-forward from each app's own stack `.env`, and the
per-app `stack: { kong_port, email_enabled }` manifest block.

**The per-iteration-locals discipline survives and still matters.** An earlier
summary of this design claimed the leak fix was a casualty; that was wrong. The bug
is about any per-app value resolved through shared variables inside the loop, and
`IMAGE_TARBALL_<NAME>` remains per-app. A leaked tarball is worse than a leaked host:
app 0's image installs as app 1, running under app 1's name and port and passing its
health check.

## Risks

- Core Supabase becomes a single point of failure for every app on the box. It
  already is for the dashboard.
- Supabase upgrades now hit all apps at once. Nothing was staggering them before.
- `<name>_owner` owns its tables, so RLS does not constrain it within its own schema
  — parity with today's per-stack `service_role`, and strictly better because it has
  no `auth` access.
- PostgREST restarts when a schema is added.

## Verification

- A cross-schema `select` from an app's role **fails**.
- No app container holds core's `service_role` key.
- A migration naming another schema fails rather than succeeding.
- End-user RLS behaviour is unchanged per app.
- One sign-in reaches every app — the auto-provisioning problem is gone by
  construction, not by feature.

## Follow-ups (out of scope)

- **HIA `clear-database` bug:** `src/app/api/admin/clear-database/route.ts:104,108`
  queries `.from('ai_cache')`, a table no migration creates, inside
  `try { } catch { /* ignore */ }`. The admin "clear database" has therefore never
  cleared the AI cache and never reported it. Real bug, unrelated to this work.
- Cortex storage is untouched.
- Newsletter's data model beyond `newsletter_drafts` / `voice_profiles` is unexamined.
