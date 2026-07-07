-- Ollie-core 0001 — per-user ownership of Hermes chat sessions.
-- Consolidated from jnow-site 0011_agent_sessions.sql (final state as of 2026-07-07).
-- Spec: ollie-hermes-orchestrator docs/superpowers/specs/2026-07-03-agent-instantiation-design.md §5.

create table if not exists public.agent_sessions (
  id                 uuid primary key default gen_random_uuid(),
  created_at         timestamptz not null default now(),
  last_active_at     timestamptz not null default now(),
  instance_id        text,                -- customer box id (nullable in v1 single-box installs)
  agent_id           text not null,       -- Hermes profile id (e.g. 'real-estate')
  hermes_session_id  text not null,       -- Hermes session id (opaque)
  user_id            uuid not null,       -- Supabase auth.users id (JWT `sub`)
  title              text,
  unique (agent_id, hermes_session_id)
);

create index if not exists agent_sessions_user_idx
  on public.agent_sessions (user_id, agent_id, last_active_at desc);

alter table public.agent_sessions enable row level security;

-- SELECT: own rows only (defense in depth — primary reads go through the
-- orchestrator's service role, which bypasses RLS). No INSERT/UPDATE/DELETE
-- policies -> only the service role can write.
create policy agent_sessions_select_own on public.agent_sessions
  for select to authenticated
  using (user_id = auth.uid());

comment on table public.agent_sessions is
  'Agent instantiation Phase 1: maps Hermes session ids to owning users; ownership enforced fail-closed by the orchestrator run-proxy.';
