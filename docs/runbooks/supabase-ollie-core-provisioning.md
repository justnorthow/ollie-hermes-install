# Runbook: provision a dedicated Supabase project for an Ollie instance

> **Default path changed (2026-07-11):** new boxes self-host Supabase —
> see `self-hosted-supabase.md` (`11-install-supabase.sh --deploy`), which
> applies `supabase/ollie-core/` automatically. This runbook remains the
> manual procedure for hosted Supabase projects (legacy/grandfathered boxes).

Gives one Ollie instance (box) its own Supabase project — auth user pool +
Ollie-core tables — instead of riding on a shared project. First executed for
`sandbox` (2026-07-07) after cross-instance session bleed was found between
sandbox and jnow prod sharing one project.

## 1. Create the project

Supabase dashboard → New project, in the JNOW org. Note the project ref
(`https://<ref>.supabase.co`). Free tier is fine for sandbox-class instances.

## 2. Apply the Ollie-core schema

Run `supabase/ollie-core/0001…0006` (this repo) in order in the SQL Editor.
See `supabase/ollie-core/README.md` for what each file is and the dependency
notes.

## 3. Auth configuration (dashboard)

1. **Google provider**: Authentication → Sign In / Providers → Google → enable,
   using the shared JNOW Google OAuth client. In Google Cloud Console, add
   `https://<ref>.supabase.co/auth/v1/callback` to that client's authorized
   redirect URIs.
2. **URLs**: Authentication → URL Configuration → Site URL =
   `https://<instance>.jnow.io`; add it to Redirect URLs too.
3. **Auth hook**: Authentication → Hooks → "Customize Access Token (JWT)
   Claims" → select `public.custom_access_token_hook`. Only after step 2's SQL
   (0006) is applied — a registered hook that errors blocks all logins.
4. Grab keys: Settings → API → `anon` + `service_role`. JWT verification: new
   projects sign with ES256 (JWKS) — the orchestrator validator only needs
   `SUPABASE_URL`. Legacy-HS256 projects additionally need the JWT secret as
   `SUPABASE_JWT_SECRET` in the orchestrator env.

## 4. Point the box at the new project

Via Fleet (instance → Supabase config): URL, anon key, service-role key, cookie
domain (`.jnow.io` — required so `<instance>-hermes.jnow.io` shares the session;
cookie names are per-project-ref so there is no cross-instance collision).
Apply pushes to `~/hermes-stack/.env` and recreates the dashboard container.

**Manual until Fleet owns it**: the orchestrator env
(`~/.config/ollie-orchestrator/.env`) needs the same `SUPABASE_URL` and
`SUPABASE_SERVICE_ROLE_KEY` (+ `SUPABASE_JWT_SECRET` if HS256); then
`systemctl --user restart ollie-orchestrator`.

**Trap (S72)**: verify `~/hermes-stack/.env` has SUPABASE_URL/ANON_KEY/
COOKIE_DOMAIN set BEFORE any `docker compose up -d dashboard` — a recreate with
them missing ships a frontend with no login gate config (login outage).

## 5. First login + operator seed

1. Log out / log in once on `https://<instance>.jnow.io` (creates the user in
   the NEW project — note the new user UUID: Authentication → Users).
2. Seed the operator role (service-role key, PostgREST):

```bash
curl -s "$SUPABASE_URL/rest/v1/user_roles" \
  -H "apikey: $KEY" -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" -H "Prefer: resolution=merge-duplicates" \
  -d '{"instance_id":"<INSTANCE_ID>","user_id":"<uuid>","tier":"platform_operator"}'
```

## 6. Rebuild session ownership

On the box (rebuilds `agent_sessions` from Hermes's live session list — no row
migration from the old project):

```bash
cd ~/ollie-hermes-orchestrator
set -a; . ~/.config/ollie-orchestrator/.env; set +a
BACKFILL_USER_ID=<new-uuid> python3 scripts/backfill_sessions.py
```

## 7. Clean the old shared project

Delete this instance's rows from the previous project: `agent_sessions`
(match `instance_id`, or all rows known to belong to this box), its
`user_roles` row(s), and optionally its `governance_events`
(`instance_id = '<INSTANCE_ID>'`). Copy first if history must be preserved.

## 8. Verify

- Login works; whoami returns the operator tier; agents list renders.
- Transcripts lists real sessions and opening one returns messages (200).
- Chat round-trip works; a governed run writes a `governance_events` row to the
  NEW project.
- The old project no longer receives writes from this box.
