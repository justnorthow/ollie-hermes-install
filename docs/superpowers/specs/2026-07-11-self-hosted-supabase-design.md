# Self-Hosted Supabase Platform — Design

**Date:** 2026-07-11
**Status:** Approved direction (Approach A); spec pending John's review
**Relates to:** `2026-07-10-provision-done-done-design.md` (amends its Supabase-at-provision model), `2026-07-06-durable-per-box-config-design.md`

## Problem

Hosted Supabase spend is $50–150/mo across 4+ projects and grows linearly: the fleet
model requires one isolated Supabase project per provisioned Ollie box (~$10+/mo
compute each on the Pro org), plus separate projects for jnow-site, airesume, and
GetBilled. Cost scales with every new customer instance forever.

## Decisions (John, 2026-07-11)

1. **Scope: everything** — Ollie fleet (prod, sandbox, future instances) and the
   small apps (airesume, jnow-site, GetBilled) all move off hosted Supabase.
2. **Features in use:** Postgres, Auth (Google OAuth, ES256 JWT signing keys/JWKS,
   custom access-token hook), Storage. No Realtime, no Edge Functions.
3. **Hard isolation required** — customer Ollie instances must never share a
   database or auth realm. Rules out any shared multi-tenant consolidation.
4. **Durability: minimal** — data is largely rebuildable (sessions, roles);
   weekly-grade snapshots acceptable. No PITR requirement.
5. **Keep the Supabase API surface** — supabase-js in the frontend, JWKS validation
   in the orchestrator, the pg-function access-token hook, PostgREST, and Storage
   APIs all stay. This is an infrastructure migration, not a rewrite.

## Considered and rejected

- **Consolidate onto fewer hosted projects** — violates hard isolation; cost still
  scales per customer.
- **Neon** — solves cheap-isolated-Postgres well (scale-to-zero, per-usage billing,
  many projects per plan) but is Postgres only. Neon Auth (Stack Auth) and its Data
  API are not the Supabase surface; auth/storage rework across frontend,
  orchestrator, and install repos would follow — the rewrite we ruled out. Cold
  starts would also hit dashboard logins after idle. May revisit later purely for
  dev-branch workflows.
- **Replace components (plain Postgres + Keycloak/Zitadel + MinIO)** — same
  rewrite problem, no cost advantage over Approach A.

## Architecture (Approach A)

### Per-Ollie-box: co-located trimmed Supabase stack

Each Ollie instance is already an isolated Hetzner VPS running Docker Compose. Add
a trimmed self-hosted Supabase stack to the same box, deployed and owned by the
install repo like every other stack component:

- **Services kept:** `db` (Postgres), `auth` (GoTrue), `rest` (PostgREST),
  `storage` (Storage API, file backend on a local volume), `kong` (internal API
  gateway).
- **Services dropped:** Realtime, Edge Functions, analytics/Logflare, vector,
  imgproxy. Studio + postgres-meta optional/off by default (enable on demand for
  admin work; migrations run via psql).
- **Exposure:** the box's existing nginx fronts Kong at a per-instance hostname,
  e.g. `sb.ollie.jnow.io` / `sb.olliesandbox.jnow.io` (Cloudflare DNS). This
  becomes the instance's `SUPABASE_URL` for both browser (supabase-js) and
  orchestrator. Cookie domain `.jnow.io` unchanged. Same only-:22-open posture —
  traffic arrives via the existing tunnel/proxy path, never a raw port.
- **Isolation boundary = the box.** Same boundary as everything else on the
  instance; nothing shared between customers.

### Auth parity (verified feasible)

- **ES256 signing keys:** self-hosted GoTrue supports asymmetric keys via
  `GOTRUE_JWT_KEYS` (private+public) with `JWT_JWKS` distributed to
  PostgREST/Storage; public key served at `/auth/v1/.well-known/jwks.json`.
  The orchestrator's JWKS-based validation (no `SUPABASE_JWT_SECRET`) carries
  over unchanged. (Supabase docs: self-hosting/self-hosted-auth-keys,
  auth/signing-keys.)
- **Custom access-token hook:** the ollie-core pg-function hook registers via
  `GOTRUE_HOOK_CUSTOM_ACCESS_TOKEN_*` env instead of the dashboard toggle.
- **Google OAuth:** `GOTRUE_EXTERNAL_GOOGLE_*` env per instance; each instance
  hostname gets a redirect URI in the Google console (one-time per instance,
  scriptable checklist item in provisioning docs).
- **Keys/creds:** per-box JWT keypair, `ANON_KEY`, `SERVICE_ROLE_KEY` generated at
  install time by the new script; written to the stack `.env` via the existing
  `stack-env.sh` renderer and added to `preserve_env_keys` (Phase-1 idempotency
  machinery already handles preservation).

### Provisioning integration (amends provision-done-done)

The 2026-07-10 spec has the operator manually creating a hosted project and
pasting url/anon/service-role into the Fleet provision form, with
`11-install-supabase.sh --verify-only` probing it. Under this design:

- `11-install-supabase.sh` gains a **deploy mode**: bring up the local stack,
  generate keys, run the ollie-core migrations (canonical SQL in
  `supabase/ollie-core/`), register the hook, emit url/anon/service-role.
- The Fleet provision form's Supabase fields become optional/derived — Fleet
  stores the creds the box emits rather than collecting them from the operator.
  The manual create-project runbook step disappears.
- The `--verify-only` probe, `seed-operator-role.py`, and the config gate all
  still run — they verify the local stack exactly as they verified the hosted one.
- Existing verify/gate work already landed (check-config verb, verify-only probe)
  is reused as-is; only the "where the creds come from" step changes.

### Shared apps VPS (non-Ollie projects)

One small Hetzner VPS (CPX31-class, ~€14/mo) runs separate compose stacks — one
per app — for jnow-site, airesume, and GetBilled (~1–1.5GB RAM each, so 8GB
covers 3 stacks plus headroom; upsize only if a fourth app lands). Separate
stacks keep each app's auth realm and service-role key distinct, so a compromise
of one site never exposes another. These apps don't require customer-grade
isolation, so sharing the host is acceptable.

### Backups

Hetzner automated server backups on every box (+20% of server cost, 7 rolling
snapshots) — matches the "minimal, recoverable" requirement. Storage files live
on the same disk and ride the same snapshot. Optional later hardening (not in
scope now): nightly `pg_dump` + storage rsync to a Hetzner Storage Box.

### Cost outcome (approximate)

- Today: $50–150/mo and +$10+/mo per future instance.
- After: apps VPS ~€14/mo + backup surcharge; per-Ollie-box marginal cost ≈ €0
  (or one RAM tier bump, ~€4–8/mo, if the trimmed stack doesn't fit — measured on
  sandbox first). Hosted Supabase org cancelled after soak.

## Migration plan (order matters)

1. **Sandbox first (proving ground).** Deploy the trimmed stack on the sandbox
   box; migrate the `ollie-sandbox` hosted project (ref `mctnughllhcndngjqakt`):
   `pg_dump`/restore of ollie-core tables **and `auth.users`** (preserving user
   UUIDs — `user_roles`/`run_owners` reference them), storage objects if any,
   re-register hook, point the box's `SUPABASE_URL`/keys at the local stack.
   Soak until the acceptance checks below pass.
2. **Apps VPS.** Provision the shared VPS; migrate jnow-site, airesume, GetBilled
   one at a time (each is small; same dump/restore + auth.users pattern; update
   each app's env on Cloudways/Vercel/Workers).
3. **jnow prod box.** Repeat the sandbox procedure on `ollie.jnow.io` (hosted
   project `kpdqhntsvjzhqjeupzsj`).
4. **Future instances** provision straight onto the local stack via the amended
   `11-install-supabase.sh` — no hosted step ever.
5. **Decommission:** pause hosted projects for a 2-week soak, then delete and
   cancel the Pro org.

## Risks and mitigations

- **GoTrue is the login gate; upgrades can break auth** (S72 class of pain).
  Pin image digests in the compose file (same pattern as CORTEX_IMAGE/
  FRONTEND_IMAGE), upgrade sandbox-first, keep the documented rollback
  (`.env` pin revert + `docker compose up -d`).
- **RAM footprint unknown until measured.** Trimmed stack estimated 1–1.5GB;
  verify on sandbox before touching prod; budget a RAM tier bump as the fallback.
- **Key management sprawl.** All new secrets flow through `stack-env.sh` +
  `preserve_env_keys` so re-installs never blank them (the S72 lesson, already
  built as Phase 1/3 idempotency).
- **auth.users migration fidelity.** Dump/restore preserves UUIDs and password
  hashes; Google-OAuth identities re-link by provider id. Verify John + Mike can
  log in on sandbox before prod. Fallback: re-seed via the proven
  resolve-or-create-by-email pattern (P6).
- **Self-host upgrade cadence is on us.** Quarterly image-bump pass, sandbox
  first; acceptable trade for the cost/isolation win.

## Acceptance (per migrated target)

- Google login round-trip works; `whoami` returns the correct role on all agents.
- JWKS endpoint serves the ES256 public key; orchestrator validates with no
  `SUPABASE_JWT_SECRET` set.
- Access-token hook fires (tags/role claims present in the JWT).
- Session list / transcripts load; foreign-user access still 403 fail-closed.
- Storage upload + download round-trip (avatar or test object).
- Exposure probe: only :22 open; Supabase reachable only via the fronting proxy.
- After all targets: hosted projects paused, nothing breaks for 2 weeks, org
  cancelled.

## Out of scope

- Realtime, Edge Functions (unused).
- PITR / offsite pg_dump pipeline (optional later hardening).
- Neon for dev-branch workflows (possible later, unrelated to this migration).
- Migrating anything that isn't on Supabase today.
