# Durable Per-Box Config — Design

- **Date:** 2026-07-06
- **Task:** task_40fb564d ("Make orchestrator per-box config durable")
- **Status:** APPROVED (John, 2026-07-06). Phased build: **Tier A builds now; Tier B/C are a planned follow-up.**
- **Related:** follow-on to the S74 idempotency-hardening workstream (`2026-07-05-idempotency-hardening-design.md`) and the S75 jnow-prod incident (OB1).

## Problem

A set of per-box config is set **out-of-band** during the S71/S72 rollouts and is written by **no install script**. When jnow prod was force-upgraded ~38 orchestrator commits + new install/images without that rollout, it broke four ways (all hand-fixed S75):

1. Agents flash-then-disappear on Chat — RBAC fail-closed (`INSTANCE_ID` unset + no `user_roles` seed).
2. Chat itself `503` "Run proxy not configured" — `HERMES_GATEWAY_URLS` unset.
3. Marketing-agent dashboard crash-loop (22,868×) — stale unit `ExecStart … --host 0.0.0.0`.
4. Management surface `401` for all agents — `HERMES_DASHBOARD_TOKEN` unset (+ no matching per-dashboard drop-ins).

Because nothing owns this config, **any rebuild, re-provision, or force-upgrade re-breaks a box** the same way.

## Goal

Every required box config is written by an install/Fleet path and **preserved on re-run**. No dependency on a human having run an S71/S72-era rollout. A rebuild or force-upgrade cannot leave a box in a broken state.

## Reference

Sandbox (`ollie@178.105.216.167`) holds the correct full config set — use it as the reference for expected shape/values.

## Ownership model

Ownership splits by *what knows the value*:

- **Install-owned** (on-box, derivable or generatable): P1 (`AGENTS_JSON` scope), P2 (dashboard-unit `--host`), P3 (proxy maps), P4 (dashboard token), P7 (parity check).
- **Fleet-owned / Fleet-instructs-box**: P5 (`INSTANCE_ID`), P6 (RBAC operator seed). At enroll, Fleet passes the operator's Supabase `user_id` + a chosen `INSTANCE_ID` to the box; the box writes `INSTANCE_ID` and seeds its own `user_roles` row using the **service-role key already on the box**. **Fleet never gets Supabase write access.**

## Config inventory (what a healthy box must have)

| Config | Location | Owner | Source / value |
|---|---|---|---|
| `INSTANCE_ID` | orchestrator `.env` | Fleet | Fleet instance UUID (new boxes); existing slugs grandfathered |
| `HERMES_GATEWAY_URLS` | orchestrator `.env` | install (05) | `{agentId: http://127.0.0.1:<gw port>}` from installed profiles |
| `HERMES_DASHBOARD_URLS` | orchestrator `.env` | install (05) | `{agentId: http://127.0.0.1:<dash port>}` from profiles/units |
| `HERMES_DASHBOARD_TOKEN` | orchestrator `.env` | install | generated once, reused if present |
| `session-token.conf` drop-ins | `~/.config/systemd/user/hermes-dashboard[-<profile>].service.d/` | install | `HERMES_DASHBOARD_SESSION_TOKEN` = same value as the orchestrator token |
| dashboard unit `--host 127.0.0.1` | `~/.config/systemd/user/hermes-dashboard*.service` | install (02/03) | canonical; never `0.0.0.0` |
| `AGENTS_JSON` `scope`/`manager_visible` | `~/hermes-stack/.env` | install (06) | preserved across the merge |
| `user_roles` operator seed | Supabase `kpdqhntsvjzhqjeupzsj` | Fleet-instructs-box | `platform_operator` @ `INSTANCE_ID` for the operator `user_id` |

---

## Tier A — build now (stops existing boxes re-breaking on update)

### P1 — `06` preserves `AGENTS_JSON` `scope` + `manager_visible`

- **File:** `scripts/06-install-stack.sh`, the python merge block (currently preserves `name`, `color`, `model` from the previous `AGENTS_JSON`; drops everything else).
- **Change:** in the merge, carry forward `scope` and `manager_visible` from the prior entry when present (same pattern as `color`/`model`: `if p.get("scope"): entry["scope"] = p["scope"]`).
- **Why:** re-running `06` currently regenerates `AGENTS_JSON` without `scope`, silently dropping the `scope:"user"` tag on the default (Ollie) agent → members lose access to Ollie (RBAC). This is what made a full `06` re-run unsafe during the S75 frontend deploy.
- **Test** (`tests/` harness, added in S74 Phase 1): feed an existing `AGENTS_JSON` whose `default` entry has `"scope":"user"` and another agent has `"manager_visible":true`; assert the re-rendered `AGENTS_JSON` still carries both. Also assert an agent with no `scope` stays absent (no spurious field).

### P2 — heal stale dashboard units (`--host 0.0.0.0` → `127.0.0.1`)

- **Where:** a dedicated idempotent heal helper in `scripts/lib/` (e.g. `heal-dashboard-units.sh`), invoked by the fleetctl `update` path (`update hermes`). Exact call site finalized in the plan.
- **Change:** scan `~/.config/systemd/user/hermes-dashboard*.service`; for any `ExecStart` containing `--host 0.0.0.0`, rewrite to `--host 127.0.0.1`; `systemctl --user daemon-reload`; restart any dashboard unit that is failed/inactive. Idempotent — a correct unit is left untouched.
- **Why:** current install code writes `--host 127.0.0.1` (`03-install-profile.sh:161`, `02-install-hermes.sh:111`, `ollie-fleetctl:742`, guarded by `test_fleetctl.py`), but **nothing regenerates stale existing units** created by an old installer → crash-loop survives updates.
- **Test** (bash): a fixture unit with `--host 0.0.0.0` is rewritten to `127.0.0.1`; a unit already at `127.0.0.1` is byte-identical after the heal (idempotent); non-dashboard units are untouched.

---

## Tier B — follow-up build (fresh provisions/rebuilds self-sufficient)

### P3 — install writes the orchestrator proxy maps

`05-install-orchestrator.sh` derives `HERMES_GATEWAY_URLS` and `HERMES_DASHBOARD_URLS` from the installed profiles/ports — the same detection `06` uses to build `AGENTS_JSON` (default gateway/dashboard ports + each profile's `API_SERVER_PORT` and the dashboard unit's `--port`). Writes them as `{agentId: http://127.0.0.1:<port>}` JSON maps into the orchestrator `.env`; preserves any operator-set value on re-run. The orchestrator is host-native, so `127.0.0.1` (not the container's `host.docker.internal`).

### P4 — install generates + persists the dashboard session token

On (re-)install of the orchestrator: if `HERMES_DASHBOARD_TOKEN` already exists in the orchestrator `.env`, **reuse it**; else generate one (`python3 -c "import secrets;print(secrets.token_urlsafe(32))"`). Write it as `HERMES_DASHBOARD_TOKEN` in the orchestrator `.env` **and** as a `session-token.conf` drop-in (`[Service]\nEnvironment=HERMES_DASHBOARD_SESSION_TOKEN=<same>`, mode 600) for every `hermes-dashboard*.service` unit; `daemon-reload` + restart dashboards. Idempotent: the value is stable across re-runs, so the dashboard's session token never randomizes and management calls never `401`.

### P5 — Fleet writes `INSTANCE_ID` at enroll

`INSTANCE_ID` = the Fleet instance UUID already minted in `enroll-core.ts` (`randomUUID()`), passed to the box and written into the orchestrator `.env` as part of `finalizeEnrollment`. Internal-only identifier (role display uses `role_labels`, separate), so a UUID is fine and collision-free. Existing slug-based boxes (`sandbox`/`jnow`) are **grandfathered** — already seeded + working; not migrated.

### P6 — Fleet-instructs-box RBAC seed

At enroll, Fleet hands the box the operator's Supabase `user_id` (the enrolling user, from `FinalizeParams.userId` — confirm this equals the Supabase auth user id) + the chosen `INSTANCE_ID`. The box's install seeds `user_roles(instance_id, user_id, 'platform_operator')` via the box-local `SUPABASE_SERVICE_ROLE_KEY` (idempotent upsert, `Prefer: resolution=merge-duplicates`). Fleet gets no Supabase write access.

---

## Tier C — follow-up build

### P7 — `check-box-config.sh` parity gate (report-only)

A check script (sibling of `check-box-exposure.sh`) that verifies a box has the full healthy config set: `INSTANCE_ID` set; `HERMES_GATEWAY_URLS`/`HERMES_DASHBOARD_URLS` present + non-empty + one entry per configured agent; `HERMES_DASHBOARD_TOKEN` present + a matching `session-token.conf` for every dashboard unit; no `--host 0.0.0.0` dashboard units; `whoami` for the operator returns a tier + non-empty `reachableAgentIds`. Report-only — prints each gap, exits non-zero if any. Run as a post-provision / post-update gate (like the exposure check).

---

## Testing strategy

- **Tier A:** the specific unit/bash tests above, plus the idempotency invariant — running the path twice produces zero drift (re-render `AGENTS_JSON` = same bytes; re-heal units = same bytes).
- **Tier B/C:** covered in the follow-up plan (fresh-install generates the full set; re-install preserves it; parity gate reports clean on a healthy box and flags each seeded gap on a stripped one).
- All fleetctl-touching changes run **both** pytest and the bash tests (S74 lesson).

## Out of scope / deferred

- Migrating existing slug-based boxes (`sandbox`/`jnow`) to UUID `INSTANCE_ID` — grandfathered.
- Auto-remediation in the parity gate — report-only first cut.
- Rotating an existing dashboard token — P4 only *generates when absent* + *preserves*; rotation is a separate concern.

## Decisions (John, 2026-07-06)

- **Scope:** full spec, phased build — Tier A (P1/P2) now, Tier B/C planned follow-up.
- **RBAC seed ownership:** Fleet-instructs-box (Fleet passes operator `user_id` + `INSTANCE_ID`; box seeds with its own service-role key; Fleet gets no Supabase write access).
- **`INSTANCE_ID`:** Fleet instance UUID for new boxes; existing slugs grandfathered.
- **Parity gate:** report-only (no auto-remediate) for the first cut.
