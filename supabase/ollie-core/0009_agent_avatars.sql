-- Ollie-core 0009 — per-user agent avatar overrides + agent-avatars storage bucket.
-- Two-layer avatar model (spec ollie-hermes-frontend docs/superpowers/specs/
-- 2026-07-17-agent-avatars-design.md): the SHARED avatar lives on the AGENTS_JSON
-- entry (orchestrator), set by admins. This table holds the PER-USER override a
-- member sets on their own scope:user Ollie — cosmetic, self-row RLS like profiles.

create table if not exists public.agent_avatar_overrides (
  user_id     uuid not null references auth.users(id) on delete cascade,
  agent_id    text not null,
  avatar_url  text not null,
  updated_at  timestamptz not null default now(),
  primary key (user_id, agent_id)
);

alter table public.agent_avatar_overrides enable row level security;

-- Policies are not idempotent — drop-first so the file is safe to re-apply.
drop policy if exists agent_avatar_overrides_self_select on public.agent_avatar_overrides;
create policy agent_avatar_overrides_self_select on public.agent_avatar_overrides
  for select to authenticated using (user_id = auth.uid());

drop policy if exists agent_avatar_overrides_self_insert on public.agent_avatar_overrides;
create policy agent_avatar_overrides_self_insert on public.agent_avatar_overrides
  for insert to authenticated with check (user_id = auth.uid());

drop policy if exists agent_avatar_overrides_self_update on public.agent_avatar_overrides;
create policy agent_avatar_overrides_self_update on public.agent_avatar_overrides
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists agent_avatar_overrides_self_delete on public.agent_avatar_overrides;
create policy agent_avatar_overrides_self_delete on public.agent_avatar_overrides
  for delete to authenticated using (user_id = auth.uid());

grant select, insert, update, delete on public.agent_avatar_overrides
  to authenticated, service_role;

-- Storage bucket for avatar bytes (shared/{agent_id}.jpg + {user_id}/{agent_id}.jpg).
-- Public read is fine for cosmetic avatars; writes are gated by the policies below.
insert into storage.buckets (id, name, public)
  values ('agent-avatars', 'agent-avatars', true)
  on conflict (id) do nothing;

-- Any authenticated user may read (bucket is public anyway; explicit for clarity).
drop policy if exists agent_avatars_read on storage.objects;
create policy agent_avatars_read on storage.objects
  for select to authenticated using (bucket_id = 'agent-avatars');

-- A user may write only under their own {uid}/ prefix.
drop policy if exists agent_avatars_self_write on storage.objects;
create policy agent_avatars_self_write on storage.objects
  for all to authenticated
  using (
    bucket_id = 'agent-avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  )
  with check (
    bucket_id = 'agent-avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- Only account_admin / platform_operator may write the shared/ prefix.
-- The user_roles self-select policy lets the subquery read the caller's own row.
drop policy if exists agent_avatars_shared_admin_write on storage.objects;
create policy agent_avatars_shared_admin_write on storage.objects
  for all to authenticated
  using (
    bucket_id = 'agent-avatars'
    and (storage.foldername(name))[1] = 'shared'
    and exists (
      select 1 from public.user_roles ur
      where ur.user_id = auth.uid()
        and ur.tier in ('account_admin', 'platform_operator')
    )
  )
  with check (
    bucket_id = 'agent-avatars'
    and (storage.foldername(name))[1] = 'shared'
    and exists (
      select 1 from public.user_roles ur
      where ur.user_id = auth.uid()
        and ur.tier in ('account_admin', 'platform_operator')
    )
  );
