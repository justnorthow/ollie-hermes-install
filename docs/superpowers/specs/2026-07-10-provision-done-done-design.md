# Provision "Done Done" — Design

- **Date:** 2026-07-10
- **Status:** APPROVED (John, 2026-07-10)
- **Supersedes:** Tier B/C of `2026-07-06-durable-per-box-config-design.md` (P3–P7 absorbed and extended here; Tier A of that spec is landed and untouched)
- **Motivating incident:** the "Ollie - GetBilled" provision (2026-07-10, IONOS 74.208.207.91). Fleet reported `done`; the box came up with a loopback-bound front-end at a recorded `frontend_url` that could never answer, zero Supabase config anywhere, and all four S75-class orchestrator gaps (no `INSTANCE_ID`, no proxy maps, no dashboard token, no RBAC seed).

## Problem

A Fleet provision runs every install script (01–09) and reports success, but the box is not usable:

1. **No Supabase.** Neither the stack `.env` (`SUPABASE_URL`/`ANON_KEY`/`COOKIE_DOMAIN` — the login gate) nor the orchestrator `.env` (`SUPABASE_URL`/`SERVICE_ROLE_KEY` — RBAC lookups) gets any Supabase config. The 2026-07-06 spec's P6 assumed "the service-role key already on the box"; that is true only for grandfathered boxes. On a fresh box P6 cannot run at all.
2. **The S75 gaps** (P3–P6 of the prior spec): no proxy maps → chat 503; no dashboard token/drop-ins → management surface 401; no `INSTANCE_ID` + no `user_roles` seed → RBAC fails closed, agents flash-then-disappear.
3. **`frontend_url` can be a lie.** Fleet records the operator-entered URL (e.g. `http://<ip>:3000/`) but nothing configures the box to serve it — the dashboard publishes `${DASHBOARD_BIND:-127.0.0.1}:3000` and tunnel setup is manual. Provision succeeds; the URL is unreachable.
4. **No gate.** Nothing checks the finished box against the healthy reference shape. Provision emits `done` unconditionally.

**Goal:** when a Fleet provision completes successfully, the operator can log in at `frontend_url` (or has explicit `pending-tunnel` instructions), chat with the default agent, and use the management surface — with zero hand-applied config. If any of that would not be true, the provision fails loudly and itemizes why.

## Decisions (John, 2026-07-10)

- **Scope:** full "done done" — P3–P7 plus Supabase-at-provision plus access-mode handling plus the wired gate.
- **Supabase model:** operator creates the per-instance Supabase project manually and pastes URL + anon key + service-role key into the provision form. Provision applies creds, runs the committed core migrations, and seeds the operator row. No Supabase Management API automation; Fleet holds no org-level Supabase credential.
- **Access mode:** a provision-form choice, `direct` or `tunnel`. `direct` sets `DASHBOARD_BIND=0.0.0.0` (cleartext-HTTP warning shown in the UI) and the gate probes `frontend_url` externally. `tunnel` leaves the loopback bind, emits the cloudflared runbook steps, and marks the instance `pending-tunnel`. No Cloudflare API automation.
- **Architecture:** Approach A — extend the approved ownership model. Install scripts own what is derivable/generatable on-box; Fleet owns what only it knows (instance UUID, operator identity, form inputs) and instructs the box. The manual (non-Fleet) runbook path stays viable.
- **Validation:** the GetBilled box is wiped and re-provisioned through the new flow as the end-to-end acceptance test. sandbox/jnow are grandfathered (no forced migration; the same pieces can heal them via the normal `update` paths).
- Carried from 2026-07-06: `INSTANCE_ID` = Fleet instance UUID for new boxes; Fleet never gets Supabase write access; existing slug IDs grandfathered.
- **Migrations (added 2026-07-10, post-exploration):** PostgREST cannot execute DDL, so `11` cannot apply SQL with the service-role key. The operator makes the project **provision-ready** per the committed runbook (`docs/runbooks/supabase-ollie-core-provisioning.md`: SQL Editor paste of `supabase/ollie-core/*.sql`, JWT-hook registration, Google provider, Site URL) *before* provisioning; `11-install-supabase.sh` **verifies** the schema via a REST probe and fails fast with a run-the-runbook message. No DB password or Management API token is collected.
- **Operator identity (verified 2026-07-10):** Fleet's `FinalizeParams.userId` is a Fleet-local UUID, *not* a Supabase auth id. P6 therefore keys on the operator's **email**: the box helper resolves the Supabase auth user by email via the admin API, creating it with `email_confirm: true` if absent (Google sign-in auto-links — the proven sandbox pattern), then seeds `user_roles` with the returned id.

## Ownership model (extended)

| Piece | Owner | Rationale |
|---|---|---|
| P3 proxy maps | install (`05`) | derivable from installed profiles/ports on-box |
| P4 dashboard token + drop-ins | install (`05`) | generatable on-box, must be stable across re-runs |
| S1 Supabase application + migrations + restart | install (new `11-install-supabase.sh`) | box-local writes; creds arrive as env from the caller (Fleet or a human following the runbook) |
| P5 `INSTANCE_ID` | Fleet (`finalizeEnrollment`) | only Fleet knows the instance UUID |
| P6 RBAC operator seed | Fleet-instructs-box | Fleet passes `user_id` + `INSTANCE_ID`; box upserts with its own service-role key |
| S2 access mode (`DASHBOARD_BIND`, pending-tunnel state) | Fleet (provision flow) + install (preserved key) | operator choice lives on the form; the box-side knob already exists and is preserved |
| P7 parity gate | install (script) + Fleet (invocation + UI) | the check is box-local; the *enforcement* (fail the provision, block `done`) is Fleet's |

## Config inventory (healthy-box reference = sandbox, corrected)

Everything from the 2026-07-06 inventory, **plus** the rows that spec missed:

| Config | Location | Owner | Source |
|---|---|---|---|
| `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_COOKIE_DOMAIN` | stack `.env` | Fleet → preserved keys | provision form / `instance_supabase` |
| `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` | orchestrator `.env` | install (`11`) | provision form, passed as env |
| `DASHBOARD_BIND` | stack `.env` | Fleet (access mode) | form choice; already a preserved key |
| core schema migrations | the instance's Supabase project | operator (runbook), **verified** by install (`11`) | `supabase/ollie-core/*.sql` in this repo (0001–0006 + runbook README, committed `14f8bc9`) |
| `INSTANCE_ID` | orchestrator `.env` | Fleet (P5) | instance UUID |
| `HERMES_GATEWAY_URLS`, `HERMES_DASHBOARD_URLS` | orchestrator `.env` | install (P3) | derived from profiles |
| `HERMES_DASHBOARD_TOKEN` + `session-token.conf` drop-ins | orchestrator `.env` + systemd user dir | install (P4) | generated once, reused |
| `user_roles` operator seed | instance Supabase project | Fleet-instructs-box (P6) | operator `user_id`, `platform_operator` |

Optional keys observed on sandbox (`HIA_*`, `FRED_API_KEY`, `GUARDRAIL_ENFORCE_APPS`) are instance-specific features, **not** part of the healthy-box baseline; the gate does not check them.

## Components

### S1 — `scripts/11-install-supabase.sh` (new, install repo)

Inputs (env): `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_COOKIE_DOMAIN` (optional; empty = no cross-subdomain cookie).

1. **Refuses partial input:** all of URL + anon + service-role present, or exit 1 with a clear message. URL must match `https://<ref>.supabase.co`.
2. Writes `SUPABASE_URL` + `SUPABASE_SERVICE_ROLE_KEY` into the orchestrator `.env` (create-or-replace per key, preserving all other lines; single-line-value guard reused from the security batch).
3. **Verifies the project is provision-ready** (operator applied the runbook SQL): `GET {SUPABASE_URL}/rest/v1/user_roles?select=user_id&limit=1` with the service-role key must return 200. Anything else = exit 1 with "project is not provision-ready — run docs/runbooks/supabase-ollie-core-provisioning.md". (PostgREST cannot execute DDL; see Decisions.)
4. Restarts `ollie-orchestrator` (systemd user unit) and waits for its health endpoint.
5. Idempotent: re-run with the same creds is a no-op apart from the restart; re-run with *different* creds replaces them (that is the repoint-a-box path, deliberate).

Stack-side Supabase keys (`SUPABASE_URL`/`ANON_KEY`/`COOKIE_DOMAIN`) are **not** written by `11` — they belong to the stack `.env` render (`06` + preserved keys) and are pushed by Fleet exactly as `set-dashboard-auth` does today. `11` owns only the orchestrator side + migrations.

### P3 — `05-install-orchestrator.sh` writes the proxy maps

As spec'd 2026-07-06: derive `HERMES_GATEWAY_URLS` / `HERMES_DASHBOARD_URLS` as `{agentId: "http://127.0.0.1:<port>"}` from the default ports (8642/9119) + each installed profile's `API_SERVER_PORT` and dashboard-unit `--port`. Written on every `05` run; an operator-customized value is preserved only if it covers every installed agent (else regenerate — a stale partial map is exactly the failure mode). `03-install-profile.sh` re-invokes the map render after adding a profile so new agents appear in the maps without a full re-install.

### P4 — `05-install-orchestrator.sh` generates + persists the dashboard token

As spec'd 2026-07-06: reuse `HERMES_DASHBOARD_TOKEN` if present in the orchestrator `.env`, else generate (`secrets.token_urlsafe(32)`). Write the `.env` key and a mode-600 `session-token.conf` drop-in (`[Service]\nEnvironment=HERMES_DASHBOARD_SESSION_TOKEN=<same>`) for every `hermes-dashboard*.service` unit; `daemon-reload`; restart dashboards whose drop-in changed. `03-install-profile.sh` re-invokes the drop-in render for the new unit.

### P5 — Fleet writes `INSTANCE_ID` (fleet repo, `finalizeEnrollment`)

After `10-install-fleetctl.sh`, Fleet writes `INSTANCE_ID=<instance UUID>` into the orchestrator `.env` over SSH (create-or-replace) and restarts the orchestrator. Provision and enroll-existing-box paths both get it. Existing slug boxes grandfathered.

### P6 — Fleet-instructs-box RBAC seed (fleet repo + box-local execution)

Immediately after P5: Fleet passes the enrolling operator's **email** (`FinalizeParams.userEmail`; Fleet's `userId` is Fleet-local — see Decisions) + `INSTANCE_ID` to the box; the box runs a small install-repo helper (`scripts/lib/seed-operator-role.py`) that resolves the Supabase auth user by email via the admin API (creating it with `email_confirm: true` if absent, so Google sign-in auto-links), then upserts `user_roles(instance_id, user_id, tier='platform_operator')` via its own `SUPABASE_SERVICE_ROLE_KEY` with `Prefer: resolution=merge-duplicates`. Exit non-zero if the orchestrator `.env` has no service-role key (ordering bug — S1 must have run).

### S2 — access mode (fleet repo)

Provision form field `accessMode: 'direct' | 'tunnel'` (required, no default in the UI).

- **direct:** Fleet appends `DASHBOARD_BIND=0.0.0.0` to the stack `.env` alongside the dashboard creds write (one container recreate total). The UI shows a warning that this serves basic-auth over cleartext HTTP on a public IP.
- **tunnel:** no bind change. The provision result panel and the operation log emit the per-box cloudflared runbook steps (hostname → `http://localhost:3000`, the Host/Origin header rewrites, from `docs/runbooks/hermes-dashboard-cloudflare.md`). Instance row gets `access_state='pending-tunnel'`.

New nullable column `instances.access_state` (`NULL`=healthy/legacy, `'pending-tunnel'`). A later heartbeat or on-demand gate run that finds `frontend_url` reachable clears it.

### P7 — `scripts/check-box-config.sh` + Fleet gate wiring

Box-local report-only script; checks, each printing PASS/FAIL with specifics:

1. Orchestrator `.env`: `INSTANCE_ID`, `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `HERMES_DASHBOARD_TOKEN` present + non-empty.
2. Proxy maps present, valid JSON, exactly one entry per configured agent (from `AGENTS_JSON`).
3. A `session-token.conf` drop-in per `hermes-dashboard*.service`, value matching the orchestrator token.
4. No dashboard unit with `--host 0.0.0.0`; all dashboard/gateway/orchestrator units active; cortex + dashboard containers running.
5. Stack `.env`: `SUPABASE_URL` + `SUPABASE_ANON_KEY` present (login gate will render).
6. **Live chain probe:** `whoami` for the operator `user_id` via the orchestrator returns a tier and non-empty `reachableAgentIds` (exercises Supabase schema + seed + `INSTANCE_ID` + RBAC in one shot).

Exit 0 all-pass, else 1 with the itemized gap list.

**Fleet wiring:** provision runs the gate as its final step. Any FAIL → the operation fails and the gap list is the error shown in the UI; **no `done` event**. In `direct` mode Fleet additionally probes `frontend_url` from fleet-prod (outside-the-box vantage) and treats unreachable as a gate failure. In `tunnel` mode the external probe is skipped (`pending-tunnel` instead). The gate is also exposed as an on-demand per-instance action in the Fleet UI (report-only there — never blocks an existing box).

## Provision sequence (new full order)

```
01 bootstrap → install key → clone repo → 02 hermes → 04 cortex-plugin →
05 orchestrator (now: + P3 maps + P4 token/drop-ins) →
06 stack (Fleet passes HERMES_UI_URL/VERTICAL as today) →
   Fleet writes stack env additions in ONE append: DASHBOARD_USER/PASS,
   SUPABASE_URL/ANON_KEY/COOKIE_DOMAIN, and (direct mode) DASHBOARD_BIND=0.0.0.0
   → single dashboard container recreate →
07 cron-brain → 08 souls → 09 identity-sync →
11 supabase (orchestrator env + migrations + restart) →
finalizeEnrollment (10 fleetctl, health, DB row) →
P5 INSTANCE_ID write + orchestrator restart →
P6 operator seed →
P7 gate (+ direct-mode external frontend_url probe) →
done  (or: failed with gap list / done with access_state=pending-tunnel)
```

Ordering constraints: S1 before P6 (seed needs key + schema); P5 before P6 (seed needs `INSTANCE_ID`); P7 last. The orchestrator restarts at most twice (after `11`, after P5) — acceptable; collapsing to one is a plan-level optimization, not a requirement.

## Failure semantics

- Unchanged principle: every step is idempotent; a failed provision is re-runnable against the same box (migrations guard, token reuses, seeds upsert, env writes are create-or-replace, key install greps first).
- Form validation front-loads the cheap failures: URL shape, JWT-shaped keys, access mode chosen — before any SSH.
- A gate failure leaves the box installed but the operation failed; the operator fixes the cause (or we fix a bug) and re-provisions the same host — the re-run converges.

## Testing

- **Install repo (bash harness + pytest, as Tier A):**
  - `11`: partial creds → exit 1; fresh run writes both keys + runs migrations (mocked runner records order); re-run same creds = byte-identical `.env` apart from nothing; different creds replace.
  - P3: fixture profiles → expected JSON maps; operator value covering all agents preserved; stale partial map regenerated; `03` adds an agent → maps regenerate.
  - P4: absent token generated; present token reused byte-identical; drop-ins created mode 600 matching; re-run zero drift.
  - `seed-operator-role.sh`: missing service-role key → exit 1; upsert payload shape (mocked curl).
  - P7: healthy fixture → exit 0; each seeded gap flagged by name; `whoami` probe mocked both ways.
  - Idempotency invariant everywhere: run twice, zero drift.
- **Fleet repo (pytest + fleetctl bash suite — always both, S74 lesson):** form validation, provision step order (extends the existing step-list tests), P5/P6 SSH command construction, gate-failure → operation fails with gap list, `access_state` transitions, direct-mode probe.
- **End-to-end acceptance:** wipe + re-provision the GetBilled box through the new flow with a real GetBilled Supabase project: login at `frontend_url`, chat round-trip with the default agent, one management-surface call (e.g. Skills list) — all working with zero hand-applied config. This is the definition of done for the whole workstream.

## Out of scope / deferred

- Supabase project creation automation (Management API) — operator creates the project.
- Cloudflare tunnel automation — runbook emission only; `pending-tunnel` tracks it.
- Migrating sandbox/jnow to the new pieces — grandfathered; normal `update` paths can heal them opportunistically.
- Gate auto-remediation — the gate reports; the idempotent scripts are the remediation, run via re-provision/update.
- Dashboard token rotation; repointing Supabase on a live box (works via `11` re-run but is not designed/tested as a first-class flow here).
- CORTEX_API_KEY enablement (still plumbed-but-unset, separate decision).
