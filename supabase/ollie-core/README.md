# Ollie-core Supabase schema

The complete, self-contained schema an Ollie instance's Supabase project needs.
Written as **consolidated final-state DDL** (one file per concern), not a replay
of the jnow-site migration history it was extracted from.

## Apply order

Run in the project's SQL Editor (or via psql) in numeric order:

| File | Creates | Used by |
|---|---|---|
| `0001_agent_sessions.sql` | `agent_sessions` | orchestrator session ownership (list/read/delete + run-proxy gate) |
| `0002_run_owners.sql` | `run_owners` | orchestrator run-ownership gate across restarts (idempotency Phase 5) |
| `0003_user_roles.sql` | `user_roles`, `role_labels` | RBAC tiers (whoami, agent reachability, admin API) |
| `0004_user_tags.sql` | `user_tags` | global functional tags; JWT `tags` claim source |
| `0005_governance_events.sql` | `governance_events` | Gate-1 audit trail; Compliance/TRAIGA pages (instance-scoped RLS) |
| `0006_access_token_hook.sql` | `custom_access_token_hook()` | stamps `tags` + default `user_role` into JWTs |
| `0007_profiles.sql` | `profiles` + role-pin trigger | Profile page display fields, market area, avatar URLs |
| `0008_user_prefs.sql` | `user_prefs` | per-user dashboard preferences (Settings page; owner-only RLS) |
| `0009_agent_avatars.sql` | `agent_avatar_overrides`, `agent-avatars` bucket | per-user avatar overrides + avatar bytes storage (service-role only — no client RLS policies; browser reads via the public bucket path; all writes go through the orchestrator) |
| `0010_compliance.sql` | `compliance_rules`, `compliance_config` + `review_rules`/`set_auto_approve`/`traiga_readiness_*` RPCs | ported compliance KB + review RPCs + TRAIGA-readiness aggregations (service-role only; orchestrator enforces authz) |
| `0011_profile_rpc.sql` | `get_profile_by_email()` | orchestrator GET /v1/profile (app-facing profile read: Newsletter Studio prefill + market areas) |
| `0012_market_data.sql` | `market_data` | orchestrator GET /v1/market-data (Newsletter Studio auto-fill; populated by the monthly Redfin ingest) |

0005 depends on 0003 (its RLS policy subqueries `user_roles`); 0006 depends on
0004 (reads `user_tags`, relies on its `supabase_auth_admin` grant).

Everything is idempotent (`create table if not exists` / `create or replace`)
EXCEPT the `create policy` statements — re-running a file whose policies already
exist errors harmlessly; drop the policy first if you genuinely need to re-apply.

## After the SQL: dashboard checklist

SQL can't do these — see `docs/runbooks/supabase-ollie-core-provisioning.md`
for the full per-project runbook:

1. Register the auth hook (Authentication → Hooks → Customize Access Token (JWT)
   Claims → `public.custom_access_token_hook`). **Do this after 0006 or logins
   are unaffected; a registered-but-broken hook blocks all logins.**
2. Enable the Google provider + add the project's callback URL to the Google
   OAuth app.
3. Set Site URL / redirect URLs for the instance's hostname.
4. Hand `SUPABASE_URL`, anon key, service-role key, cookie domain to Fleet's
   per-instance Supabase config; orchestrator needs `SUPABASE_URL` (+
   `SUPABASE_JWT_SECRET` only for legacy HS256 projects — ES256/JWKS projects
   need no secret).
5. After the operator's first login, seed their `user_roles` row
   (`platform_operator`, the instance's `INSTANCE_ID`).

## Lineage rule (important)

As of 2026-07-07, the Ollie tables (`agent_sessions`, `run_owners`, `user_roles`,
`role_labels`, `user_tags`, `governance_events`, the access-token hook) **stop
evolving in the jnow-site migration chain**. New schema changes to these tables
land HERE, as new numbered files, and get applied to every instance project.
The jnow-site chain (0001–0017) remains the historical record for the original
shared project only.

## Provenance

Extracted 2026-07-07 from jnow-site `development/core/supabase/migrations/`
(0005, 0011, 0012, 0013, 0015→refactored, 0016+0017 folded into 0005's final
policy) and ollie-hermes-orchestrator `docs/migrations/0017_run_owners.sql`.
The hook (0006) is refactored to drop the site's `public.profiles` dependency —
`profiles` is a jnow-site concept and does not exist in instance projects.
