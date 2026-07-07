-- Ollie-core 0005 — append-only, instance-scoped governance audit trail.
-- Consolidated FINAL STATE (as of 2026-07-07) of jnow-site 0005_governance_events.sql
-- + 0016_governance_rls_tags.sql + 0017_governance_tenancy.sql: instance_id is in
-- the create, and the select policy is the Phase 2b instance-scoped version
-- (NOT the 0005 role-list or 0016 tag-only intermediates).
-- Spec: ollie-hermes-orchestrator docs/superpowers/specs/2026-07-04-governance-tenancy-phase2b-design.md.

create table if not exists public.governance_events (
  id          uuid primary key default gen_random_uuid(),
  created_at  timestamptz not null default now(),
  user_email  text not null,                 -- who ran it (run's authenticated identity)
  user_role   text not null,                 -- their role at capture time
  app         text not null,                 -- e.g. 'newsletter'
  event_type  text not null,                 -- e.g. 'compliance_screen'
  status      text not null,                 -- 'pass'|'flagged'|'needs_review'|'unknown'
  title       text,                          -- human label
  findings    jsonb not null default '[]'::jsonb,  -- [{text, rule?, citation?, rewrite?}]
  content     text,                          -- the screened text (for review)
  run_id      text,                          -- Hermes run id (traceability)
  instance_id text                           -- producing box (orchestrator INSTANCE_ID)
);

create index if not exists governance_events_created_idx  on public.governance_events (created_at desc);
create index if not exists governance_events_email_idx    on public.governance_events (user_email);
create index if not exists governance_events_app_evt_idx  on public.governance_events (app, event_type);
create index if not exists governance_events_status_idx   on public.governance_events (status);
create index if not exists governance_events_instance_idx on public.governance_events (instance_id);

alter table public.governance_events enable row level security;

-- SELECT (Phase 2b): global compliance tag sees all; account_admin+ tier or an
-- explicit per-user governance_view grant sees their own instance's rows; everyone
-- sees their own rows. No INSERT/UPDATE/DELETE policies -> only the service role
-- (which bypasses RLS) can write. Append-only.
create policy governance_events_select on public.governance_events
  for select to authenticated
  using (
    -- (a) JNOW cross-instance oversight: the global compliance tag.
    (auth.jwt() -> 'tags') ? 'compliance'
    -- (b) Your own instance: account_admin+ tier OR an explicit per-user
    --     governance grant for THIS row's instance. Tier is never a JWT claim
    --     (Phase 2a.3), so we read user_roles directly; the subquery is filtered
    --     to ur.user_id = auth.uid(), which user_roles' select-own RLS allows.
    or exists (
      select 1 from public.user_roles ur
      where ur.user_id = auth.uid()
        and ur.instance_id = governance_events.instance_id
        and (ur.tier in ('account_admin', 'platform_operator') or ur.governance_view)
    )
    -- (c) Personal fallback: your own rows.
    or user_email = coalesce(auth.jwt() ->> 'email', '')
  );

comment on table public.governance_events is
  'Append-only governance/compliance audit trail; written by the orchestrator run-proxy via service role, read instance-scoped (Phase 2b).';
comment on column public.governance_events.instance_id is
  'Phase 2b: the box/instance that produced this event (orchestrator INSTANCE_ID).';
