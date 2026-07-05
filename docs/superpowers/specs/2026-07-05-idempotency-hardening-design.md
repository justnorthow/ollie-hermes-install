# Ollie/Hermes Idempotency & State-Preservation Hardening — Design

**Date:** 2026-07-05
**Author:** John Bryant (with Claude Code)
**Status:** Design — awaiting review before writing-plans
**Repos touched:** ollie-hermes-install, ollie-fleet, ollie-hermes-orchestrator, ollie-hermes-frontend (compose/generate-scripts), ollie-prospecting-agent (installer)

---

## 1. Goal & non-goals

**Goal.** Make every install / update / rebuild / provision path **idempotent and self-healing** so that:

- Re-running any path never wipes operator- or Fleet-set state (`~/hermes-stack/.env` keys, profile config, secrets).
- An update never silently re-breaks something a prior fix already handled.
- Config that today must be "re-applied by hand after a rebuild" becomes durable in git / Fleet.
- Image/version pins can't silently ship stale (pre-fix) code.

**Guiding principle.** The correct pattern already exists in this codebase — `hermes update` wipes `~/.hermes/hermes-agent`, and `ollie-fleetctl update` **automatically re-applies** the pieces it clobbers (scripts 04/07/08). Every gap below is a place where a writer, a re-apply step, or a preserve entry is *missing* from that established pattern. We are extending a proven pattern, not inventing one.

**Non-goals.** Not a security review (that's the separate, already-staged security batch this stacks on top of). Not a refactor of the install scripts' structure. Not changing the deployment topology beyond the one approved gateway-bind change (Phase 8).

---

## 2. Context & how this relates to the security batch

Each of the 5 repos has an **unpushed, local** "security batch" commit at HEAD (cortex `9c7f8ca` / orchestrator `828b2ee` / frontend `9d0b464` / install `9d23b0f` / fleet `39550f0`). **Decision (John, 2026-07-05): these idempotency fixes are a follow-on batch stacked as new commits on top of those, kept local + unpushed** — John batches the coordinated deploy.

Deploy-timing couplings (see `D:\sessioncontext\DEPLOY-RUNBOOK-security-batch-2026-07-05.md`):

- The security batch's **first** deploy is safe as-is. The image-pin trap (Phase 1) and `update stack` gap (Phase 2) arm the **next** image bump, not the first — so these idempotency fixes must land **before the second image bump** and **before `CORTEX_API_KEY` is ever enabled**.
- The `ollie-fleet` working tree has 2 **untracked docs** (`docs/reviews/`, a stray plan `.md`); `git diff` is empty. Safe to build on that HEAD; optionally clean them up.

---

## 3. Decisions locked with John (2026-07-05)

| # | Decision | Choice |
|---|---|---|
| D1 | Batching vs the security batch | **Follow-on commits on top, local + unpushed** |
| D2 | Scope breadth | **All 19 findings, firewall included** |
| D3 | Run-ownership on restart | **Persist to Supabase now** (not accept-as-is) |
| D4 | Gateway-bind / firewall (#19) | **REVISED 2026-07-05: keep `0.0.0.0` (no rebind); codify the provider firewall + add a Fleet exposure health-check** — see Phase 8 |
| D5 | `CORTEX_API_KEY` enable | Fix plumbing (preserve + compose decl) this pass; **keep the key UNSET** — flip later per runbook |
| D6 | Legacy runs under fail-closed | **Leave un-migrated** (transient; persistence covers new runs going forward) |
| D7 | Legacy sessions | **Verify `backfill_sessions.py` ran at cutover** (operational check), don't re-migrate |

---

## 4. Findings → phase map (all 19)

| # | Finding (short) | Tier | Repo(s) | Phase |
|---|---|---|---|---|
| 1 | Image-pin duplicate-key trap (preserved OLD pin wins) | 1 | install | P1 |
| 2 | `update stack` never re-runs `06` → stale compose/pins | 1 | install | P2 |
| 3 | `CORTEX_API_KEY` wiped + absent from deployed compose | 1 | install, frontend | P1 |
| 4 | Supabase blank-on-disable + `SUPABASE_COOKIE_DOMAIN` has no Fleet writer (S72 root cause) | 2 | fleet, install(fleetctl) | P3 |
| 5 | Provision never repopulates Supabase; `06` only preserves | 2 | fleet | P3 |
| 6 | `approvals.mode:"off"` set by no code path | 2 | install, prospecting-agent | P4 |
| 7 | `update hermes` doesn't re-apply 09 identity-sync | 3 | install | P2 |
| 8 | Onboarding-injection patch not re-applied (design exists; ship status unverified) | 3 | install | P2 |
| 9 | Operator skills + `env_passthrough` (Apollo key) — wiring in git, secret value manual | 3 | fleet, prospecting-agent | P4 |
| 10 | `update orchestrator` never re-runs `05` → unit/env drift | 3 | install | P2 |
| 11 | README vs fleetctl re-apply lists disagree, both incomplete | 3 | install | P2 |
| 12 | Non-cortex plugin `__init__.py` not restored | 3 | install | P2 (accept/guard) |
| 13 | Profile inheritance not retroactive (update never re-runs 03) | 3 | install | P2 |
| 14 | `_RUN_OWNERS` in-memory, fail-closed on restart | 4 | orchestrator | P5 |
| 15 | Verify sessions backfill ran; runs un-migrated | 4 | orchestrator | P6 |
| 16 | `HERMES_UI_HOSTNAME` wiped, no writer | 5 | install | P1 |
| 17 | Operator tunables drift to defaults | 5 | install | P1 |
| 18 | `INSTALL_REPO_REF` hardcoded-SHA manual bump / update uses master | 5 | fleet, install | P7 |
| 19 | Gateway bound `0.0.0.0` + no in-repo firewall | 5 | install, fleet | P8 |

---

## 5. Cross-cutting design rules

**R1 — One preservation mechanism, no duplicates.** `06-install-stack.sh` today preserves via two paths: `preserve_env_keys()` (appends old lines *after* the heredoc → can produce duplicate keys) and inline read-forward (`X="${X:-$EXISTING_X}"` written *inside* the heredoc → exactly one line). The inline path is strictly better (no duplicate-key ambiguity). **New preserved keys use the inline read-forward pattern.** Existing `preserve_env_keys` entries stay, except where a duplicate is harmful (the image pins — Phase 1).

**R2 — Re-apply lists have a single source of truth.** The set of scripts re-applied after `hermes update` must be defined once (in `ollie-fleetctl`), and the README must reference/derive from it — not maintain a second hand-copied list.

**R3 — Idempotent + self-healing.** Every writer/step must be safe to run repeatedly and must converge a partially-configured box to the correct state (so a box built before a fix heals on the next update, not just on a from-scratch reinstall).

**R4 — Sandbox-first, box-verified.** Anything whose behavior can only be confirmed on a live box (Phase 8 loopback bind, the approvals/skills wipe blast radius, `backfill_sessions` status) is verified on the sandbox box before jnow prod. SSH needs John present for the 1Password prompt.

---

## 6. Phased design

### Phase 1 — `06-install-stack.sh` + compose `.env` completeness *(install, frontend)*
Findings: #1, #3, #16, #17.

1. **#1 Image-pin duplicate:** stop preserving `CORTEX_IMAGE`/`FRONTEND_IMAGE` in `preserve_env_keys` so the script's heredoc value is authoritative (single line). Rationale: the pin should come from the reviewed script/env, never from the box's stale prior `.env`. Verify the resulting `.env` has exactly one line per pin and `docker compose config` resolves the intended (new) digest.
2. **#3 `CORTEX_API_KEY`:** (a) add `CORTEX_API_KEY` to the inline read-forward block (env > old .env > empty), so it survives a re-run; (b) add `CORTEX_API_KEY=${CORTEX_API_KEY:-}` to **both** the `cortex` and `dashboard` `environment:` blocks in the *deployed* `templates/docker-compose.yml`. Key stays UNSET on boxes (D5) — this is plumbing only, so enabling later is a pure config flip.
3. **#16 `HERMES_UI_HOSTNAME`:** add to inline read-forward. (Optional: a `fleetctl set-hermes-ui-hostname` verb to match its siblings — defer unless cheap.)
4. **#17 Operator tunables:** add `DASHBOARD_BIND` and `HIA_BASE_URL` to inline read-forward (the two with real operational blast radius). `LOG_LEVEL` / `DISCOVERY_MAX_*` are cosmetic — preserve them too for completeness, low cost.

**Tests:** a bats/shell harness that runs `06`'s `.env` generation against a fixture "old `.env`" containing every operator/Fleet key and asserts each survives with exactly one line and the correct value; plus a `docker compose config` assertion on pin resolution.

### Phase 2 — `ollie-fleetctl` update re-apply completeness *(install)*
Findings: #2, #7, #8, #10, #11, #12, #13.

1. **#2 `update stack` re-runs the stack installer:** replace the bare `compose pull/up` with a re-run of `06-install-stack.sh` (or a `stage-compose + refresh-pins` step) so a committed compose/pin change actually ships. This is the durable fix for the "update didn't take" class.
2. **#7 + #13 `update hermes` re-apply set:** add `09-install-identity-sync.sh` (command_allowlist) and re-run `03-install-profile.sh` for **every** installed profile (idempotent; heals pre-inheritance-fix profiles). Confirm `03` is safe to re-run per-profile.
3. **#10 `update orchestrator`:** re-run `05-install-orchestrator.sh` (or the orchestrator `install.sh`) so unit/env-contract changes apply — gate on a unit-hash/version if a full re-run is too heavy.
4. **#8 Onboarding-injection patch:** verify current ship status against `2026-06-08-onboarding-injection-patch-design.md`. If it's a real on-box patch, land it as a numbered idempotent script and add to both install order and the `update hermes` re-apply set; if it was superseded, delete the stale "re-apply after hermes update" doc line. **Verification task — do not assume.**
5. **#11 Single re-apply list (R2):** define the canonical set in `ollie-fleetctl`; make the README reference it. Canonical set after this phase: 03 (per profile), 04, 07, 08, 09, [onboarding if shipped], approvals (Phase 4).
6. **#12 Non-cortex plugins:** accept + add a guard/log if only cortex is vendored; no code change unless another plugin exists on a box (verification task).

**Tests:** unit-test the fleetctl `cmd_update` step list (assert the canonical set is present for each subcommand); dry-run mode that prints the planned steps.

### Phase 3 — Fleet Supabase durability *(fleet, install/fleetctl)*
Findings: #4, #5. **This closes the S72 outage class.**

1. **#4a Don't blank on disable:** in `set_dashboard_auth_supabase` (fleetctl), when a value is empty, **skip the write** rather than overwriting a good key with `""`. A disable should stop *using* Supabase (tri-state precedence) without *destroying* the keys.
2. **#4b `SUPABASE_COOKIE_DOMAIN` becomes Fleet-managed:** add it to Fleet's Supabase config model (`supabase-config.ts` `SaveSupabaseInput`) + the Access-tab UI + the fleetctl writer, so it's no longer a pure hand-edit that only `06`-preserve keeps alive.
3. **#5 Provision auto-applies Supabase:** at the enroll/provision tail, invoke the Supabase apply from Fleet's stored config so a fresh box never depends on a manual post-provision step. Guard: only if a Supabase config is stored for that instance.

**Tests:** fleetctl writer unit tests (disable path leaves keys intact; cookie-domain written); a Fleet-side test that provision calls supabase-apply when config present. **Attack-probe:** confirm no path can produce the empty-gate state (`SUPABASE_URL` empty while frontend recreates).

### Phase 4 — `approvals.mode` + agent-secret durability *(install, prospecting-agent, fleet)*
Findings: #6, #9.

1. **#6 `approvals.mode:"off"` written by code:** the prospecting-agent `install.sh` sets it idempotently (`hermes -p <profile> config set approvals.mode off`), and Phase 2's `update hermes` re-apply restores it. **First: verify on a live box** whether `hermes update` resets the default `~/.hermes/config.yaml` vs the per-profile `config.yaml` (audits B and E disagreed; E found per-profile config.yaml is in the backup set and survives). The fix covers both: make the setter own it regardless of the wipe boundary.
2. **#9 Apollo secret via Fleet injection:** the passthrough *wiring* is already in git and durable; only the secret **value** is manual. Have Fleet's "Add Prospecting Agent" accept `APOLLO_API_KEY` from an encrypted Fleet-stored secret and write it into the profile `.env` (mirroring how it already passes `ORCHESTRATOR_KEY`). Operator enters it once in Fleet, never re-types per rebuild. Also **verify** where installed agent skills physically live vs the `hermes update` wipe (reconciles STATE's "survives redeploy" claim).

**Tests:** installer idempotency test (approvals set once, re-run is a no-op); Fleet secret-injection unit test (key written to profile `.env`, not logged/argv).

### Phase 5 — Orchestrator run-ownership persistence *(orchestrator + Supabase migration)*
Finding: #14. **D3 = persist now.**

Mirror the existing, proven sessions pattern (`src/api/sessions.py`): `record_session`/`get_session_owner` upsert against a Supabase table keyed `(agent_id, hermes_session_id) → user_id`.

1. **Migration:** add a `run_owners` table keyed `(agent_id, run_id) → user_id, created_at` (+ RLS consistent with the sessions table).
2. **Write:** `_remember_run_owner()` (`runs.py:91`) upserts to Supabase (keep the in-memory dict as a fast-path cache).
3. **Read:** the run-access gate reads Supabase on a cache miss — so after a restart a member keeps access to their own in-flight runs.
4. **Fallback (preferred if viable):** since runs already carry a `session_id` and session ownership is persisted, derive run ownership from the session owner when the run's `session_id` is known — potentially avoiding a second table. Decide during planning by confirming a `run_id → session_id` durable link exists; if not, the `run_owners` table is the fix.
5. **#14 also:** fix the stale docstring at `runs.py:24-26` that wrongly claims fail-open.

**Tests:** unit test the gate resolves ownership from Supabase after the in-memory cache is cleared (simulated restart); TDD the migration up/down.

### Phase 6 — Legacy-record verification *(orchestrator, operational)*
Finding: #15. **D6/D7.**

1. Confirm `backfill_sessions.py` actually ran at the fail-closed cutover on each box (else every pre-existing session 403s its creator). Make it a **guaranteed idempotent step** in the deploy/update path so it can't be skipped.
2. Runs: no backfill (transient; Phase 5 covers new runs). Document the decision.

**Tests:** idempotency test on the backfill (safe to run twice, no dupes).

### Phase 7 — `INSTALL_REPO_REF` drift guard *(fleet, install)*
Finding: #18.

- Add a CI/pre-commit check in `ollie-fleet` (or a test) that **fails when the install-repo tip ≠ `INSTALL_REPO_REF`**, forcing an intentional bump. Optional: converge on-box `update hermes` to check out the pin instead of `master`, so provisioned and self-updated boxes never diverge. (Currently zero live drift — this is a guard, low urgency.)

**Tests:** the guard test itself (asserts equality; fails on drift).

### Phase 8 — Codify + verify the provider firewall *(fleet, install)* — DOWNSCOPED 2026-07-05
Finding: #19. **D4 (revised): keep `0.0.0.0`, do NOT rebind the gateway.**

Rationale for dropping the rebind: the gateway already requires `HERMES_GATEWAY_KEY` (it is not open), the boxes that matter sit behind a durable **provider/edge firewall** (Hetzner Cloud Firewall: inbound ICMP + SSH/22), and John already concluded in S70 that `0.0.0.0` + edge firewall is acceptable ("not a finding"). A rebind is the riskiest change in the workstream — it breaks the dashboard→gateway `host.docker.internal` path — for a benefit the edge firewall already provides. The real gap is that the firewall is **tribal/manual**, not the bind.

1. **Primary control = provider firewall, made non-tribal.** In order of preferred lift:
   - Best: Fleet attaches/verifies the provider firewall via the provider API at provision/enroll (Fleet already provisions Hetzner and holds the token).
   - Minimum: a **committed provisioning-checklist** item asserting the firewall requirement, **plus a Fleet health-check that probes the box's public IP and flags anything beyond `:22`/tunnel exposed** — turning "did someone attach the firewall?" into automated drift detection. This health-check is the core durability win.
2. **Host `ufw` is NOT in the default install for managed boxes** (avoids the SSH-lockout risk + extra host surface). Keep it only as a **documented fallback** for a self-managed / bare-metal / no-provider-firewall box, where it is the only portable option.
3. **Fleet-box lockdown:** prefer the Fleet box's own provider firewall over the manual `ufw` block in DEPLOY.md §9; codify/verify it the same way.

**Tests:** the exposure health-check itself (asserts only `:22`/tunnel reachable from off-box; flags drift). No bind change → no dashboard↔gateway regression risk.

---

## 7. Open verification items (resolve during implementation, sandbox-first)

1. `hermes update` wipe boundary for `config.yaml` (default vs per-profile) — sets the exact approvals fix (Phase 4).
2. Where installed agent skills physically live vs the wipe — reconciles STATE's "survives redeploy" (Phase 4).
3. Onboarding-injection patch ship status vs its design doc (Phase 2 #8).
4. `backfill_sessions.py` actually ran at cutover on each box (Phase 6).
5. `run_id → session_id` durable link for the Phase 5 fallback.
6. Per-box provider-firewall status + the baseline "expected exposure" (only `:22`/tunnel) that the Phase 8 health-check asserts against — live-box only.

---

## 8. Testing & rollout strategy

- **TDD per phase** (superpowers:test-driven-development): red → green → refactor; each phase's tests above land first.
- **subagent-driven-development** with per-phase review gates, mirroring the prior session; attack-probe the risky phases (P3 empty-gate, P5 access gate, P8 exposure).
- **All commits local + unpushed**, stacked on the security-batch HEAD per repo.
- **Deploy:** folded into the coordinated runbook as a follow-on; sandbox-first then jnow prod; P8 verified last.

---

## 9. Out of scope / explicitly deferred

- Enabling `CORTEX_API_KEY` (plumbing only this pass — D5).
- Backfilling legacy runs (D6) — not recoverable (the owner map was never persisted, so there is no source of truth to backfill from); Phase 5's session-owner fallback absorbs any legacy run still linked to a resolvable session, so no migration is needed.
- Any security-review work beyond the already-staged batch.
- Restructuring the numbered install scripts.

---

## 10. Spec self-review

- **Placeholders:** none — every phase has concrete files/approach; unknowns are explicitly listed as §7 verification tasks, not hidden TODOs.
- **Consistency:** the 19 findings each map to exactly one phase (§4); decisions (§3) are reflected in the phases they govern (D3→P5, D4→P8, D5→P1, D6/D7→P6).
- **Scope:** large but coherent (one theme: idempotency/durability). Likely produces multiple implementation plans (roughly one per phase) rather than a single plan — noted for writing-plans.
- **Ambiguity:** the one genuinely-open design choice (Phase 5 `run_owners` table vs session-derivation fallback) is called out with a recommended option to validate. Phase 8's bind change was dropped (2026-07-05); it is now firewall-codification + an exposure health-check only.
