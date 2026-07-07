-- Ollie-core 0004 — GLOBAL functional tags (compliance/marketing) — non-authority.
-- Consolidated from jnow-site 0013_user_tags.sql (final state as of 2026-07-07).
-- Global (no instance_id): a functional tag is an attribute of the person and
-- rides the instance-blind JWT for governance RLS. Authority (tier) is separate,
-- per-instance (0003), and never a JWT claim.
-- Spec: ollie-hermes-orchestrator docs/superpowers/specs/2026-07-03-identity-consolidation-phase2a3-design.md.

create table if not exists public.user_tags (
  user_id     uuid not null,
  tag         text not null,
  created_at  timestamptz not null default now(),
  primary key (user_id, tag)
);

alter table public.user_tags enable row level security;

-- A user reads their own tags (defense in depth; orchestrator reads via service role).
create policy user_tags_select_own on public.user_tags
  for select to authenticated
  using (user_id = auth.uid());

-- The access-token hook (0006) runs as supabase_auth_admin and its SELECT is
-- subject to RLS — grant it a permissive read.
create policy user_tags_auth_admin_read on public.user_tags
  as permissive for select to supabase_auth_admin
  using (true);

-- No INSERT/UPDATE/DELETE policy -> only the service role (orchestrator admin API) writes.

-- Base table privilege: RLS gates rows, but supabase_auth_admin still needs the
-- SELECT grant to read the table at all.
grant select on public.user_tags to supabase_auth_admin;

comment on table public.user_tags is
  'Phase 2a.3: GLOBAL functional tags (compliance/marketing); non-authority; JWT-carried for governance RLS.';
