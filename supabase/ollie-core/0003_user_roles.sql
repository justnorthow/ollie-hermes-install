-- Ollie-core 0003 — RBAC roles + per-instance role labels.
-- Consolidated from jnow-site 0012_user_roles.sql with 0017_governance_tenancy.sql's
-- governance_view column folded into the create (final state as of 2026-07-07).
-- Spec: ollie-hermes-orchestrator docs/superpowers/specs/2026-07-03-rbac-scope-taxonomy-phase2a-design.md.

create table if not exists public.user_roles (
  instance_id      text not null,
  user_id          uuid not null,
  tier             text not null
    check (tier in ('member','manager','account_admin','platform_operator')),
  -- Phase 2b: per-user, per-instance opt-in to the instance governance audit
  -- view (the configurable manager); owners are covered by tier.
  governance_view  boolean not null default false,
  assigned_by      uuid,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  primary key (instance_id, user_id)
);

alter table public.user_roles enable row level security;

-- SELECT: a user may read only their own row (defense in depth; the orchestrator
-- reads via the service role, which bypasses RLS). No write policies -> only the
-- service role (the orchestrator admin API) may write.
create policy user_roles_select_own on public.user_roles
  for select to authenticated
  using (user_id = auth.uid());

create table if not exists public.role_labels (
  instance_id  text not null,
  tier         text not null
    check (tier in ('member','manager','account_admin','platform_operator')),
  label        text not null,
  primary key (instance_id, tier)
);

alter table public.role_labels enable row level security;

-- Labels are non-sensitive display text; any authenticated user may read them.
create policy role_labels_select_all on public.role_labels
  for select to authenticated using (true);

comment on table public.user_roles is
  'Phase 2a: instance-scoped RBAC tier per user; source of truth, orchestrator resolves by user_id.';
comment on column public.user_roles.governance_view is
  'Phase 2b: per-user, per-instance opt-in to the instance governance audit view (the configurable manager); owners are covered by tier.';
comment on table public.role_labels is
  'Phase 2a: per-instance customizable display labels for canonical tiers (cosmetic; never affects enforcement).';
