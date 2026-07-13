# Plan 4 — Migrate the remaining hosted Supabase apps and cancel the Pro org

**Date:** 2026-07-13
**Status:** Approved by John (conversation 2026-07-13); supersedes the "Shared apps VPS" section of `2026-07-11-self-hosted-supabase-design.md`
**Prereq:** Plan 3 complete (all Ollie boxes self-hosted; hosted prod paused, soaking)

## Goal

Move the last apps off hosted Supabase so the **Metro Structured Holdings Pro org
(~$35/mo) can be cancelled**, take Fieldkit fully standalone (off Vercel too), and
leave every dormant app's data recoverable. New infrastructure spend: **one IONOS
VPS, ~$11/mo**. Net ≈ $24+/mo saved plus no auto-pause anywhere.

## Authoritative inventory (verified in dashboard + code, 2026-07-13)

Supabase projects exist across **three accounts/orgs**:

| Org (account) | Project | Ref | State | Verdict |
|---|---|---|---|---|
| Metro Structured Holdings (Pro) | fieldkit | `xzqzidnsenjjwobkegii` | Active, Micro | **Migrate → Fieldkit box** |
| Metro Structured Holdings (Pro) | jnow-workspace | `lzbdghgywqnequxijrlf` | Active, Micro | **Migrate → prod-box HIA stack** (it is HIA's live backend — see below) |
| Metro Structured Holdings (Pro) | inspection-report-app | `fcaeulzkbtwysdwhmxgq` | Paused | **Restore → final dump to archive → delete** (old InspectionLens, superseded by HIA) |
| Revomate-Free (free) | ollie-login-frontend | `kpdqhntsvjzhqjeupzsj` | Paused | Plan-3 migrated jnow/Ollie prod. Delete after Plan-3 soak passes. Never on the Pro bill. |
| Revomate-Free (free) | ollie-realestate-newsletter | `trurniscewfvzihmmnzj` | Paused | **Restore → migrate → prod-box newsletter-studio stack** (revives the broker app) |
| Revomate-Free (free) | CabinetEstimator | `fkjxcbdqeczvinbqmjwp` | Paused | Leave hosted (John's call). Parked-data option documented in §Parked apps. |
| Revomate-Free (free) | QBOkeeper | `hbugujskaybznsrgmqno` | Paused | Leave hosted (John's call). |
| JNOW (free, jb@jnow.io) | ollie-sandbox | `mctnughllhcndngjqakt` | Active (auto-pauses) | Plan-3 scope; untouched. |
| JNOW (free, jb@jnow.io) | open-brain | `xkmtdsqdvdtvvsuuiaoq` | Active | OB1 backend — **never touch**. |

Key identifications made during discovery:

- **"jnow-workspace" is not an orphan.** Its tables (`users`, `reports`,
  `file_uploads`, `ai_response_cache`, `sso_used_tokens`) match exactly the
  **Home Inspection Advisor** app (`D:\workspaces\jnow\jnow-workspace\development\client-apps\real-estate\home-inspection-advisor`,
  formerly "InspectionLens"), which is deployed on Railway and SSO-integrated with
  the Ollie orchestrator (`HIA_SSO_SECRET` / `HIA_BASE_URL`). ~108 req/24h observed.
- **airesume is out of scope.** The site migrated to Neon (commit `c796d60`, pushed
  to master → deployed); its legacy Supabase project (`aworxlbyzbqfohzccvuh`) is
  NXDOMAIN and not present in any visible org — already gone.
- **Fieldkit's local `.env.local` ref (`auovqoqnwbynitgogrvh`) is a dead dev
  project.** Production ref is `xzqzidnsenjjwobkegii` (in Vercel env, not on disk).
- newsletter-studio (Railway, `D:\workspaces\jnow\jnow-workspace\development\client-apps\real-estate\newsletter-studio`)
  is the app for `ollie-realestate-newsletter` (tables `sso_used_tokens`,
  `voice_profiles`); currently dead because its project is paused.

## Decisions (John, 2026-07-13)

1. **Fieldkit: own box, all at once** — DB stack *and* the Next.js app move in
   Plan 4. Fieldkit is the production system for the handyman business; it gets
   its own VPS, isolated from demo apps.
2. **Fieldkit box provider: IONOS** — 4 vCPU / 4 GB / 120 GB SSD, $11/mo, **US
   datacenter** (Hetzner's new pricing — $23.59/mo for 2c/4GB — lost; the CX line
   is unavailable). Ops patterns carry over from the GetBilled IONOS box.
3. **No shared apps VPS.** HIA + newsletter-studio stacks ride the **existing jnow
   prod Ollie box** (Hetzner, `ollie@46.224.81.84`) as co-tenants: measured
   headroom 1.9 GB available / two stacks ≈ 680 MB. $0 marginal cost.
4. **HIA + newsletter-studio apps stay on Railway**; only their databases move
   (env repoint).
5. **Realtime:** fieldkit's stack adds the `supabase/realtime` container (its SMS
   inbox uses `postgres_changes`). HIA/NS stacks stay trimmed (no realtime).
6. **Auth emails: none.** GoTrue runs autoconfirm + admin-managed users
   (`GOTRUE_MAILER_AUTOCONFIRM=true`; users created / passwords reset via admin
   API). No SMTP dependency. Applies to fieldkit + HIA + NS.
7. **inspection-report-app:** dump-to-archive then delete.
8. **Free-org strays:** leave hosted (CabinetEstimator, QBOkeeper;
   ollie-login-frontend deleted only after the Plan-3 soak).
9. Accepted trade-off: Railway (US) → prod box (Hetzner EU) adds ~100 ms per DB
   query for HIA/NS. Acceptable for demo-tier apps; Fieldkit (latency-sensitive)
   is the one that gets the US box.

## Architecture

### Box 1 — Fieldkit box (new, IONOS US, 4c/4GB/120GB)

Containers (single compose project `fieldkit`):

- Trimmed Supabase stack (Plan-3 template): postgres 15.8, gotrue, postgrest,
  storage-api, kong (loopback :8000) — **plus `realtime`** (supabase/realtime,
  pinned digest), routed at `/realtime/v1` through kong (websocket upgrade
  headers in the kong template).
- **Fieldkit Next.js app** — standalone Docker image, built on John's PC and
  pushed to Docker Hub (`justnorthow/fieldkit-app@sha256:…`, digest-pinned like
  the Ollie frontend). Not built on-box (4 GB).
- **caddy + Let's Encrypt** serving the app's existing production domain
  (Fieldkit's domain is NOT on Cloudflare — confirmed by John 2026-07-13; DNS A
  record repoints from Vercel to the box IP; :80/:443 open on the IONOS
  firewall, caddy handles cert issuance/renewal). The domain does not change →
  Twilio webhooks, Stripe webhooks, and PWA push subscriptions keep working
  without re-registration.
- **cron container / systemd timers** replacing the 3 Vercel cron jobs (enumerate
  from `D:\workspaces\metro\Fieldkit-App\vercel.json` at plan time; each becomes
  a `curl` against the app's route on schedule).

Data flow: browser/Twilio → domain → app container; app → Supabase over
**loopback** (`SUPABASE_URL=http://127.0.0.1:8000` server-side). The browser
client (`NEXT_PUBLIC_SUPABASE_URL`) needs a public HTTPS endpoint for auth/
storage/realtime: `sb-<fieldkit-domain>` public hostname on the same
tunnel/caddy. Realtime websockets ride the same hostname.

External services unchanged: Twilio, Stripe, Inngest (cloud, repointed at the
new base URL), Sentry, web-push.

Key-format note: current Vercel env uses new-style `sb_publishable_…` /
`sb_secret_…` keys. Self-hosted stacks issue legacy JWT anon/service keys —
supabase-js accepts either string; the cutover swaps env values only.

### Box 2 — jnow prod Ollie box (existing, co-tenancy)

Two additional compose projects, each a fully isolated trimmed stack (own
Postgres, GoTrue realm, service key, volumes):

| Stack | Compose project | Kong port | Data from | App (stays on Railway) |
|---|---|---|---|---|
| HIA | `hia` | 127.0.0.1:**8010** | `lzbdghgywqnequxijrlf` | home-inspection-advisor |
| newsletter-studio | `ns` | 127.0.0.1:**8020** | `trurniscewfvzihmmnzj` | newsletter-studio |

**Multi-stack template work (the main new engineering besides realtime):** the
Plan-3 stack hardcodes container names (`supabase-db`, …), the `~/supabase-stack`
dir, and kong :8000. Parameterize: compose **project name** (container-name
prefixes), **stack dir** (`~/stacks/<app>`), **kong bind port**, volume paths.
The existing Ollie stack on this box is untouched (stays `~/supabase-stack`,
:8000).

**Public endpoints for Railway (the bot-protection problem):** Railway's
server-side supabase-js arrives as a non-browser client; the jnow.io zone's Bot
Fight Mode challenges exactly that (Plan-3 finding), and BFM cannot be scoped
per-hostname. Chosen approach: **DNS-only (grey-cloud) subdomains + caddy with
Let's Encrypt on the box**, e.g. `sb-hia.jnow.io`, `sb-ns.jnow.io` → caddy :443
→ loopback kong ports. This requires opening **:443** on the box's Hetzner cloud
firewall — a deliberate, documented exception to the ":22 only" posture (caddy
terminates TLS; kong enforces API keys behind it). Alternative rejected: putting
these hostnames through the tunnel (challenged), or turning off BFM zone-wide
(weakens the marketing site for Mike's zone).

RAM guardrail: after both stacks are live, `free -m` available must stay
≥ 700 MB; if it doesn't, newsletter-studio's stack is the one that moves off
(it's the least-used).

### Auth specifics (all three stacks)

- Plan-3 keygen as-is: ES256 signing keys + HS256 anon/service JWTs,
  `GOTRUE_JWT_ISSUER`/JWKS, kong 24k header buffers, storage `JWT_JWKS`.
- `GOTRUE_MAILER_AUTOCONFIRM=true`; signup stays enabled for fieldkit (its app
  has a signup flow) but new users are usable immediately without email; password
  resets via GoTrue admin API (runbook snippet).
- **auth.users / identities migrate with UUIDs preserved** (Plan-3
  `12-migrate-supabase.sh` pattern) — fieldkit and HIA both FK to auth.users.
- SSO secrets (`HIA_SSO_SECRET`, `NEWSLETTER_SSO_SECRET`) are app-level HMAC
  shared with the Ollie orchestrator — unchanged by the DB move.

## Migration procedure (per app)

Extends the Plan-3 tooling: `scripts/12-migrate-supabase.sh` gains (or a sibling
`13-migrate-app.sh` implements) a **whole-schema mode** — these apps' schemas are
not ollie-core, so instead of the fixed table list: apply the app's repo
migrations (fieldkit: 165 files; HIA: 11 + bootstrap; NS: 0001_init) to the fresh
stack, then column-intersection data copy for every public table, auth.users/
identities UUID-preserving copy, sequence fix, storage bucket + object sync,
storage RLS policy port. Same stdin-secrets, `--single-transaction`, count-verify
gates as Plan 3.

Order (each step reversible until its DNS/env cutover):

1. **Prod box first (lower risk, proves multi-stack):** deploy HIA stack →
   migrate `lzbdghgywqnequxijrlf` → repoint Railway env → verify Ollie-SSO
   round-trip + report upload/PDF flow → watch RAM.
2. **newsletter-studio:** restore `trurniscewfvzihmmnzj` from pause → deploy NS
   stack → migrate → repoint Railway → verify SSO entry + studio loads.
3. **inspection-report-app:** restore from pause → full `pg_dump` (schema+data)
   + storage download → archive to the Fieldkit box `/srv/archive/` **and**
   `D:\workspaces\jnow\_archive\supabase-dumps\` → test-restore into a scratch
   container → delete the hosted project.
4. **Fieldkit (the production cutover, do last, low-traffic window):** provision
   IONOS box → deploy stack+realtime → build/push app image → migrate data +
   storage → bring app up on the box → cut DNS from Vercel to the box → verify
   (below) → keep Vercel deployment paused-but-intact as rollback for the soak.
5. **Soak + kill:** 1 week of real Fieldkit business use + HIA/NS spot checks →
   remove Supabase projects → **cancel the Metro Structured Holdings Pro org** →
   disable the Vercel fieldkit project.

Rollback per app = repoint env/DNS back to the hosted project (kept paused, not
deleted, until the soak passes) — same `.bak-prehosted` discipline as Plan 3.

## Acceptance checks

- **Fieldkit:** login (existing user, UUID preserved), estimate photo upload +
  render, **SMS inbox live-updates via realtime**, Twilio inbound webhook, Stripe
  checkout + webhook, each cron fires once, Inngest job round-trip, PWA push.
- **HIA:** SSO from Ollie dashboard, create report → upload PDF → process →
  download PDF (storage buckets `inspection_pdfs`/`amendment_pdfs`/`report_pdfs`),
  ai_response_cache hit.
- **NS:** SSO entry, studio loads voice_profiles.
- **Prod box:** Ollie's own stack/gate still green (`check-box-config.sh` 23/23),
  RAM available ≥ 700 MB.
- **Bill:** Pro org shows $0 forward charges before cancel; final invoice checked.

## Risks & mitigations

- **Fieldkit is a production business system.** Vercel kept as instant rollback
  through the soak; cutover in a low-traffic window; image + env digest-pinned;
  nightly `pg_dump` to disk from day one + IONOS backup add-on priced in.
- **Realtime is new to the template.** Test `postgres_changes` end-to-end on the
  box before DNS cutover (it needs `wal_level=logical` + publication — verify the
  supabase/postgres image defaults).
- **Multi-stack collisions on the prod box** (names/ports/volumes) — the
  parameterization work exists precisely for this; double re-run idempotency
  test like Plan 3.
- **:443 exposure on the prod box** — caddy only proxies the two sb hostnames;
  kong still enforces API keys; documented in the runbook as a deliberate
  exception.
- **Paused-project restores** (inspection-report-app, ollie-realestate-newsletter)
  can take minutes and free-tier restores have a 90-day deletion horizon — do
  them early in the plan, not last.
- **EU latency for Railway apps** — accepted (decision 9); if HIA feels too slow,
  its app moves onto the prod box later (loopback), which also has a documented
  seam.
- **Old-key formats / env drift** — every env swap is recorded in the runbook
  with before/after; Vercel + Railway env snapshots taken before any change.

## Parked apps (documented option, not built)

CabinetEstimator + QBOkeeper stay hosted-paused (John's call). If Supabase's
free-tier retention ever threatens deletion, the inspection-report-app archive
procedure (§Migration step 3) applies verbatim; dumps land in the same two
archive locations, restorable into an on-demand stack on the Fieldkit box (120 GB
disk has room).

## Out of scope

- Moving HIA/NS apps off Railway; self-hosting Inngest; Fleet/fleetctl management
  of the new stacks (hand-run compose via runbook); deleting free-org strays;
  any Ollie-box changes beyond the two co-tenant stacks.

## Open items to resolve at plan time (not blockers)

1. Fieldkit's production domain name (zone confirmed NOT on Cloudflare → caddy
   + Let's Encrypt on the box; get the domain + registrar/DNS host for the A
   record cutover).
2. Enumerate the 3 Vercel crons + full Vercel env var list (needs Vercel
   dashboard access or `vercel env pull`).
3. IONOS datacenter choice (nearest to Texas) + backup add-on price.
4. Whether fieldkit prod runs any Edge Functions (repo shows none; confirm the
   dashboard Functions tab is empty before cutover).
