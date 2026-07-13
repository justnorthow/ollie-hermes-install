# Plan 4 — Apps Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate fieldkit (own IONOS box, full app+DB cutover), HIA + newsletter-studio databases (co-tenant stacks on the jnow prod Ollie box), archive+delete inspection-report-app, then cancel the Metro Structured Holdings Supabase Pro org.

**Spec:** `docs/superpowers/specs/2026-07-13-plan4-apps-migration-design.md` (approved 2026-07-13).

**Architecture:** A new parameterized "app stack" variant of the Plan-3 trimmed Supabase compose stack (multi-stack-per-host: compose project name, container prefix, kong port; optional realtime service) plus a whole-schema migration script (pg_dump schema + discover-all-tables data copy + storage/policy/publication port). Fieldkit additionally gets a Dockerized Next.js app + caddy TLS on its own box. Tasks 1–6 are repo code (TDD); Tasks 7–11 are gated live-ops runbook tasks executed with John.

**Tech Stack:** bash (`set -euo pipefail`, stdin-secrets convention), docker compose v2, supabase/postgres 15.8 + gotrue + postgrest + storage-api + kong 2.8 + supabase/realtime, caddy (host apt, Let's Encrypt), Next.js standalone Docker build.

## Global Constraints

- Repo for Tasks 1–5: `D:\workspaces\jnow\ollie-hermes-install` (commits local on master, unpushed until John's deploy gate — same convention as Plans 1–3).
- Repo for Task 6: `D:\workspaces\metro\Fieldkit-App` (branch `feat/self-host`; do NOT push without John's go — production system).
- Secrets always on stdin, never argv (existing convention; `docker -e` env-forwarding for hosted DB URLs).
- All scripts idempotent + re-runnable; secret preservation is all-or-nothing per the 6-key bundle rule in `scripts/lib/supabase-stack-env.sh:33-55`.
- Image pins only — no `:latest` (pins restamped on every render, never preserved).
- Bash test convention: self-contained `tests/test-<name>.sh` using PATH-shim fakes for docker/psql (see existing `tests/` suites); every test file runs standalone via `bash tests/test-<name>.sh` and prints `PASS`/`FAIL` per case.
- OPS GOTCHA (recurring): never pipe a script containing `docker exec -T` to `bash` over ssh — scp it and run `bash file </dev/null`. PowerShell 5.1 quoting: use base64-piped command files for remote ssh.
- SSH: keys in `D:\workspaces\jnow\_obsidian\SSH Keys for VPS Systems.md`; use `-i <keyfile> -o IdentitiesOnly=yes`. jnow prod box = `ollie@46.224.81.84` (Fleet ed25519 key).
- The existing Ollie stack on the prod box (`~/supabase-stack`, compose project `supabase`, kong 127.0.0.1:8000, container names `supabase-*`) must be untouched by everything in this plan.
- Prod-box RAM guardrail: `free -m` "available" ≥ 700 MB after both new stacks are up, else newsletter-studio's stack comes back down (spec decision).

## Known values (verified during discovery — do not re-derive)

| Item | Value |
|---|---|
| fieldkit hosted ref | `xzqzidnsenjjwobkegii` (us-west-2, ACTIVE) |
| HIA hosted ref ("jnow-workspace" project) | `lzbdghgywqnequxijrlf` (us-east-2, ACTIVE) |
| newsletter-studio hosted ref | `trurniscewfvzihmmnzj` (us-east-2, PAUSED — restore first) |
| inspection-report-app hosted ref | `fcaeulzkbtwysdwhmxgq` (us-east-2, PAUSED — restore first) |
| Pro org | "Metro Structured Holdings", org slug `aeelggtdspbmsmptcejt` |
| fieldkit env names | `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` |
| fieldkit realtime dependency | `postgres_changes` INSERT+UPDATE on `public.sms_logs` filtered by `business_id` (`contexts/messages-context.tsx:66-113`); UPDATE handler reads `payload.old` → replica identity must be ported |
| fieldkit Vercel crons (`vercel.json`) | `/api/cron/sync-metrics` `0 * * * *`; `/api/cron/generate-recommendations` `0 6 * * *`; `/api/cron/send-summaries` `0 8 * * 1` |
| HIA/NS env names | `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` (+ app-level `HIA_SSO_SECRET` / `NEWSLETTER_SSO_SECRET` — unchanged by this plan) |
| HIA storage buckets | `inspection_pdfs`, `amendment_pdfs`, `report_pdfs` |
| Stack ports | prod box: hia → 127.0.0.1:8010, ns → 127.0.0.1:8020; fieldkit box: fieldkit → 127.0.0.1:8000 |
| Public DB hostnames | `sb-hia.jnow.io`, `sb-ns.jnow.io` (DNS-only/grey-cloud + caddy :443 on prod box); `sb.<fieldkit-domain>` (caddy on fieldkit box) |
| From John at Task 10 | fieldkit domain name + DNS host login, IONOS box root access, Vercel env values (`vercel env pull`), hosted session-pooler DB URLs + service keys per project |

## File Structure

**ollie-hermes-install (Tasks 1–5):**

- `templates/supabase-app/docker-compose.yml` — parameterized app-stack compose (create)
- `templates/supabase-app/kong.yml` — app kong template incl. realtime route (create)
- `templates/caddy/Caddyfile.vhost` — one-vhost snippet template (create)
- `scripts/lib/supabase-app-env.sh` — `.env` renderer for app stacks (create; sibling of `supabase-stack-env.sh`)
- `scripts/lib/supabase-app-migrate.sh` — whole-schema migrate lib (create; sources/reuses `supabase-migrate.sh` helpers)
- `scripts/20-install-app-stack.sh` — deploy one app stack (create)
- `scripts/21-migrate-app.sh` — migrate one hosted project into one app stack (create)
- `scripts/22-install-caddy-vhosts.sh` — root-run caddy install + vhost render (create)
- `tests/test-supabase-app-env.sh`, `tests/test-app-stack-compose.sh`, `tests/test-20-install-app-stack.sh`, `tests/test-supabase-app-migrate.sh`, `tests/test-22-caddy-vhosts.sh` (create)
- `docs/runbooks/app-stacks.md` — operator runbook for Tasks 7–11 procedures (create, written per-task)

**Fieldkit-App (Task 6):**

- `next.config.ts` — add `output: 'standalone'` + env-derived storage remotePattern (modify)
- `Dockerfile`, `.dockerignore` — standalone build (create)
- `deploy/box/docker-compose.app.yml` — app + cron services for the box (create)
- `deploy/box/crontab` — 3 cron entries (create)
- `deploy/build-push.ps1` — PC-side image build+push (create)

---

### Task 1: App-stack compose + kong templates

**Files:**
- Create: `templates/supabase-app/docker-compose.yml`
- Create: `templates/supabase-app/kong.yml`
- Test: `tests/test-app-stack-compose.sh`

**Interfaces:**
- Consumes: env vars rendered by Task 2 (`STACK_NAME`, `KONG_PORT`, `POSTGRES_PASSWORD`, `JWT_SECRET`, `GOTRUE_JWT_KEYS`, `JWT_JWKS`, `ANON_KEY`, `SERVICE_ROLE_KEY`, `SUPABASE_PUBLIC_URL`, `SITE_URL`, `REALTIME_ENC_KEY`, `REALTIME_SECRET_KEY_BASE`, `SB_*_IMAGE` pins incl. new `SB_REALTIME_IMAGE`).
- Produces: compose file used by Task 3 via `docker compose -p "$STACK_NAME" -f <dir>/docker-compose.yml --env-file <dir>/.env [--profile realtime] up -d`; kong template consumed by the existing `supabase_render_kong` (`scripts/lib/supabase-env.sh:53`).

Differences vs the Ollie template (`templates/supabase/docker-compose.yml`), each deliberate:
no top-level `name:` (project name comes from `-p`), `container_name: ${STACK_NAME}-*`,
kong binds `127.0.0.1:${KONG_PORT}:8000`, **no** `GOTRUE_HOOK_CUSTOM_ACCESS_TOKEN_*`
(that hook is ollie-core's; the function doesn't exist in app schemas and GoTrue
would fail token issuance), **no** Google OAuth envs (apps are email/password +
admin-managed), plus an optional `realtime` service behind a compose profile.

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# tests/test-app-stack-compose.sh — render checks for templates/supabase-app.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TPL="${DIR}/templates/supabase-app/docker-compose.yml"
KONG="${DIR}/templates/supabase-app/kong.yml"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

[ -f "$TPL" ] && ok "compose template exists" || bad "compose template exists"
[ -f "$KONG" ] && ok "kong template exists" || bad "kong template exists"

grep -q '^name:' "$TPL" && bad "no top-level name: (project set via -p)" || ok "no top-level name:"
grep -q 'container_name: \${STACK_NAME}-db' "$TPL" && ok "db container parameterized" || bad "db container parameterized"
grep -q '127.0.0.1:\${KONG_PORT}:8000' "$TPL" && ok "kong port parameterized" || bad "kong port parameterized"
grep -q 'GOTRUE_HOOK_CUSTOM_ACCESS_TOKEN' "$TPL" && bad "no ollie-core token hook" || ok "no ollie-core token hook"
grep -q 'GOTRUE_EXTERNAL_GOOGLE' "$TPL" && bad "no google oauth envs" || ok "no google oauth envs"
grep -q 'GOTRUE_MAILER_AUTOCONFIRM=true' "$TPL" && ok "autoconfirm on" || bad "autoconfirm on"
grep -q 'KONG_NGINX_HTTP_LARGE_CLIENT_HEADER_BUFFERS=8 24k' "$TPL" && ok "24k header buffers kept" || bad "24k header buffers kept"
grep -Eq 'profiles:.*realtime|profiles: \["realtime"\]' "$TPL" && ok "realtime behind profile" || bad "realtime behind profile"
grep -q 'realtime-dev.supabase-realtime' "$TPL" && ok "realtime tenant network alias" || bad "realtime tenant network alias"
grep -q '/realtime/v1/' "$KONG" && ok "kong realtime route" || bad "kong realtime route"
grep -q '__ANON_KEY__' "$KONG" && ok "kong key placeholders" || bad "kong key placeholders"

# compose config must interpolate cleanly with a full env file
TMP="$(mktemp -d)"
cat > "${TMP}/.env" <<'EOF'
STACK_NAME=hia
KONG_PORT=8010
POSTGRES_PASSWORD=x
JWT_SECRET=x
GOTRUE_JWT_KEYS=[]
JWT_JWKS={}
ANON_KEY=x
SERVICE_ROLE_KEY=x
SUPABASE_PUBLIC_URL=https://sb-hia.jnow.io
SITE_URL=https://hia.example.com
REALTIME_ENC_KEY=0123456789abcdef
REALTIME_SECRET_KEY_BASE=x
SB_DB_IMAGE=supabase/postgres:15.8.1.085
SB_AUTH_IMAGE=supabase/gotrue:v2.177.0
SB_REST_IMAGE=postgrest/postgrest:v12.2.12
SB_STORAGE_IMAGE=supabase/storage-api:v1.25.7
SB_KONG_IMAGE=kong:2.8.1
SB_REALTIME_IMAGE=supabase/realtime:pin
EOF
if command -v docker >/dev/null 2>&1; then
  docker compose -p hia -f "$TPL" --env-file "${TMP}/.env" config >/dev/null 2>&1 \
    && ok "compose config interpolates" || bad "compose config interpolates"
  docker compose -p hia -f "$TPL" --env-file "${TMP}/.env" --profile realtime config 2>/dev/null \
    | grep -q 'hia-realtime' && ok "profile enables realtime container" || bad "profile enables realtime container"
else
  echo "SKIP: docker not available (compose config checks)"
fi
rm -rf "$TMP"
echo; echo "${pass} passed, ${fail} failed"; [ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-app-stack-compose.sh`
Expected: FAIL on "compose template exists" (file missing).

- [ ] **Step 3: Write the compose template**

`templates/supabase-app/docker-compose.yml` — copy `templates/supabase/docker-compose.yml`, then apply exactly these changes:

1. Replace the header comment with an app-stack one referencing this plan, and **delete the `name: supabase` line** (line 7).
2. Every `container_name: supabase-<svc>` → `container_name: ${STACK_NAME}-<svc>`.
3. In `auth.environment`, delete the two `GOTRUE_HOOK_CUSTOM_ACCESS_TOKEN_*` lines and the three `GOTRUE_EXTERNAL_GOOGLE_*` lines (keep `GOTRUE_MAILER_AUTOCONFIRM=true`, `GOTRUE_DISABLE_SIGNUP=false`, `GOTRUE_JWT_ISSUER`, `GOTRUE_JWT_KEYS`).
4. Kong `ports:` → `- "127.0.0.1:${KONG_PORT}:8000"` (comment: public access is caddy → this port).
5. Append the realtime service (after `storage`, before `kong`):

```yaml
  realtime:
    # Optional — enabled per-stack with `--profile realtime` (fieldkit needs
    # postgres_changes for its SMS inbox; HIA/NS stay trimmed). The network
    # alias matters: realtime is multi-tenant and resolves the tenant from the
    # Host header's first label; SEED_SELF_HOST seeds tenant "realtime-dev",
    # and kong's service URL targets http://realtime-dev.supabase-realtime:4000
    # (upstream supabase/docker convention). Each stack has its own compose
    # network, so the alias cannot collide across stacks on one host.
    image: ${SB_REALTIME_IMAGE:?pinned in .env by supabase-app-env.sh}
    container_name: ${STACK_NAME}-realtime
    profiles: ["realtime"]
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    networks:
      default:
        aliases:
          - realtime-dev.supabase-realtime
    environment:
      - PORT=4000
      - DB_HOST=db
      - DB_PORT=5432
      - DB_USER=supabase_admin
      - DB_PASSWORD=${POSTGRES_PASSWORD}
      - DB_NAME=postgres
      - DB_AFTER_CONNECT_QUERY=SET search_path TO _realtime
      - DB_ENC_KEY=${REALTIME_ENC_KEY}
      - API_JWT_SECRET=${JWT_SECRET}
      - SECRET_KEY_BASE=${REALTIME_SECRET_KEY_BASE}
      - ERL_AFLAGS=-proto_dist inet_tcp
      - DNS_NODES=''
      - RLIMIT_NOFILE=10000
      - APP_NAME=realtime
      - SEED_SELF_HOST=true
      - RUN_JANITOR=true
```

`templates/supabase-app/kong.yml` — copy `templates/supabase/kong.yml` and append (route present even for stacks without the realtime container — kong 503s on use, harmless):

```yaml
  - name: realtime-v1-ws
    url: http://realtime-dev.supabase-realtime:4000/socket
    routes:
      - name: realtime-v1-ws
        strip_path: true
        paths: ["/realtime/v1/"]
    plugins:
      - name: cors
      - name: key-auth
        config:
          key_names: ["apikey"]
          hide_credentials: false
      - name: acl
        config:
          hide_groups_header: true
          allow: ["admin", "anon"]
```

(`hide_credentials: false` because supabase-js passes `apikey` as a websocket query param that realtime also reads.)

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-app-stack-compose.sh`
Expected: all PASS (docker checks may SKIP on machines without docker — fine on the Windows dev box, must PASS on a box).

- [ ] **Step 5: Commit**

```bash
git add templates/supabase-app/ tests/test-app-stack-compose.sh
git commit -m "feat(app-stacks): parameterized supabase app compose + kong templates w/ optional realtime"
```

---

### Task 2: App-stack env renderer

**Files:**
- Create: `scripts/lib/supabase-app-env.sh`
- Test: `tests/test-supabase-app-env.sh`

**Interfaces:**
- Consumes: `scripts/lib/gen-supabase-keys.py` (existing 6-key bundle: `postgres_password`, `jwt_secret`, `gotrue_jwt_keys`, `jwt_jwks`, `anon_key`, `service_role_key`) and `supabase_stack_env_val FILE KEY` (re-declared locally to keep the lib self-contained).
- Produces: `render_supabase_app_env OUT OLD` writing the full `.env` for Task 1's template; callers export `STACK_NAME KONG_PORT SUPABASE_PUBLIC_URL SITE_URL` before calling. Also `SB_REALTIME_IMAGE_PIN`.

- [ ] **Step 1: Resolve the realtime image pin**

Run: `curl -s https://raw.githubusercontent.com/supabase/supabase/master/docker/docker-compose.yml | grep -A1 'realtime:' | grep 'image:'`
Expected: one line like `image: supabase/realtime:v2.…` — use that exact tag as `SB_REALTIME_IMAGE_PIN`. Record the tag in the commit message.

- [ ] **Step 2: Write the failing test**

```bash
#!/usr/bin/env bash
# tests/test-supabase-app-env.sh
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${DIR}/scripts/lib/supabase-app-env.sh" || { echo "FAIL: lib sources"; exit 1; }
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# fresh render generates everything
export STACK_NAME=hia KONG_PORT=8010 \
  SUPABASE_PUBLIC_URL=https://sb-hia.jnow.io SITE_URL=https://hia.example.com REALTIME=0
render_supabase_app_env "${TMP}/a.env" "" || bad "fresh render exits 0"
for k in POSTGRES_PASSWORD JWT_SECRET GOTRUE_JWT_KEYS JWT_JWKS ANON_KEY SERVICE_ROLE_KEY \
         REALTIME_ENC_KEY REALTIME_SECRET_KEY_BASE STACK_NAME KONG_PORT \
         SUPABASE_PUBLIC_URL SITE_URL SB_DB_IMAGE SB_REALTIME_IMAGE; do
  grep -q "^${k}=." "${TMP}/a.env" && ok "renders ${k}" || bad "renders ${k}"
done
[ "$(grep -c '^REALTIME_ENC_KEY=.\{16\}$' "${TMP}/a.env")" = "1" ] \
  && ok "enc key is 16 chars" || bad "enc key is 16 chars"
[ "$(stat -c %a "${TMP}/a.env" 2>/dev/null || stat -f %Lp "${TMP}/a.env")" = "600" ] \
  && ok "env is 0600" || bad "env is 0600"

# re-render preserves all secrets, restamps pins
sed -i.bak 's|^SB_DB_IMAGE=.*|SB_DB_IMAGE=stale:0|' "${TMP}/a.env"
OLD_JWT="$(grep '^JWT_SECRET=' "${TMP}/a.env")"
OLD_ENC="$(grep '^REALTIME_ENC_KEY=' "${TMP}/a.env")"
render_supabase_app_env "${TMP}/b.env" "${TMP}/a.env" || bad "re-render exits 0"
[ "$(grep '^JWT_SECRET=' "${TMP}/b.env")" = "$OLD_JWT" ] && ok "JWT preserved" || bad "JWT preserved"
[ "$(grep '^REALTIME_ENC_KEY=' "${TMP}/b.env")" = "$OLD_ENC" ] && ok "realtime enc preserved" || bad "realtime enc preserved"
grep -q '^SB_DB_IMAGE=stale:0' "${TMP}/b.env" && bad "pin restamped" || ok "pin restamped"

# partial JWT bundle refuses (all-or-nothing rule)
grep -v '^ANON_KEY=' "${TMP}/b.env" > "${TMP}/c.env"
render_supabase_app_env "${TMP}/d.env" "${TMP}/c.env" 2>/dev/null && bad "partial bundle refused" || ok "partial bundle refused"

echo; echo "${pass} passed, ${fail} failed"; [ "$fail" -eq 0 ]
```

- [ ] **Step 3: Run test to verify it fails**

Run: `bash tests/test-supabase-app-env.sh`
Expected: `FAIL: lib sources` (file missing).

- [ ] **Step 4: Write the renderer**

`scripts/lib/supabase-app-env.sh`:

```bash
#!/usr/bin/env bash
# supabase-app-env.sh — idempotent .env renderer for APP stacks
# (templates/supabase-app). Sibling of supabase-stack-env.sh: same
# all-or-nothing rule for the 6 interdependent JWT secrets, same
# pins-always-restamped rule. Adds: STACK_NAME/KONG_PORT parameters and the
# two realtime secrets (independent of the JWT bundle — preserved
# individually, generated if absent).
set -uo pipefail

SB_DB_IMAGE_PIN="supabase/postgres:15.8.1.085"
SB_AUTH_IMAGE_PIN="supabase/gotrue:v2.177.0"
SB_REST_IMAGE_PIN="postgrest/postgrest:v12.2.12"
SB_STORAGE_IMAGE_PIN="supabase/storage-api:v1.25.7"
SB_KONG_IMAGE_PIN="kong:2.8.1"
SB_REALTIME_IMAGE_PIN="<TAG FROM STEP 1>"   # e.g. supabase/realtime:v2.x.y

supabase_app_env_val() { # FILE KEY
  [ -f "$1" ] || return 0
  grep -E "^$2=" "$1" | tail -1 | cut -d= -f2- || true
}

_sba_keep() { # KEY OLDENV BUNDLE_JSON_KEY BUNDLE
  local old_v; old_v="$(supabase_app_env_val "$2" "$1")"
  if [ -n "$old_v" ]; then printf '%s' "$old_v"; else
    printf '%s' "$4" | python3 -c "import sys,json;print(json.load(sys.stdin)['$3'])"
  fi
}

_sba_keep_or_gen() { # KEY OLDENV NBYTES  (hex output, 2*NBYTES chars)
  local old_v; old_v="$(supabase_app_env_val "$2" "$1")"
  if [ -n "$old_v" ]; then printf '%s' "$old_v"; else
    python3 -c "import secrets;print(secrets.token_hex($3))"
  fi
}

render_supabase_app_env() { # OUT OLD  (exports: STACK_NAME KONG_PORT SUPABASE_PUBLIC_URL SITE_URL)
  local out="$1" old="${2:-}"
  local bundle="" present=0 missing_keys="" k
  for k in POSTGRES_PASSWORD JWT_SECRET GOTRUE_JWT_KEYS JWT_JWKS ANON_KEY SERVICE_ROLE_KEY; do
    if [ -n "$(supabase_app_env_val "$old" "$k")" ]; then present=$((present + 1))
    else missing_keys="${missing_keys}${missing_keys:+ }$k"; fi
  done
  if [ "$present" -eq 0 ]; then
    bundle="$(python3 "$(dirname "${BASH_SOURCE[0]}")/gen-supabase-keys.py")"
  elif [ "$present" -lt 6 ]; then
    echo "ERROR: $old has some but not all of the 6 interdependent Supabase secrets (missing: $missing_keys) — restore from backup or delete the .env to regenerate the full set." >&2
    return 1
  fi
  local pg jwt gkeys jwks anon srk renc rskb
  pg="$(_sba_keep POSTGRES_PASSWORD "$old" postgres_password "$bundle")"
  jwt="$(_sba_keep JWT_SECRET "$old" jwt_secret "$bundle")"
  gkeys="$(_sba_keep GOTRUE_JWT_KEYS "$old" gotrue_jwt_keys "$bundle")"
  jwks="$(_sba_keep JWT_JWKS "$old" jwt_jwks "$bundle")"
  anon="$(_sba_keep ANON_KEY "$old" anon_key "$bundle")"
  srk="$(_sba_keep SERVICE_ROLE_KEY "$old" service_role_key "$bundle")"
  renc="$(_sba_keep_or_gen REALTIME_ENC_KEY "$old" 8)"        # 16 hex chars (AES key len realtime expects)
  rskb="$(_sba_keep_or_gen REALTIME_SECRET_KEY_BASE "$old" 32)"
  local name port url site_url
  name="${STACK_NAME:-$(supabase_app_env_val "$old" STACK_NAME)}"
  port="${KONG_PORT:-$(supabase_app_env_val "$old" KONG_PORT)}"
  url="${SUPABASE_PUBLIC_URL:-$(supabase_app_env_val "$old" SUPABASE_PUBLIC_URL)}"
  site_url="${SITE_URL:-$(supabase_app_env_val "$old" SITE_URL)}"
  for k in name port url site_url; do
    if [ -z "${!k}" ]; then echo "ERROR: ${k} unset (export STACK_NAME/KONG_PORT/SUPABASE_PUBLIC_URL/SITE_URL or provide in OLD env)" >&2; return 1; fi
  done
  cat > "$out" <<EOF
# Generated by supabase-app-env.sh — re-run 20-install-app-stack.sh to refresh.
STACK_NAME=${name}
KONG_PORT=${port}
POSTGRES_PASSWORD=${pg}
JWT_SECRET=${jwt}
GOTRUE_JWT_KEYS=${gkeys}
JWT_JWKS=${jwks}
ANON_KEY=${anon}
SERVICE_ROLE_KEY=${srk}
REALTIME_ENC_KEY=${renc}
REALTIME_SECRET_KEY_BASE=${rskb}
SUPABASE_PUBLIC_URL=${url}
SITE_URL=${site_url}
SB_DB_IMAGE=${SB_DB_IMAGE_PIN}
SB_AUTH_IMAGE=${SB_AUTH_IMAGE_PIN}
SB_REST_IMAGE=${SB_REST_IMAGE_PIN}
SB_STORAGE_IMAGE=${SB_STORAGE_IMAGE_PIN}
SB_KONG_IMAGE=${SB_KONG_IMAGE_PIN}
SB_REALTIME_IMAGE=${SB_REALTIME_IMAGE_PIN}
EOF
  chmod 600 "$out"
  return 0
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/test-supabase-app-env.sh`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/supabase-app-env.sh tests/test-supabase-app-env.sh
git commit -m "feat(app-stacks): app-stack .env renderer (realtime secrets, stack name/port params; realtime pin <TAG>)"
```

---

### Task 3: `20-install-app-stack.sh` deployer

**Files:**
- Create: `scripts/20-install-app-stack.sh`
- Test: `tests/test-20-install-app-stack.sh`

**Interfaces:**
- Consumes: Task 1 templates, Task 2 `render_supabase_app_env`, existing `supabase_render_kong` + `supabase_validate_inputs` from `scripts/lib/supabase-env.sh`.
- Produces: a running stack at `~/stacks/<STACK_NAME>` (dir 0700, `.env`, `kong.yml`, compose project `<STACK_NAME>`); prints `ANON_KEY`/`SERVICE_ROLE_KEY`/URLs for the app's env repoint. Task 4 requires this to have run first (same preflight convention as `12-migrate-supabase.sh:62-74`).

Stdin (KEY=VALUE lines): `STACK_NAME` (req, `^[a-z][a-z0-9-]*$`), `KONG_PORT` (req, numeric), `SUPABASE_PUBLIC_URL` (req https origin), `SITE_URL` (req https origin), `REALTIME` (optional `1`). Carry-forward re-runs may omit everything except `STACK_NAME` (values re-read from the existing `.env` — same pattern as `11-install-supabase.sh:96-100`).

- [ ] **Step 1: Write the failing test**

PATH-shim `docker` + `curl` fakes (log argv to a file, return canned success), `HOME` pointed at a tempdir; assert: refuses root-style missing STACK_NAME; validates port numeric and name charset; stages `~/stacks/hia` 0700 with `.env` (params present) + `kong.yml` (keys substituted, mode 644); compose invoked with `-p hia -f ~/stacks/hia/docker-compose.yml --env-file ~/stacks/hia/.env up -d`; `--profile realtime` appears iff `REALTIME=1`; role-password `ALTER USER` psql call happens; health-wait curl targets `http://127.0.0.1:8010/auth/v1/health`; idempotent second run preserves `JWT_SECRET`. Full test file:

```bash
#!/usr/bin/env bash
# tests/test-20-install-app-stack.sh — shim-based checks for the app-stack deployer.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
mkdir -p "$T/bin"
cat > "$T/bin/docker" <<'SH'
#!/usr/bin/env bash
echo "docker $*" >> "${DOCKER_LOG}"
# compose exec psql reads stdin — swallow it
[[ "$*" == *" exec "* ]] && cat >/dev/null
exit 0
SH
cat > "$T/bin/curl" <<'SH'
#!/usr/bin/env bash
echo "curl $*" >> "${CURL_LOG}"
echo -n "200"
SH
chmod +x "$T/bin/docker" "$T/bin/curl"
export PATH="$T/bin:$PATH" DOCKER_LOG="$T/docker.log" CURL_LOG="$T/curl.log"

run() { printf '%s\n' "$@" | bash "${DIR}/scripts/20-install-app-stack.sh"; }

# 1. missing STACK_NAME refuses
run "KONG_PORT=8010" "SUPABASE_PUBLIC_URL=https://sb-hia.jnow.io" "SITE_URL=https://hia.example.com" \
  >/dev/null 2>&1 && bad "missing STACK_NAME refused" || ok "missing STACK_NAME refused"

# 2. bad name refuses
run "STACK_NAME=Bad_Name" "KONG_PORT=8010" "SUPABASE_PUBLIC_URL=https://x.example" "SITE_URL=https://y.example" \
  >/dev/null 2>&1 && bad "bad name refused" || ok "bad name refused"

# 3. happy path, no realtime
: > "$DOCKER_LOG"; : > "$CURL_LOG"
run "STACK_NAME=hia" "KONG_PORT=8010" "SUPABASE_PUBLIC_URL=https://sb-hia.jnow.io" "SITE_URL=https://hia.example.com" \
  >/dev/null 2>&1 && ok "deploy exits 0" || bad "deploy exits 0"
[ -f "$HOME/stacks/hia/.env" ] && ok "env staged" || bad "env staged"
[ -f "$HOME/stacks/hia/kong.yml" ] && ok "kong staged" || bad "kong staged"
[ "$(stat -c %a "$HOME/stacks/hia" 2>/dev/null || stat -f %Lp "$HOME/stacks/hia")" = "700" ] \
  && ok "stack dir 0700" || bad "stack dir 0700"
grep -q '^KONG_PORT=8010$' "$HOME/stacks/hia/.env" && ok "port in env" || bad "port in env"
grep -q -- '-p hia -f' "$DOCKER_LOG" && ok "compose project -p hia" || bad "compose project -p hia"
grep -q -- '--profile realtime' "$DOCKER_LOG" && bad "no realtime profile by default" || ok "no realtime profile by default"
grep -q 'ALTER USER supabase_auth_admin' "$DOCKER_LOG" && ok "role passwords synced" || bad "role passwords synced"
grep -q '127.0.0.1:8010/auth/v1/health' "$CURL_LOG" && ok "health wait on kong port" || bad "health wait on kong port"
K1="$(grep '^JWT_SECRET=' "$HOME/stacks/hia/.env")"

# 4. realtime profile
: > "$DOCKER_LOG"
run "STACK_NAME=fieldkit" "KONG_PORT=8000" "SUPABASE_PUBLIC_URL=https://sb.fk.example" "SITE_URL=https://fk.example" "REALTIME=1" \
  >/dev/null 2>&1 && ok "realtime deploy exits 0" || bad "realtime deploy exits 0"
grep -q -- '--profile realtime' "$DOCKER_LOG" && ok "realtime profile passed" || bad "realtime profile passed"

# 5. idempotent re-run (carry-forward, secrets preserved)
run "STACK_NAME=hia" >/dev/null 2>&1 && ok "carry-forward re-run exits 0" || bad "carry-forward re-run exits 0"
[ "$(grep '^JWT_SECRET=' "$HOME/stacks/hia/.env")" = "$K1" ] && ok "secrets preserved" || bad "secrets preserved"

echo; echo "${pass} passed, ${fail} failed"; [ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-20-install-app-stack.sh`
Expected: FAILs (script missing).

- [ ] **Step 3: Write the deployer**

`scripts/20-install-app-stack.sh`:

```bash
#!/usr/bin/env bash
# 20-install-app-stack.sh — stand up ONE parameterized app Supabase stack
# (templates/supabase-app) at ~/stacks/<STACK_NAME>. Multi-stack-per-host safe:
# compose project = STACK_NAME, containers <STACK_NAME>-*, kong on
# 127.0.0.1:<KONG_PORT>. NO orchestrator/dashboard coupling (that's the Ollie
# stack's 11-install-supabase.sh). Schema/data arrive later via
# 21-migrate-app.sh.
#
# Run as: the service user. Idempotent — re-runs preserve secrets, restamp pins.
# Input (stdin, KEY=VALUE lines):
#   STACK_NAME=<^[a-z][a-z0-9-]*$, required>
#   KONG_PORT=<numeric, required first run>
#   SUPABASE_PUBLIC_URL=<https origin, required first run>
#   SITE_URL=<https origin, required first run>
#   REALTIME=1            (optional; enables the realtime service profile)
# Re-runs may pass only STACK_NAME — everything else carries forward from .env.
set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  echo "error: run as the service user, not root" >&2; exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/lib/supabase-env.sh"
. "${SCRIPT_DIR}/lib/supabase-app-env.sh"
TEMPLATES="${SCRIPT_DIR}/../templates/supabase-app"

STACK_NAME="" ; KONG_PORT="" ; SUPABASE_PUBLIC_URL="" ; SITE_URL="" ; REALTIME=""
while IFS='=' read -r k v || [[ -n "${k:-}" ]]; do
  case "${k}" in
    STACK_NAME) STACK_NAME="${v}" ;;
    KONG_PORT) KONG_PORT="${v}" ;;
    SUPABASE_PUBLIC_URL) SUPABASE_PUBLIC_URL="${v}" ;;
    SITE_URL) SITE_URL="${v}" ;;
    REALTIME) REALTIME="${v}" ;;
  esac
done
if [[ ! "${STACK_NAME}" =~ ^[a-z][a-z0-9-]*$ ]]; then
  echo "error: STACK_NAME required, ^[a-z][a-z0-9-]*$ (got: '${STACK_NAME}')" >&2; exit 1
fi
SB_DIR="${SB_DIR:-$HOME/stacks/${STACK_NAME}}"
# carry-forward
[[ -z "${KONG_PORT}" ]] && KONG_PORT="$(supabase_app_env_val "${SB_DIR}/.env" KONG_PORT)"
[[ -z "${SUPABASE_PUBLIC_URL}" ]] && SUPABASE_PUBLIC_URL="$(supabase_app_env_val "${SB_DIR}/.env" SUPABASE_PUBLIC_URL)"
[[ -z "${SITE_URL}" ]] && SITE_URL="$(supabase_app_env_val "${SB_DIR}/.env" SITE_URL)"
if [[ ! "${KONG_PORT}" =~ ^[0-9]+$ ]]; then
  echo "error: KONG_PORT required (numeric), got '${KONG_PORT}'" >&2; exit 1
fi
supabase_validate_inputs "${SUPABASE_PUBLIC_URL}" "placeholder-key-not-validated-here" || exit 1
supabase_validate_inputs "${SITE_URL}" "placeholder-key-not-validated-here" || exit 1

PROFILE_ARGS=()
[[ "${REALTIME}" == "1" ]] && PROFILE_ARGS=(--profile realtime)
# carry realtime choice forward: once enabled, keep enabling on re-runs
if [[ -z "${REALTIME}" && -f "${SB_DIR}/.realtime" ]]; then PROFILE_ARGS=(--profile realtime); fi

echo "==> app-stack 1: stage ${SB_DIR}"
mkdir -p "${SB_DIR}"
chmod 700 "${SB_DIR}"
cp "${TEMPLATES}/docker-compose.yml" "${SB_DIR}/docker-compose.yml"
ENV_OLD=""
if [[ -f "${SB_DIR}/.env" ]]; then ENV_OLD="$(mktemp)"; cp "${SB_DIR}/.env" "${ENV_OLD}"; fi
export STACK_NAME KONG_PORT SUPABASE_PUBLIC_URL SITE_URL
render_supabase_app_env "${SB_DIR}/.env" "${ENV_OLD}"
[[ -n "${ENV_OLD}" ]] && rm -f "${ENV_OLD}"
[[ "${REALTIME}" == "1" ]] && touch "${SB_DIR}/.realtime"
ANON_KEY="$(supabase_app_env_val "${SB_DIR}/.env" ANON_KEY)"
SERVICE_ROLE_KEY="$(supabase_app_env_val "${SB_DIR}/.env" SERVICE_ROLE_KEY)"
supabase_render_kong "${TEMPLATES}/kong.yml" "${SB_DIR}/kong.yml" "${ANON_KEY}" "${SERVICE_ROLE_KEY}"

COMPOSE=(docker compose -p "${STACK_NAME}" -f "${SB_DIR}/docker-compose.yml" --env-file "${SB_DIR}/.env" "${PROFILE_ARGS[@]}")

echo "==> app-stack 2: docker compose up -d (project ${STACK_NAME})"
"${COMPOSE[@]}" pull --quiet
"${COMPOSE[@]}" up -d

echo "==> app-stack 3: sync internal role passwords"
SB_PGPASS="$(supabase_app_env_val "${SB_DIR}/.env" POSTGRES_PASSWORD)"
"${COMPOSE[@]}" exec -T -e PGPASSWORD="${SB_PGPASS}" db psql -h 127.0.0.1 -U supabase_admin -d postgres \
  -c "ALTER USER supabase_auth_admin WITH PASSWORD '${SB_PGPASS}';" \
  -c "ALTER USER authenticator WITH PASSWORD '${SB_PGPASS}';" \
  -c "ALTER USER supabase_storage_admin WITH PASSWORD '${SB_PGPASS}';"

echo "==> app-stack 4: wait for auth healthy via kong :${KONG_PORT}"
set +e
CODE=""
for i in $(seq 1 30); do
  CODE="$(curl -s -o /dev/null -w '%{http_code}' -m 5 \
    -H "apikey: ${ANON_KEY}" "http://127.0.0.1:${KONG_PORT}/auth/v1/health")"
  [[ "${CODE}" == "200" ]] && break
  sleep 2
done
set -e
if [[ "${CODE:-}" != "200" ]]; then
  echo "error: auth /health did not come up (last HTTP ${CODE:-none}) — check: docker compose -p ${STACK_NAME} -f ${SB_DIR}/docker-compose.yml logs auth kong" >&2
  exit 1
fi
echo "    auth /health → 200 ✓"

echo
echo "✓ app stack '${STACK_NAME}' up (kong 127.0.0.1:${KONG_PORT})."
echo "  App env values (set on Railway/compose after 21-migrate-app.sh):"
echo "  NEXT_PUBLIC_SUPABASE_URL=${SUPABASE_PUBLIC_URL}"
echo "  NEXT_PUBLIC_SUPABASE_ANON_KEY=${ANON_KEY}"
echo "  SUPABASE_SERVICE_ROLE_KEY=${SERVICE_ROLE_KEY}"
echo "  Next: schema+data via 21-migrate-app.sh; public TLS via 22-install-caddy-vhosts.sh."
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-20-install-app-stack.sh`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/20-install-app-stack.sh tests/test-20-install-app-stack.sh
git commit -m "feat(app-stacks): 20-install-app-stack.sh — multi-stack deployer (project/port params, optional realtime)"
```

---

### Task 4: Whole-schema migration — lib + `21-migrate-app.sh`

**Files:**
- Create: `scripts/lib/supabase-app-migrate.sh`
- Create: `scripts/21-migrate-app.sh`
- Test: `tests/test-supabase-app-migrate.sh`

**Interfaces:**
- Consumes: `migrate_src_psql` / `migrate_dst_psql` runner contract from `scripts/lib/supabase-migrate.sh` (the caller defines them; the lib also reuses `sb_fix_sequences` and `sb_sync_bucket` from that file — source both libs). New runner required: `migrate_src_pgdump` (pg_dump against the hosted DB).
- Produces: functions `sb_app_dump_schema`, `sb_app_list_tables`, `sb_app_copy_data`, `sb_app_port_storage`, `sb_app_port_realtime_publication`; script `21-migrate-app.sh` orchestrating them.

Approach (spec §Migration): **pg_dump the hosted public schema** (schema-only, `--no-owner`, ACLs kept so anon/authenticated grants + RLS survive) instead of replaying app repo migrations — guarantees parity for 165-file fieldkit. Data copy discovers all public base tables from the SOURCE and copies with FK triggers disabled (`session_replication_role=replica`) so ordering doesn't matter. auth.users/identities copy reuses the Plan-3 UUID-preserving pattern. Storage: discover buckets (with their `public` flag), sync objects, port `storage.objects` RLS policies generated from `pg_policies`. Realtime: port `supabase_realtime` publication membership + replica identity.

- [ ] **Step 1: Write the failing test**

Shim `migrate_src_psql`/`migrate_dst_psql`/`migrate_src_pgdump`/`migrate_curl` as bash functions that log calls and return canned outputs; assert per function below. Full test file:

```bash
#!/usr/bin/env bash
# tests/test-supabase-app-migrate.sh
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${DIR}/scripts/lib/supabase-migrate.sh"
. "${DIR}/scripts/lib/supabase-app-migrate.sh" || { echo "FAIL: lib sources"; exit 1; }
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
LOG="$(mktemp)"; trap 'rm -f "$LOG"' EXIT

# ---- sb_app_list_tables: reads source base tables ----
migrate_src_psql() { echo "src_psql $*" >> "$LOG"; printf 'businesses\nsms_logs\n'; }
migrate_dst_psql() { echo "dst_psql $*" >> "$LOG"; cat >/dev/null 2>&1 || true; }
OUT="$(sb_app_list_tables)"
[ "$OUT" = "businesses
sms_logs" ] && ok "list_tables returns source tables" || bad "list_tables returns source tables"

# ---- sb_app_dump_schema: pipes pg_dump into dst ----
migrate_src_pgdump() { echo "pgdump $*" >> "$LOG"; echo "CREATE TABLE public.x();"; }
migrate_dst_psql() { echo "dst_psql $*" >> "$LOG"; cat > /dev/null; }
sb_app_dump_schema && ok "dump_schema exits 0" || bad "dump_schema exits 0"
grep -q 'pgdump --schema-only --schema=public --no-owner' "$LOG" \
  && ok "pg_dump flags" || bad "pg_dump flags"

# ---- sb_app_copy_data: truncate-all + replica-mode copy + count verify ----
: > "$LOG"
migrate_src_psql() {
  echo "src_psql $*" >> "$LOG"
  case "$*" in
    *"copy ("*) echo "row1" ;;
    *count*) echo "1" ;;
    *) echo "" ;;
  esac
}
migrate_dst_psql() {
  echo "dst_psql $*" >> "$LOG"
  case "$*" in
    *count*) cat >/dev/null 2>&1 || true; echo "1" ;;
    *) cat > /dev/null 2>&1 || true ;;
  esac
}
sb_common_columns() { echo "id,name"; }   # isolate from column probing
sb_app_copy_data "businesses sms_logs" && ok "copy_data exits 0" || bad "copy_data exits 0"
grep -q 'truncate table public.businesses, public.sms_logs cascade' "$LOG" \
  && ok "single truncate-all cascade" || bad "single truncate-all cascade"
grep -q "session_replication_role" "$LOG" && ok "replica mode set" || bad "replica mode set"

# ---- count mismatch fails ----
migrate_dst_psql() { echo "dst_psql $*" >> "$LOG"; case "$*" in *count*) cat >/dev/null 2>&1||true; echo "0";; *) cat >/dev/null 2>&1||true;; esac; }
sb_app_copy_data "businesses" 2>/dev/null && bad "count mismatch fails" || ok "count mismatch fails"

# ---- sb_app_port_storage: buckets discovered with public flag; policies ported ----
: > "$LOG"
migrate_src_psql() {
  echo "src_psql $*" >> "$LOG"
  case "$*" in
    *from\ storage.buckets*) printf 'inspection_pdfs\tfalse\nreport_pdfs\ttrue\n' ;;
    *pg_policies*) echo "create policy \"p1\" on storage.objects for select to authenticated using (true);" ;;
    *storage.objects*) printf '' ;;   # no objects to sync in this test
    *) echo "" ;;
  esac
}
migrate_dst_psql() { echo "dst_psql $*" >> "$LOG"; cat >/dev/null 2>&1 || true; }
migrate_curl() { echo "curl $*" >> "$LOG"; echo -n "200"; }
sb_app_port_storage "https://src.example" "srckey" "http://127.0.0.1:8010" "dstkey" \
  && ok "port_storage exits 0" || bad "port_storage exits 0"
grep -q '"public":false' "$LOG" && ok "bucket public flag honored" || bad "bucket public flag honored"
grep -q 'create policy' "$LOG" && ok "policies ported" || bad "policies ported"

# ---- sb_app_port_realtime_publication ----
: > "$LOG"
migrate_src_psql() {
  echo "src_psql $*" >> "$LOG"
  case "$*" in
    *pg_publication_tables*) printf 'public\tsms_logs\n' ;;
    *relreplident*) echo "f" ;;
    *) echo "" ;;
  esac
}
migrate_dst_psql() { echo "dst_psql $*" >> "$LOG"; cat >/dev/null 2>&1 || true; }
sb_app_port_realtime_publication && ok "port_publication exits 0" || bad "port_publication exits 0"
grep -q 'create publication supabase_realtime' "$LOG" && ok "publication ensured" || bad "publication ensured"
grep -q 'add table public.sms_logs' "$LOG" && ok "table added to publication" || bad "table added to publication"
grep -q 'replica identity full' "$LOG" && ok "replica identity ported" || bad "replica identity ported"

echo; echo "${pass} passed, ${fail} failed"; [ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-supabase-app-migrate.sh`
Expected: `FAIL: lib sources`.

- [ ] **Step 3: Write the lib**

`scripts/lib/supabase-app-migrate.sh`:

```bash
#!/usr/bin/env bash
# supabase-app-migrate.sh — testable core for 21-migrate-app.sh. Source AFTER
# supabase-migrate.sh (reuses sb_common_columns, sb_fix_sequences,
# sb_sync_bucket, migrate_curl default).
#
# Callers MUST define: migrate_src_psql, migrate_dst_psql (see
# supabase-migrate.sh contract) and migrate_src_pgdump (pg_dump-alike against
# the hosted DB; receives pg_dump args, writes SQL to stdout).
set -uo pipefail

# Whole public schema, structure only. --no-owner: local restore runs as
# supabase_admin and hosted role owners (postgres, supabase_admin variants)
# don't map 1:1. ACLs are KEPT (no --no-privileges) — anon/authenticated/
# service_role grants and RLS enable flags must survive; those roles exist in
# both hosted and self-hosted images.
sb_app_dump_schema() {
  migrate_src_pgdump --schema-only --schema=public --no-owner \
    | migrate_dst_psql -v ON_ERROR_STOP=1 || return 1
  echo "    public schema restored"
}

sb_app_list_tables() {
  migrate_src_psql -tAc "select table_name from information_schema.tables where table_schema='public' and table_type='BASE TABLE' order by table_name"
}

# Copy every listed table with FK triggers disabled on the destination so
# topological order doesn't matter. One truncate-all first (cascade), then a
# per-table COPY inside a session that sets session_replication_role=replica
# (psql executes multiple -c in ONE session/connection).
sb_app_copy_data() { # "table1 table2 ..."
  local tables="$1" t cols src_n dst_n qualified=""
  for t in $tables; do qualified="${qualified}${qualified:+, }public.${t}"; done
  migrate_dst_psql -c "truncate table ${qualified} cascade;" </dev/null || return 1
  for t in $tables; do
    cols="$(sb_common_columns public "$t")" || return 1
    migrate_src_psql -c "copy (select ${cols} from public.${t}) to stdout" \
      | migrate_dst_psql -c "set session_replication_role = replica;" \
                         -c "copy public.${t} (${cols}) from stdin" || return 1
    src_n="$(migrate_src_psql -tAc "select count(*) from public.${t}")" || return 1
    dst_n="$(migrate_dst_psql -tAc "select count(*) from public.${t}" </dev/null)" || return 1
    if [[ "$src_n" != "$dst_n" ]]; then
      echo "error: public.${t} row count mismatch (src=${src_n} dst=${dst_n})" >&2; return 1
    fi
    echo "    public.${t}: ${dst_n} rows"
    sb_fix_sequences public "$t" || return 1
  done
}

# Buckets (with their public flag) + objects + storage.objects RLS policies.
sb_app_port_storage() { # SRC_URL SRC_KEY DST_URL DST_KEY
  local src="$1" src_key="$2" dst="$3" dst_key="$4" line bucket is_public code ddl
  while IFS=$'\t' read -r bucket is_public; do
    [[ -z "$bucket" ]] && continue
    code="$(migrate_curl -s -o /dev/null -w '%{http_code}' -X POST "${dst%/}/storage/v1/bucket" \
      -H "apikey: ${dst_key}" -H "Authorization: Bearer ${dst_key}" \
      -H "Content-Type: application/json" \
      -d "{\"id\":\"${bucket}\",\"name\":\"${bucket}\",\"public\":${is_public}}")"
    case "${code}" in
      200|201|400|409) ;;
      *) echo "error: bucket ensure failed for ${bucket} (HTTP ${code})" >&2; return 1 ;;
    esac
    sb_sync_bucket "$src" "$src_key" "$dst" "$dst_key" "$bucket" || return 1
  done < <(migrate_src_psql -tAc "select id || E'\t' || public::text from storage.buckets order by id")
  # Port storage.objects policies: generate CREATE POLICY DDL from the source's
  # pg_policies (qual is null for INSERT-only policies; with_check null for
  # SELECT/DELETE). Drop-first for idempotent re-runs.
  ddl="$(migrate_src_psql -tAc "
    select 'drop policy if exists ' || quote_ident(policyname) || ' on storage.objects; '
        || 'create policy ' || quote_ident(policyname) || ' on storage.objects'
        || ' for ' || lower(cmd)
        || ' to ' || array_to_string(roles, ', ')
        || coalesce(' using (' || qual || ')', '')
        || coalesce(' with check (' || with_check || ')', '')
        || ';'
    from pg_policies where schemaname='storage' and tablename='objects'")" || return 1
  if [[ -n "${ddl//[[:space:]]/}" ]]; then
    printf '%s\n' "$ddl" | migrate_dst_psql -v ON_ERROR_STOP=1 || return 1
    echo "    storage.objects policies ported"
  else
    echo "    no storage.objects policies on source"
  fi
}

# supabase_realtime publication membership + replica identity, mirrored from
# the source (postgres_changes needs the table in the publication; UPDATE
# events with old-record payloads need replica identity full).
sb_app_port_realtime_publication() {
  local schema table ident
  migrate_dst_psql -c "do \$\$ begin if not exists (select 1 from pg_publication where pubname='supabase_realtime') then execute 'create publication supabase_realtime'; end if; end \$\$;" </dev/null || return 1
  while IFS=$'\t' read -r schema table; do
    [[ -z "$table" ]] && continue
    migrate_dst_psql -c "do \$\$ begin if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='${schema}' and tablename='${table}') then execute 'alter publication supabase_realtime add table ${schema}.${table}'; end if; end \$\$;" </dev/null || return 1
    echo "    publication += ${schema}.${table}"
    ident="$(migrate_src_psql -tAc "select relreplident from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='${schema}' and c.relname='${table}'")" || return 1
    if [[ "$ident" == "f" ]]; then
      migrate_dst_psql -c "alter table ${schema}.${table} replica identity full;" </dev/null || return 1
      echo "    replica identity full → ${schema}.${table}"
    fi
  done < <(migrate_src_psql -tAc "select schemaname || E'\t' || tablename from pg_publication_tables where pubname='supabase_realtime'")
}
```

- [ ] **Step 4: Write `scripts/21-migrate-app.sh`**

```bash
#!/usr/bin/env bash
# 21-migrate-app.sh — migrate ONE hosted Supabase project (whole public
# schema + data + auth users + storage + realtime publication) into ONE local
# app stack deployed by 20-install-app-stack.sh. The HOSTED side is only ever
# read. Idempotent: schema restore is additive-or-noop on re-runs (objects
# exist), data copy is truncate-first, storage sync is upsert.
#
# Input (stdin, KEY=VALUE lines — secrets never in argv):
#   STACK_NAME=<stack deployed under ~/stacks/<name>>
#   HOSTED_DB_URL=postgresql://postgres.<ref>:<pass>@…pooler.supabase.com:5432/postgres
#   HOSTED_SUPABASE_URL=https://<ref>.supabase.co
#   HOSTED_SERVICE_ROLE_KEY=<service role key>
set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  echo "error: run as the service user, not root" >&2; exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/lib/supabase-env.sh"
. "${SCRIPT_DIR}/lib/supabase-app-env.sh"
. "${SCRIPT_DIR}/lib/supabase-migrate.sh"
. "${SCRIPT_DIR}/lib/supabase-app-migrate.sh"

MIGRATE_PG_IMAGE="${MIGRATE_PG_IMAGE:-postgres:17-alpine}"
AUTH_TABLES=(users identities)

STACK_NAME="" ; HOSTED_DB_URL="" ; HOSTED_SUPABASE_URL="" ; HOSTED_SERVICE_ROLE_KEY=""
while IFS='=' read -r k v || [[ -n "${k:-}" ]]; do
  case "${k}" in
    STACK_NAME) STACK_NAME="${v}" ;;
    HOSTED_DB_URL) HOSTED_DB_URL="${v}" ;;
    HOSTED_SUPABASE_URL) HOSTED_SUPABASE_URL="${v}" ;;
    HOSTED_SERVICE_ROLE_KEY) HOSTED_SERVICE_ROLE_KEY="${v}" ;;
  esac
done
MISSING=""
[[ -z "${STACK_NAME}" ]] && MISSING="${MISSING} STACK_NAME"
[[ -z "${HOSTED_DB_URL}" ]] && MISSING="${MISSING} HOSTED_DB_URL"
[[ -z "${HOSTED_SUPABASE_URL}" ]] && MISSING="${MISSING} HOSTED_SUPABASE_URL"
[[ -z "${HOSTED_SERVICE_ROLE_KEY}" ]] && MISSING="${MISSING} HOSTED_SERVICE_ROLE_KEY"
if [[ -n "${MISSING}" ]]; then
  echo "error: missing required stdin key(s):${MISSING}" >&2; exit 1
fi
export HOSTED_DB_URL

SB_DIR="${SB_DIR:-$HOME/stacks/${STACK_NAME}}"
echo "==> app-migrate 1: preflight (${SB_DIR})"
if [[ ! -f "${SB_DIR}/.env" ]]; then
  echo "error: ${SB_DIR}/.env not found — deploy first: 20-install-app-stack.sh" >&2; exit 1
fi
KONG_PORT="$(supabase_app_env_val "${SB_DIR}/.env" KONG_PORT)"
LOCAL_PUBLIC_URL="$(supabase_app_env_val "${SB_DIR}/.env" SUPABASE_PUBLIC_URL)"
LOCAL_ANON_KEY="$(supabase_app_env_val "${SB_DIR}/.env" ANON_KEY)"
LOCAL_SERVICE_KEY="$(supabase_app_env_val "${SB_DIR}/.env" SERVICE_ROLE_KEY)"
LOCAL_PGPASS="$(supabase_app_env_val "${SB_DIR}/.env" POSTGRES_PASSWORD)"
for v in KONG_PORT LOCAL_PUBLIC_URL LOCAL_ANON_KEY LOCAL_SERVICE_KEY LOCAL_PGPASS; do
  if [[ -z "${!v}" ]]; then echo "error: ${v} empty in ${SB_DIR}/.env" >&2; exit 1; fi
done
if [[ "${MIGRATE_PREFLIGHT_ONLY:-0}" == "1" ]]; then echo "    preflight OK"; exit 0; fi

migrate_src_psql() {
  docker run --rm -i --network host -e HOSTED_DB_URL "${MIGRATE_PG_IMAGE}" \
    sh -c 'exec psql "$HOSTED_DB_URL" -v ON_ERROR_STOP=1 "$@"' -- "$@"
}
migrate_src_pgdump() {
  docker run --rm -i --network host -e HOSTED_DB_URL "${MIGRATE_PG_IMAGE}" \
    sh -c 'exec pg_dump "$HOSTED_DB_URL" "$@"' -- "$@"
}
migrate_dst_psql() {
  docker compose -p "${STACK_NAME}" -f "${SB_DIR}/docker-compose.yml" --env-file "${SB_DIR}/.env" \
    exec -T -e PGPASSWORD="${LOCAL_PGPASS}" db \
    psql -h 127.0.0.1 -U supabase_admin -d postgres -v ON_ERROR_STOP=1 "$@" </dev/stdin
}

echo "==> app-migrate 2: connectivity"
SRC_VER="$(migrate_src_psql -tAc 'show server_version' </dev/null)" \
  || { echo "error: cannot reach hosted DB — check HOSTED_DB_URL (Session pooler string; project must be RESTORED if paused)" >&2; exit 1; }
echo "    hosted postgres ${SRC_VER} ✓"
migrate_dst_psql -tAc 'select 1' </dev/null >/dev/null \
  || { echo "error: local ${STACK_NAME} db not reachable" >&2; exit 1; }

echo "==> app-migrate 3: restore public schema (pg_dump --schema-only)"
sb_app_dump_schema

echo "==> app-migrate 4: copy auth (UUID-preserving)"
for t in "${AUTH_TABLES[@]}"; do sb_copy_table auth "$t"; sb_fix_sequences auth "$t"; done

echo "==> app-migrate 5: copy public data (FK-order-free, count-verified)"
TABLES="$(sb_app_list_tables | tr '\n' ' ')"
echo "    tables: ${TABLES}"
sb_app_copy_data "${TABLES}"

echo "==> app-migrate 6: storage (buckets + objects + RLS policies)"
sb_app_port_storage "${HOSTED_SUPABASE_URL}" "${HOSTED_SERVICE_ROLE_KEY}" \
  "http://127.0.0.1:${KONG_PORT}" "${LOCAL_SERVICE_KEY}"

echo "==> app-migrate 7: realtime publication + replica identity"
sb_app_port_realtime_publication

echo "==> app-migrate 8: verify"
CODE="$(curl -s -o /dev/null -w '%{http_code}' -m 15 \
  -H "apikey: ${LOCAL_SERVICE_KEY}" -H "Authorization: Bearer ${LOCAL_SERVICE_KEY}" \
  "http://127.0.0.1:${KONG_PORT}/rest/v1/?limit=1" || echo 000)"
[[ "${CODE}" == "200" ]] || { echo "error: local REST probe HTTP ${CODE}" >&2; exit 1; }
USERS_N="$(migrate_dst_psql -tAc 'select count(*) from auth.users' </dev/null)"
echo "    auth.users rows: ${USERS_N}"

echo
echo "✓ '${STACK_NAME}' migrated from ${HOSTED_SUPABASE_URL}."
echo "  Now point the app at it:"
echo "  NEXT_PUBLIC_SUPABASE_URL=${LOCAL_PUBLIC_URL}"
echo "  NEXT_PUBLIC_SUPABASE_ANON_KEY=${LOCAL_ANON_KEY}"
echo "  SUPABASE_SERVICE_ROLE_KEY=${LOCAL_SERVICE_KEY}"
echo "  Rollback = point the app back at ${HOSTED_SUPABASE_URL} (hosted project stays PAUSED, not deleted, until soak passes)."
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/test-supabase-app-migrate.sh`
Expected: all PASS.

- [ ] **Step 6: Run ALL suites (regression)**

Run: `for f in tests/test-*.sh; do echo "== $f"; bash "$f" || exit 1; done`
Expected: every suite green.

- [ ] **Step 7: Commit**

```bash
git add scripts/lib/supabase-app-migrate.sh scripts/21-migrate-app.sh tests/test-supabase-app-migrate.sh
git commit -m "feat(app-stacks): 21-migrate-app.sh — whole-schema migrate (pg_dump schema, replica-mode data copy, storage+policies, realtime publication)"
```

---

### Task 5: Caddy vhost installer

**Files:**
- Create: `scripts/22-install-caddy-vhosts.sh`
- Create: `templates/caddy/Caddyfile.vhost`
- Test: `tests/test-22-caddy-vhosts.sh`

**Interfaces:**
- Consumes: nothing from other tasks (root-run, standalone).
- Produces: `/etc/caddy/Caddyfile` rendering one reverse-proxy block per `host:port` arg; used by ops Tasks 7/8/10.

Runs as **root** (deliberate exception — caddy is a system service; documented in the runbook). Idempotent: re-running with the same args rewrites the same file and reloads.

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# tests/test-22-caddy-vhosts.sh — render-only checks (no root, no apt): the
# script must support CADDY_RENDER_ONLY=1 OUT=<file> to render and exit.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

CADDY_RENDER_ONLY=1 OUT="$T/Caddyfile" \
  bash "${DIR}/scripts/22-install-caddy-vhosts.sh" \
  sb-hia.jnow.io:8010 sb-ns.jnow.io:8020 >/dev/null 2>&1 \
  && ok "render exits 0" || bad "render exits 0"
grep -q '^sb-hia.jnow.io {' "$T/Caddyfile" && ok "vhost 1 block" || bad "vhost 1 block"
grep -q 'reverse_proxy 127.0.0.1:8010' "$T/Caddyfile" && ok "vhost 1 proxy" || bad "vhost 1 proxy"
grep -q '^sb-ns.jnow.io {' "$T/Caddyfile" && ok "vhost 2 block" || bad "vhost 2 block"
# no args refuses
CADDY_RENDER_ONLY=1 OUT="$T/x" bash "${DIR}/scripts/22-install-caddy-vhosts.sh" >/dev/null 2>&1 \
  && bad "no-args refused" || ok "no-args refused"
# bad arg refuses
CADDY_RENDER_ONLY=1 OUT="$T/x" bash "${DIR}/scripts/22-install-caddy-vhosts.sh" "no-port-here" >/dev/null 2>&1 \
  && bad "bad arg refused" || ok "bad arg refused"

echo; echo "${pass} passed, ${fail} failed"; [ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-22-caddy-vhosts.sh` — Expected: FAILs (script missing).

- [ ] **Step 3: Write template + script**

`templates/caddy/Caddyfile.vhost`:

```
__HOST__ {
	encode gzip
	reverse_proxy 127.0.0.1:__PORT__
}
```

`scripts/22-install-caddy-vhosts.sh`:

```bash
#!/usr/bin/env bash
# 22-install-caddy-vhosts.sh — install caddy (apt, official repo) and render
# /etc/caddy/Caddyfile with one HTTPS reverse-proxy vhost per HOST:PORT arg.
# Let's Encrypt certs are automatic (domains must already resolve to this box,
# DNS-only/grey-cloud — no Cloudflare proxy). Run as root. Idempotent.
#
# Usage: 22-install-caddy-vhosts.sh sb-hia.jnow.io:8010 [sb-ns.jnow.io:8020 …]
# Test hook: CADDY_RENDER_ONLY=1 OUT=<file> renders the Caddyfile and exits.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPL="${SCRIPT_DIR}/../templates/caddy/Caddyfile.vhost"

if [[ $# -lt 1 ]]; then
  echo "usage: $0 HOST:PORT [HOST:PORT …]" >&2; exit 1
fi
for a in "$@"; do
  if [[ ! "$a" =~ ^[a-z0-9.-]+:[0-9]+$ ]]; then
    echo "error: bad vhost arg '$a' (want host:port)" >&2; exit 1
  fi
done

render() { # OUT
  local out="$1" a host port
  : > "$out"
  for a in "$@"; do :; done   # (args re-read below from the global list)
  for a in "${VHOSTS[@]}"; do
    host="${a%%:*}"; port="${a##*:}"
    sed -e "s|__HOST__|${host}|" -e "s|__PORT__|${port}|" "$TPL" >> "$out"
    echo >> "$out"
  done
}
VHOSTS=("$@")

if [[ "${CADDY_RENDER_ONLY:-0}" == "1" ]]; then
  render "${OUT:?OUT required with CADDY_RENDER_ONLY}"
  exit 0
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "error: run as root (installs a system service)" >&2; exit 1
fi

if ! command -v caddy >/dev/null 2>&1; then
  echo "==> caddy 1: install (official apt repo)"
  apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update && apt-get install -y caddy
fi

echo "==> caddy 2: render /etc/caddy/Caddyfile (${#VHOSTS[@]} vhost(s))"
[[ -f /etc/caddy/Caddyfile ]] && cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.bak-$(date +%Y%m%d-%H%M%S)"
render /etc/caddy/Caddyfile
caddy validate --config /etc/caddy/Caddyfile

echo "==> caddy 3: enable + reload"
systemctl enable --now caddy
systemctl reload caddy
echo "✓ caddy serving: ${VHOSTS[*]} (certs auto-issue on first request — DNS must already point here; open :80 AND :443 in the cloud firewall)"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-22-caddy-vhosts.sh` — Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/22-install-caddy-vhosts.sh templates/caddy/ tests/test-22-caddy-vhosts.sh
git commit -m "feat(app-stacks): 22-install-caddy-vhosts.sh — caddy TLS for grey-cloud stack endpoints"
```

---

### Task 6: Fieldkit-App self-host packaging

**Repo:** `D:\workspaces\metro\Fieldkit-App`, branch `feat/self-host` (create from master; do NOT push/merge without John).

**Files:**
- Modify: `next.config.ts` (add `output: 'standalone'`; env-derived storage remotePattern)
- Create: `Dockerfile`, `.dockerignore`
- Create: `deploy/box/docker-compose.app.yml`, `deploy/box/crontab`
- Create: `deploy/build-push.ps1`

**Interfaces:**
- Consumes: env at runtime — `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`, plus the full Vercel env set pulled in Task 10 (`vercel env pull`). NOTE: `NEXT_PUBLIC_*` values are **baked at build time** in Next.js — the PC-side build must run with the production values in `.env.production.local`.
- Produces: image `justnorthow/fieldkit-app` (digest-pinned) consumed by Task 10's compose on the box.

- [ ] **Step 1: Branch + failing check**

```bash
cd /d/workspaces/metro/Fieldkit-App && git checkout -b feat/self-host
grep -q "output: 'standalone'" next.config.ts && echo UNEXPECTED || echo "confirmed missing"
```
Expected: `confirmed missing`.

- [ ] **Step 2: Edit `next.config.ts`**

In the `nextConfig` object (`next.config.ts:12-27`): add `output: 'standalone',` as the first key, and replace the `images.remotePatterns` array with one that also admits the self-hosted storage host, derived from the build-time env:

```typescript
const supabaseHost = process.env.NEXT_PUBLIC_SUPABASE_URL
  ? new URL(process.env.NEXT_PUBLIC_SUPABASE_URL).hostname
  : undefined;

const nextConfig: NextConfig = {
  output: 'standalone',
  images: {
    remotePatterns: [
      {
        protocol: 'https',
        hostname: '*.supabase.co',
        pathname: '/storage/v1/object/public/**',
      },
      ...(supabaseHost
        ? [{
            protocol: 'https' as const,
            hostname: supabaseHost,
            pathname: '/storage/v1/object/public/**',
          }]
        : []),
    ],
  },
  experimental: {
    serverActions: {
      bodySizeLimit: '10mb',
    },
  },
};
```

- [ ] **Step 3: Create `Dockerfile` + `.dockerignore`**

`Dockerfile`:

```dockerfile
# Fieldkit self-host image — Next.js standalone. Build on the dev PC with the
# production env present (NEXT_PUBLIC_* are baked at build time):
#   deploy/build-push.ps1
FROM node:22-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci

FROM node:22-alpine AS builder
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .
# .env.production.local (gitignored) must be present at build time — the
# build-push script asserts it. Sentry sourcemap upload runs iff SENTRY_* set.
RUN npm run build

FROM node:22-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production PORT=3000 HOSTNAME=0.0.0.0
RUN addgroup -S nodejs && adduser -S nextjs -G nodejs
COPY --from=builder /app/public ./public
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static
USER nextjs
EXPOSE 3000
CMD ["node", "server.js"]
```

`.dockerignore`:

```
.git
.next
node_modules
.vercel
tests
playwright-report
*.md
```

- [ ] **Step 4: Create `deploy/build-push.ps1`**

```powershell
# Build + push the Fieldkit self-host image from the dev PC (Docker Desktop
# logged in as justnorthow). Requires .env.production.local with the FULL
# production env (vercel env pull --environment=production .env.production.local,
# then edit the SUPABASE_* values to the self-hosted stack's).
$ErrorActionPreference = "Stop"
if (-not (Test-Path ".env.production.local")) {
  throw ".env.production.local missing - pull Vercel env first, then set self-host SUPABASE_* values"
}
$tag = "justnorthow/fieldkit-app:$(git rev-parse --short HEAD)"
docker build -t $tag -t justnorthow/fieldkit-app:latest .
if ($LASTEXITCODE -ne 0) { throw "build failed" }
docker push $tag
docker push justnorthow/fieldkit-app:latest
docker inspect --format='{{index .RepoDigests 0}}' $tag
Write-Host "PIN THIS DIGEST in deploy/box/docker-compose.app.yml (FIELDKIT_IMAGE)"
```

- [ ] **Step 5: Create `deploy/box/docker-compose.app.yml` + `deploy/box/crontab`**

`deploy/box/docker-compose.app.yml`:

```yaml
# Fieldkit app + cron on the box. Env file: ~/fieldkit-app/.env (runtime env —
# server-side secrets; NEXT_PUBLIC_* are already baked into the image).
# The app joins the fieldkit stack's compose network to reach kong directly.
services:
  app:
    image: ${FIELDKIT_IMAGE:?digest-pinned by deploy/build-push.ps1}
    container_name: fieldkit-app
    restart: unless-stopped
    env_file: [".env"]
    ports:
      - "127.0.0.1:3000:3000"
    networks: [fieldkit-net]

  cron:
    # Replaces vercel.json crons. BusyBox crond hits the app's cron routes with
    # the same Authorization header Vercel used (CRON_SECRET).
    image: alpine:3.20
    container_name: fieldkit-cron
    restart: unless-stopped
    env_file: [".env"]
    command: ["/bin/sh", "-c", "apk add --no-cache curl >/dev/null && crond -f -l 8"]
    volumes:
      - ./crontab:/etc/crontabs/root:ro
    networks: [fieldkit-net]

networks:
  fieldkit-net:
    name: fieldkit_default
    external: true
```

`deploy/box/crontab` (mirrors `vercel.json`; Vercel sends `Authorization: Bearer $CRON_SECRET` — verify the routes' check at execution and adjust the header if the code differs):

```
0 * * * * curl -sf -H "Authorization: Bearer $CRON_SECRET" http://app:3000/api/cron/sync-metrics >> /proc/1/fd/1 2>&1
0 6 * * * curl -sf -H "Authorization: Bearer $CRON_SECRET" http://app:3000/api/cron/generate-recommendations >> /proc/1/fd/1 2>&1
0 8 * * 1 curl -sf -H "Authorization: Bearer $CRON_SECRET" http://app:3000/api/cron/send-summaries >> /proc/1/fd/1 2>&1
```

- [ ] **Step 6: Verify build locally**

Run (PC, with a copy of current `.env.local` as `.env.production.local` — dev values are fine for the smoke build):
`npm run lint && npm run build`
Expected: build succeeds and `ls .next/standalone/server.js` exists.
Then: `docker build -t fieldkit-smoke .` — Expected: image builds.

- [ ] **Step 7: Check the cron routes' auth**

Run: `grep -rn "CRON_SECRET" app/api/cron/ lib/ | head -20`
Expected: confirms header name/format; fix `deploy/box/crontab` if it differs from `Authorization: Bearer`.

- [ ] **Step 8: Commit (local branch only)**

```bash
git add next.config.ts Dockerfile .dockerignore deploy/
git commit -m "feat: self-host packaging — standalone output, Dockerfile, box compose + cron (Plan 4)"
```

---

### Task 7 (OPS, with John): HIA stack live on the jnow prod box

Procedure — also write it up as `docs/runbooks/app-stacks.md` §1–§3 in the install repo as you execute (commit at the end of the task).

- [ ] Push install-repo master (Tasks 1–5 commits) after John's gate; on the box: `cd ~/ollie-hermes-install && git fetch && git checkout <pushed HEAD>`.
- [ ] Preflight source size (fits 24 GB free disk?): against `lzbdghgywqnequxijrlf` session pooler: `select pg_database_size(current_database());` and `select coalesce(sum((metadata->>'size')::bigint),0) from storage.objects;` — expect well under 5 GB total; STOP and reassess disk if not.
- [ ] Deploy: `printf 'STACK_NAME=hia\nKONG_PORT=8010\nSUPABASE_PUBLIC_URL=https://sb-hia.jnow.io\nSITE_URL=https://<HIA Railway URL>\n' | bash scripts/20-install-app-stack.sh` → expect `auth /health → 200 ✓`.
- [ ] Migrate: scp a command file with the 4 stdin keys (HOSTED_DB_URL = session pooler for `lzbdghgywqnequxijrlf`, service key from dashboard) → `bash 21-migrate-app.sh` → expect per-table row counts, `auth.users rows: <n>` matching hosted, buckets synced.
- [ ] DNS: add `sb-hia.jnow.io` **A record, DNS-only/grey cloud** → box IP (Cloudflare zone UI; NOT proxied — proxied = bot-challenge on Railway's server-side calls).
- [ ] Firewall: open :80 + :443 on the box's Hetzner Cloud firewall (console; document as the deliberate exposure exception).
- [ ] Caddy (as root): `bash scripts/22-install-caddy-vhosts.sh sb-hia.jnow.io:8010` → `curl -s https://sb-hia.jnow.io/auth/v1/health -H "apikey: <anon>"` → 200 from off-box.
- [ ] Railway env repoint (John in Railway dashboard): set the three SUPABASE_* values printed by the migrate script; redeploy service.
- [ ] Acceptance: Ollie dashboard → HIA SSO round-trip; create report → upload PDF → process → download PDF; `select count(*) from ai_response_cache` grows on a repeat run.
- [ ] Guardrails: `free -m` available ≥ 700 MB (with only hia added it should be ≈1.2 GB); Ollie gate still green: `OPERATOR_EMAIL=jb@jnow.io bash scripts/check-box-config.sh` → all PASS.
- [ ] Hosted project `lzbdghgywqnequxijrlf`: **PAUSE** (do not delete — soak rollback).

### Task 8 (OPS, with John): newsletter-studio stack live

- [ ] Dashboard: RESTORE `trurniscewfvzihmmnzj` from pause (takes minutes; wait for Healthy).
- [ ] Deploy: `STACK_NAME=ns`, `KONG_PORT=8020`, `SUPABASE_PUBLIC_URL=https://sb-ns.jnow.io`, `SITE_URL=<NS Railway URL>` via `20-install-app-stack.sh`.
- [ ] Migrate via `21-migrate-app.sh` (pooler string + service key for `trurniscewfvzihmmnzj`).
- [ ] DNS `sb-ns.jnow.io` grey-cloud → box IP; caddy re-render with BOTH vhosts: `bash scripts/22-install-caddy-vhosts.sh sb-hia.jnow.io:8010 sb-ns.jnow.io:8020`.
- [ ] Railway env repoint for newsletter-studio; redeploy.
- [ ] Acceptance: SSO entry from Ollie broker hub → `/apps/newsletter/studio` loads; `voice_profiles` rows present.
- [ ] Guardrail: `free -m` available ≥ 700 MB — if breached, `docker compose -p ns … down` and revisit (spec fallback).
- [ ] PAUSE `trurniscewfvzihmmnzj` again (hosted side no longer needed but kept for soak).

### Task 9 (OPS, with John): inspection-report-app final archive + delete

- [ ] Dashboard: RESTORE `fcaeulzkbtwysdwhmxgq`; wait Healthy.
- [ ] Full dump (PC or box): `docker run --rm -e URL="<pooler>" postgres:17-alpine sh -c 'pg_dump "$URL" --no-owner' > inspectionlens-final-$(date +%Y%m%d).sql`
- [ ] Storage download: for each row of `select name from storage.objects`, `curl -H "apikey/Bearer <service key>" https://fcaeulzkbtwysdwhmxgq.supabase.co/storage/v1/object/<bucket>/<name>` into `storage/<bucket>/` (small script inline; count must match `select count(*) from storage.objects`).
- [ ] Archive to BOTH: `D:\workspaces\jnow\_archive\supabase-dumps\inspectionlens\` and (once the fieldkit box exists) `/srv/archive/inspectionlens/`.
- [ ] Test-restore: `docker run --rm -d --name ilens-check -e POSTGRES_PASSWORD=x postgres:17-alpine` → `psql < dump` → spot `select count(*) from reports;` → matches hosted → `docker rm -f ilens-check`.
- [ ] Dashboard: **DELETE** project `fcaeulzkbtwysdwhmxgq` (John clicks; his call per spec decision 7).

### Task 10 (OPS, with John): Fieldkit box — provision, deploy, cutover

Inputs from John at start: IONOS box (4c/4GB/120GB, US DC) root access; fieldkit domain + DNS host login; Vercel account for `vercel env pull`; hosted pooler string + service key for `xzqzidnsenjjwobkegii`; Docker Hub login on the PC.

- [ ] Box base setup (root): create `svc` user + docker (`curl -fsSL https://get.docker.com | sh; usermod -aG docker svc`), `loginctl enable-linger svc`, sshd hardening per existing box convention; IONOS firewall: allow :22, :80, :443 only.
- [ ] Clone install repo on box (`git clone https://github.com/justnorthow/ollie-hermes-install.git` and check out the pushed HEAD).
- [ ] Deploy stack (as svc): `STACK_NAME=fieldkit`, `KONG_PORT=8000`, `SUPABASE_PUBLIC_URL=https://sb.<domain>`, `SITE_URL=https://<domain>`, `REALTIME=1` via `20-install-app-stack.sh`. Verify realtime came up: `docker ps --filter name=fieldkit-realtime` → Up; `docker logs fieldkit-realtime | tail` shows tenant seeded.
- [ ] DNS now (propagation lead time): `A <domain> → box IP` **NOT yet** (cutover is later) — but DO add `A sb.<domain> → box IP` immediately.
- [ ] Caddy (root): `bash scripts/22-install-caddy-vhosts.sh sb.<domain>:8000 <domain>:3000` — cert for `<domain>` will fail until its A record cuts over; that's expected (caddy retries).
- [ ] Migrate data: `21-migrate-app.sh` with `STACK_NAME=fieldkit` + hosted creds → row counts match; realtime publication port lists `public.sms_logs`.
- [ ] Vercel env: `vercel env pull --environment=production .env.production.local` in the Fieldkit-App repo; copy to `.env` for the box (server-side values), replacing the three SUPABASE_* values with the stack's; keep `CRON_SECRET`, Twilio, Stripe, Inngest, Sentry values verbatim.
- [ ] PC: edit `.env.production.local` SUPABASE_* → self-host values (`https://sb.<domain>` + new anon key); run `deploy/build-push.ps1`; pin the printed digest as `FIELDKIT_IMAGE` in `deploy/box/docker-compose.app.yml`.
- [ ] Box: `mkdir ~/fieldkit-app`, scp `deploy/box/*` + `.env` there; `docker compose -f ~/fieldkit-app/docker-compose.app.yml up -d` → `curl -s http://127.0.0.1:3000` → 200/redirect.
- [ ] Pre-cutover smoke on the box (hosts-file trick on the PC: point `<domain>` at the box IP locally): login with John's real user (UUID preserved), estimate photos render, SMS inbox loads, **send a test SMS and watch it appear live (realtime)**.
- [ ] CUTOVER (low-traffic window): flip `A <domain>` → box IP at the DNS host. Caddy issues the cert on first hit. Verify from a phone on cellular: login, photos, SMS.
- [ ] Post-cutover: Twilio webhook fires on a real inbound SMS (no console change needed — domain unchanged); Stripe dashboard webhook deliveries green; Inngest run round-trip; wait for the next top-of-hour and confirm `/api/cron/sync-metrics` fired in `docker logs fieldkit-cron`.
- [ ] Nightly backups from day one (root): cron `0 3 * * * docker exec fieldkit-db pg_dump -U supabase_admin postgres | gzip > /srv/backups/fieldkit-$(date +\%F).sql.gz` + prune >14d; enable the IONOS backup add-on (John, console).
- [ ] Vercel: leave the project deployed but remove the domain AFTER 48h clean — it is the instant rollback (re-point DNS + restore domain) during soak. PAUSE hosted `xzqzidnsenjjwobkegii` once the box has run clean for 48–72h.

### Task 11 (OPS, with John): Soak, kill the bill, wrap

- [ ] Soak gate (1 week of real Fieldkit business use + HIA/NS spot checks, per spec): no auth failures, no storage misses, realtime alive, crons firing, RAM guardrails hold on both boxes.
- [ ] Delete hosted projects: `xzqzidnsenjjwobkegii`, `lzbdghgywqnequxijrlf` (inspection-report-app already deleted in Task 9).
- [ ] **Cancel the Metro Structured Holdings Pro org** (Billing → cancel; verify $0 forward charges + final invoice).
- [ ] Vercel: disable/delete the fieldkit project; confirm no Vercel charges forward.
- [ ] Plan-3 leftover (only if its own 2-week soak has passed): delete `kpdqhntsvjzhqjeupzsj` ("ollie-login-frontend") from the free org.
- [ ] Merge `feat/self-host` in Fieldkit-App (John's call), push install-repo docs/runbook; OB1 capture + STATE.md carry-forward update.

---

## Self-review notes (completed)

- **Spec coverage:** inventory verdicts → Tasks 7–11; multi-stack parameterization → Tasks 1–3; realtime → Tasks 1/2/4 + 10 acceptance; autoconfirm/no-hook/no-Google → Task 1; whole-schema migrate + storage policies + publication → Task 4; caddy/grey-cloud/:443 exception → Tasks 5/7; fieldkit Docker/cron/build-on-PC → Task 6/10; archive-then-delete → Task 9; soak + cancel → Task 11; parked-apps = documented option only (no task — spec says not built).
- **Deliberate deviation from spec:** spec's "loopback for fieldkit server-side" simplified to a single public `NEXT_PUBLIC_SUPABASE_URL` via caddy — no Cloudflare on that domain means no bot-protection risk, and Next.js bakes `NEXT_PUBLIC_*` at build time anyway (a loopback URL would break the browser client). Hairpin via the box's own public IP is the only cost. Flagged for John in the plan-review message.
- **Type consistency:** runner names (`migrate_src_psql`/`migrate_dst_psql`/`migrate_src_pgdump`), env key names, `~/stacks/<name>` paths, and port numbers cross-checked across Tasks 3/4/7/8/10.
- **Realtime image pin** is resolved by a command step (Task 2 Step 1), not invented here.
