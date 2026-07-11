# Runbook: self-hosted Supabase for an Ollie box

Every new Ollie box gets its own trimmed, co-located Supabase stack (db + auth +
rest + storage behind Kong, loopback-only) instead of a hosted `*.supabase.co`
project — see `docs/superpowers/specs/2026-07-11-self-hosted-supabase-design.md`
for why. `scripts/11-install-supabase.sh --deploy` stands the stack up, applies
the `supabase/ollie-core/` migrations, and points the dashboard + orchestrator at
it. This is now the default path for new boxes. `docs/runbooks/supabase-ollie-core-provisioning.md`
remains the manual procedure for hosted/legacy Supabase projects.

## 1. Prereqs

- The box is provisioned through `06-install-stack.sh` (`~/hermes-stack` is up —
  `docker compose -f ~/hermes-stack/docker-compose.yml ps` shows the dashboard
  container running).
- DNS + `cloudflared` are already serving the box's dashboard hostname
  (`<instance-host>`, e.g. `ollie.jnow.io`) per
  `docs/runbooks/hermes-dashboard-cloudflare.md` — same tunnel gets a second
  public hostname for Supabase in the next step.
- You're logged in as the service user (`sudo -iu ollie`, or `ssh ollie@<host>`),
  **not root** — `11-install-supabase.sh` hard-errors if run as root.
- **All commands in this runbook run from `~/ollie-hermes-install`** (the
  cloned install repo, per the README quick start) as the service user:
  `cd ~/ollie-hermes-install` first.

## 2. Cloudflared ingress — do this FIRST, before `--deploy`

**Why this has to come before the deploy step:** `--deploy`'s final health
check (step 3 of the tail, "verify the Supabase project is provision-ready")
probes `${SUPABASE_PUBLIC_URL}/rest/v1/user_roles` — the **public** `sb.<host>`
hostname, not `localhost:8000`. If the tunnel route isn't live yet, that probe
fails with a connection error *after* the local stack has already come up
successfully and the migrations have already applied — a confusing partial
failure. Wire the hostname first so the probe (and Google OAuth) succeed
end-to-end on the first `--deploy`.

1. **Add a tunnel public hostname** (Zero Trust → Networks → Tunnels → the
   box's tunnel → Published application routes → Add):
   - Subdomain: `sb.<instance>` (for `ollie.jnow.io`, that's subdomain `sb.ollie`,
     domain `jnow.io` — full hostname `sb.ollie.jnow.io`)
   - Service: `HTTP` → `localhost:8000` (Kong's loopback-only port — see
     `templates/supabase/docker-compose.yml`, the `kong` service only binds
     `127.0.0.1:8000:8000`)
   - No Cloudflare Access application needed here (unlike the dashboard
     hostname) — this is an API surface, not a login UI; Kong's `key-auth`/`acl`
     plugins plus Postgres RLS are the access control.

2. **Verify the route is live** (won't return `200` yet — the stack isn't
   deployed — but it must reach Kong, not time out or 522):

   ```bash
   curl -s -o /dev/null -w '%{http_code}' https://sb.<instance-host>/auth/v1/health -H 'apikey: <anon>'
   ```

   Before `--deploy` this returns `000`/`502`/`522` (nothing is listening on
   `:8000` yet) if the tunnel route itself is broken, or a connection succeeds
   but auth isn't up yet. Re-run this same command after step 4 (deploy) and
   confirm it then returns `200` — that's the real acceptance check; right now
   you're only confirming the tunnel hostname resolves and reaches the box.

## 3. Google OAuth redirect URI

In the Google Cloud console, open the **existing per-instance OAuth client**
(the same one used by `supabase-ollie-core-provisioning.md` for hosted
projects) → Credentials → the OAuth 2.0 Client ID → Authorized redirect URIs →
Add:

```
https://sb.<instance-host>/auth/v1/callback
```

This matches `GOTRUE_EXTERNAL_GOOGLE_REDIRECT_URI=${SUPABASE_PUBLIC_URL}/auth/v1/callback`
in `templates/supabase/docker-compose.yml`'s `auth` service.

## 4. Deploy

```bash
printf 'SUPABASE_PUBLIC_URL=https://sb.<instance-host>\nSITE_URL=https://<instance-host>\nGOOGLE_CLIENT_ID=<id>\nGOOGLE_CLIENT_SECRET=<secret>\n' \
  | bash scripts/11-install-supabase.sh --deploy
```

- `SUPABASE_PUBLIC_URL` — the Supabase API hostname from step 2
  (`https://sb.<instance-host>`).
- `SITE_URL` — **required**, the browser-facing dashboard origin (e.g.
  `https://ollie.jnow.io`). It sets `GOTRUE_SITE_URL` and
  `GOTRUE_URI_ALLOW_LIST=${SITE_URL}/**`, i.e. it scopes which origins GoTrue
  will redirect back to after login. Getting this wrong (or leaving it blank)
  either blocks the login redirect or opens the allow-list too wide.
- `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` — optional on a first deploy if
  you want to bring the stack up before wiring Google; **required** before
  anyone can actually sign in. On re-runs, omit them entirely and the prior
  values carry forward from `~/supabase-stack/.env` (see §6).

What this does (in order, per `scripts/11-install-supabase.sh`):

1. Stages `~/supabase-stack/` — copies `templates/supabase/docker-compose.yml`,
   renders `.env` (generates or preserves the 6 interdependent secrets, always
   restamps the pinned image tags), renders `kong.yml` with the real anon/service
   keys.
2. `docker compose pull` + `up -d` for db/auth/rest/storage/kong.
3. Polls `http://127.0.0.1:8000/auth/v1/health` (up to 60s) — hard-fails with a
   `docker compose logs auth kong` pointer if auth never comes up.
4. Applies every `supabase/ollie-core/000*.sql` file via `psql` inside the `db`
   container (idempotent).
5. Writes `SUPABASE_URL`/`SUPABASE_ANON_KEY` into `~/hermes-stack/.env` and
   recreates the `dashboard` container so the frontend's login gate points at
   the new stack.
6. Falls through to the same verify/apply tail as the hosted path: probes
   `${SUPABASE_PUBLIC_URL}/rest/v1/user_roles` (this is the step that needs the
   tunnel from §2 already live), writes `SUPABASE_URL`/`SUPABASE_SERVICE_ROLE_KEY`
   to the orchestrator env, and restarts `ollie-orchestrator`.

**Secrets in stdout — do not paste this into tickets/chat.** The deploy summary
prints `ANON_KEY` and `SERVICE_ROLE_KEY` (and `SUPABASE_URL`/`SITE_URL`) to
stdout at the end of step 6 above, e.g.:

```
    local stack deployed — keys for Fleet (store via provision flow):
    SUPABASE_URL=https://sb.ollie.jnow.io
    SITE_URL=https://ollie.jnow.io
    SUPABASE_ANON_KEY=eyJ...
    SERVICE_ROLE_KEY=eyJ...
```

These land in terminal scrollback/logs. Copy them straight into Fleet's
provision flow (or wherever they need to go) and avoid pasting the raw output
elsewhere — treat scrollback from this command as sensitive for the rest of
the session.

## 5. Acceptance checklist

Run these after step 4 succeeds (and after the redirect URI from step 3 is
saved).

**a. JWKS endpoint serves an ES256 key**

```bash
curl -s https://sb.<instance-host>/auth/v1/.well-known/jwks.json
```

Expect a `{"keys":[...]}` body containing an entry with `"kty":"EC"`,
`"alg":"ES256"` (the asymmetric signing key GoTrue generated at deploy time —
see `scripts/lib/gen-supabase-keys.py`'s `ec_pem_to_jwk`) alongside a legacy
`"kty":"oct"` HS256 verify-only key. Quick grep:

```bash
curl -s https://sb.<instance-host>/auth/v1/.well-known/jwks.json | grep -o '"alg":"ES256"'
```

**b. Browser Google login round-trip + whoami shows the seeded role**

First seed the operator's role (per the done-done flow — this must run before
the login check means anything):

```bash
python3 scripts/lib/seed-operator-role.py --email <operator-email> --instance-id <INSTANCE_ID>
```

This resolves-or-creates the Supabase auth user by email and upserts a
`platform_operator` row in `user_roles` for `<INSTANCE_ID>` (idempotent —
merge-duplicates upsert; reads/writes `~/.config/ollie-orchestrator/.env` for
`SUPABASE_URL`/`SUPABASE_SERVICE_ROLE_KEY`, which step 4 just wrote).

Then, in a browser: open `https://<instance-host>`, sign in with Google, and
confirm the redirect back to the dashboard completes (no GoTrue error page).
In devtools → Network, find the whoami call the dashboard makes to the
orchestrator (the same endpoint `check-box-config.sh`'s live gate probes,
`GET http://127.0.0.1:9123/v1/whoami`, proxied through the dashboard) and
confirm the response's `tier` is `platform_operator` — the role you just
seeded.

**c. Decode a session JWT — hook claims present**

Grab the `access_token` from the browser (devtools → Application → Local
Storage → the `supabase.auth.token`-style key, or the `Authorization` header
on an authenticated request), then:

```bash
python3 -c "
import base64, json, sys
token = sys.argv[1]
payload_b64 = token.split('.')[1]
payload_b64 += '=' * (-len(payload_b64) % 4)
print(json.dumps(json.loads(base64.urlsafe_b64decode(payload_b64)), indent=2))
" '<paste-access_token>'
```

Confirm the decoded payload has:
- `"user_role": "agent"` — a constant every JWT gets (per
  `supabase/ollie-core/0006_access_token_hook.sql`: authority/tier is
  deliberately never a JWT claim, it lives in `user_roles` and is what §5b's
  whoami call reads).
- `"tags": [...]` — an array (empty `[]` is fine if the user has no tags in
  `user_tags`).

Both keys being present at all (rather than absent) proves
`custom_access_token_hook` fired — i.e. the hook is registered and didn't
error (a broken registered hook blocks all logins outright, so if you got this
far it already fired).

**d. Storage round-trip**

Using the `SERVICE_ROLE_KEY` from step 4's output:

```bash
# Create a bucket
curl -s -X POST "https://sb.<instance-host>/storage/v1/bucket" \
  -H "apikey: <service-role-key>" -H "Authorization: Bearer <service-role-key>" \
  -H "Content-Type: application/json" \
  -d '{"name":"acceptance-test","public":false}'

# Upload an object
echo "hello from acceptance check" > /tmp/sb-test.txt
curl -s -X POST "https://sb.<instance-host>/storage/v1/object/acceptance-test/hello.txt" \
  -H "apikey: <service-role-key>" -H "Authorization: Bearer <service-role-key>" \
  -H "Content-Type: text/plain" \
  --data-binary @/tmp/sb-test.txt

# Fetch it back
curl -s "https://sb.<instance-host>/storage/v1/object/acceptance-test/hello.txt" \
  -H "apikey: <service-role-key>" -H "Authorization: Bearer <service-role-key>"
```

The last command must echo back `hello from acceptance check`. (Kong's
`storage-v1` route strips `/storage/v1/` and forwards to the `storage`
container at `:5000`; the `storage` service in the compose file has
`FILE_SIZE_LIMIT=52428800`, `STORAGE_BACKEND=file` on the `storage-data`
volume.)

**e. Foreign-user access still fails closed**

`agent_sessions` (`supabase/ollie-core/0001_agent_sessions.sql`) has RLS
enabled with a single `select ... using (user_id = auth.uid())` policy and no
insert/update/delete policy at all — a second, non-operator authenticated user
must never see another user's session rows via PostgREST directly:

```bash
curl -s -o /dev/null -w '%{http_code}\n' \
  "https://sb.<instance-host>/rest/v1/agent_sessions?select=id" \
  -H "apikey: <anon-key>" \
  -H "Authorization: Bearer <second-account-session-jwt>"
```

Expect `200` with a body of `[]` (or only rows that second account itself
owns) — RLS filters the table, it never leaks another user's row. Note: the
acceptance spec's "foreign-user 403" shorthand manifests at the PostgREST
layer as exactly this — HTTP `200` with an RLS-filtered empty body, not a
literal `403` status — so an empty `[]` here means the check is *passing*,
not broken. This is
defense-in-depth: the primary enforcement is the orchestrator's run-proxy,
which the `0001` migration's own comment describes as enforcing ownership
"fail-closed" — verify that layer too, in the dashboard: log in as a second
Google account and confirm the Transcripts/session list shows only that
account's own sessions, never the operator's.

**f. Exposure probe**

```bash
OPERATOR_EMAIL=<operator-email> bash scripts/check-box-config.sh
```

Expect `OK: box config is done-done` (exit 0). This covers the orchestrator
env, proxy-map coverage, dashboard session-token drop-ins, and the stack's
`SUPABASE_URL`/`SUPABASE_ANON_KEY` — but not port exposure, so pair it with an
external scan of the box's raw public IP:

```bash
nmap -Pn -p- <box-public-ip>
```

Expect only `22/tcp open` — Supabase (`:8000`, loopback-only per the `kong`
service's `127.0.0.1:8000:8000` port binding) and every other stack port must
not appear; the only path in is the cloudflared tunnel from §2.

## 6. Re-run / upgrade

**Re-running `--deploy` is safe.** The 6 interdependent secrets
(`POSTGRES_PASSWORD`, `JWT_SECRET`, `GOTRUE_JWT_KEYS`, `JWT_JWKS`, `ANON_KEY`,
`SERVICE_ROLE_KEY`) are preserved as an all-or-nothing set from the existing
`~/supabase-stack/.env`; the pinned image tags
(`SB_DB_IMAGE`/`SB_AUTH_IMAGE`/`SB_REST_IMAGE`/`SB_STORAGE_IMAGE`/`SB_KONG_IMAGE`)
are **always** restamped from `scripts/lib/supabase-stack-env.sh`, never
preserved — so a plain re-run with no stdin (omitting `SUPABASE_PUBLIC_URL`
etc. entirely, or piping an empty stdin) picks up any pin bump without
touching credentials.

**Partial-`.env` failure mode.** If `~/supabase-stack/.env` exists but is
missing *some but not all* of the 6 secret keys — a hand-edited file, a
restored backup that didn't include the full set, or an interrupted first
write — `render_supabase_stack_env` (in `scripts/lib/supabase-stack-env.sh`)
hard-errors and names the missing keys, e.g.:

```
ERROR: /home/ollie/supabase-stack/.env has some but not all of the 6 interdependent Supabase secrets (missing: JWT_JWKS ANON_KEY). These keys are cryptographically linked (JWTs are signed with JWT_SECRET; JWT_JWKS embeds it) and cannot be partially regenerated without breaking JWT verification. Restore the missing keys from backup, or delete /home/ollie/supabase-stack/.env (or the target .env) entirely to regenerate a full new set.
```

It refuses to mix old and new secrets because that silently breaks JWT
verification (the JWKS embeds `JWT_SECRET`; `ANON_KEY`/`SERVICE_ROLE_KEY` are
JWTs signed with it). **Remedy:** either restore the missing keys from a
Hetzner snapshot (§7) into `~/supabase-stack/.env`, or delete
`~/supabase-stack/.env` outright and re-run `--deploy` to mint a brand-new
full set — this invalidates every previously-issued session/anon/service key
(users have to log in again; re-run `seed-operator-role.py` for the operator
role).

**Image bumps.** Bump the pin constants
(`SB_DB_IMAGE_PIN`/`SB_AUTH_IMAGE_PIN`/`SB_REST_IMAGE_PIN`/`SB_STORAGE_IMAGE_PIN`/`SB_KONG_IMAGE_PIN`)
at the top of `scripts/lib/supabase-stack-env.sh`, sandbox-first — re-diff env
vars against `github.com/supabase/supabase/tree/master/docker` when bumping
(per the file's own header comment). Then re-run `--deploy` (no stdin needed
if the URLs/Google creds are already set) to pull the new images and recreate
the containers. **Rollback:** revert the pin lines in
`scripts/lib/supabase-stack-env.sh` and re-run `--deploy` again.

**Migration ledger.** Applied `supabase/ollie-core/[0-9]*.sql` migrations are tracked by filename in `public._ollie_core_migrations` on the box and skipped on re-runs (deploy step 4), so a new migration file (higher number) is picked up automatically on the next `--deploy` without re-applying already-applied ones.

**Maintainer note:** `shellcheck` wasn't available on the dev machine this
stack was built on. Run it on the target box during Task-6 verification:

```bash
shellcheck scripts/11-install-supabase.sh scripts/lib/supabase-env.sh scripts/lib/supabase-stack-env.sh
```

### Verification results (sandbox, 2026-07-11)

Live end-to-end deploy against a 4GB CX22-class sandbox box. Three fixes
found live and folded back into this repo (see the fix commit for detail —
`scripts/11-install-supabase.sh` deploy 2b, `supabase_render_kong`'s file
mode, and the `storage` service's `PGRST_JWT_SECRET`):

- **Idle RAM ≈ 340MiB total** for the stack (`kong` 165MiB, `storage` 70MiB,
  `db` 83MiB, `rest` 16MiB, `auth` 8MiB) — no box resize needed on a 4GB
  CX22-class box.
- **`supabase_admin` is the image's superuser, not `postgres`.** The
  `supabase/postgres` image does not set `supabase_auth_admin`/
  `authenticator`/`supabase_storage_admin`'s passwords from
  `POSTGRES_PASSWORD` the way upstream `supabase/docker`'s init script does
  (which this repo doesn't ship) — a fresh `--deploy` left auth/rest/storage
  crash-looping with `password authentication failed`. The fix (deploy 2b)
  syncs those three roles' passwords via `ALTER USER ... WITH PASSWORD`,
  connecting as `supabase_admin` over TCP with `PGPASSWORD` — password auth
  is enforced for `supabase_admin` even from inside the `db` container, so a
  plain `psql -U postgres` or socket connection doesn't work here.
- **Storage verifies HS256 keys only.** `storage-api` v1.25.7 (verified
  live) treats `PGRST_JWT_SECRET` as a raw HS256 secret and 403s
  (`signature verification failed`) if handed the JWKS — unlike PostgREST's
  `rest` service, which accepts the JWKS fine. The anon/service keys are
  HS256 so the raw-secret fix verifies those; **ES256 user-token storage
  access is a known follow-up**, not yet covered.
- **`shellcheck` still pending** — not installed on the sandbox box or the
  dev machine this stack was built on. Run
  `apt-get install -y shellcheck` on the box (or wire it into CI) and then
  the command above.

## 7. Backups

Enable Hetzner's automated server backups on the box (Cloud console → the
server → Backups → Enable — 7 rolling snapshots, +20% of server cost). This
covers both the `db-data` and `storage-data` Docker volumes (and everything
else on the box) since they're both on the same disk. There is no
finer-grained restore: **restore = restore the whole-server snapshot**, which
rolls back every service on the box to that point in time, not just Supabase.
(No PITR / offsite `pg_dump` pipeline in scope — see the design doc's Out of
scope section.)
