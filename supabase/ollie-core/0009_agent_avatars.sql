-- Ollie-core 0009 — per-user agent avatar overrides + agent-avatars storage bucket.
-- Two-layer avatar model (spec ollie-hermes-frontend docs/superpowers/specs/
-- 2026-07-17-agent-avatars-design.md): the SHARED avatar lives on the AGENTS_JSON
-- entry (orchestrator), set by admins. This table holds the PER-USER override a
-- member sets on their own scope:user Ollie — cosmetic, self-row RLS like profiles.
--
-- MULTI-TENANCY NOTE: all JNOW/Fleet boxes share ONE Supabase project, isolated
-- logically by instance_id (which is NOT a JWT claim and NOT known to the browser).
-- So the SHARED layer's bytes are written ONLY by the orchestrator via the service
-- role (which bypasses RLS) at shared/{instance_id}/{agent_id}.jpg — there is
-- deliberately NO client-facing shared/ write policy here (an RLS policy can't scope
-- to the caller's box). The PER-USER layer below is safe client-side: it is keyed by
-- the globally-unique user_id under self-row RLS, mirroring profiles.

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

-- Storage bucket for avatar bytes:
--   per-user override → {user_id}/{agent_id}.jpg   (written by the browser, self-RLS)
--   shared/company    → shared/{instance_id}/{agent_id}.jpg
--                       (written ONLY by the orchestrator service role, no RLS below)
-- Public read is fine for cosmetic avatars.
insert into storage.buckets (id, name, public)
  values ('agent-avatars', 'agent-avatars', true)
  on conflict (id) do nothing;

-- Any authenticated user may read (bucket is public anyway; explicit for clarity).
drop policy if exists agent_avatars_read on storage.objects;
create policy agent_avatars_read on storage.objects
  for select to authenticated using (bucket_id = 'agent-avatars');

-- A user may write only under their own {uid}/ prefix (the per-user override layer).
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

-- NO client-facing shared/ write policy: an RLS policy cannot scope a write to the
-- caller's instance (instance_id is not a JWT claim), so shared/ bytes are written
-- exclusively by the orchestrator's service role, which bypasses RLS. Drop any prior
-- shared-write policy so a re-apply of this migration removes it cleanly.
drop policy if exists agent_avatars_shared_admin_write on storage.objects;
