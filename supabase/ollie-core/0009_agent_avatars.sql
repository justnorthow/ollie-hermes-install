-- Ollie-core 0009 — per-user agent avatar overrides + agent-avatars storage bucket.
-- Two-layer avatar model (spec ollie-hermes-frontend docs/superpowers/specs/
-- 2026-07-17-agent-avatars-design.md): a SHARED/company avatar (admin-set, pointer in
-- AGENTS_JSON) and a PER-USER override (member-set, this table).
--
-- SELF-HOSTED NOTE: each Ollie box runs its OWN co-located Supabase stack (per-box
-- isolation; there is no shared hosted project). That stack's storage-api does NOT
-- accept the browser's ES256 user token (only the HS256 service-role key), so BOTH
-- avatar layers are written server-side by the ORCHESTRATOR via the service role
-- (which bypasses RLS): shared bytes at shared/{instance_id}/{agent_id}.jpg, per-user
-- bytes at {user_id}/{agent_id}.jpg, and the per-user override rows in the table below.
-- The browser only READS public URLs. Hence there are deliberately NO client-facing
-- write policies here — all writes are service-role.

create table if not exists public.agent_avatar_overrides (
  user_id     uuid not null references auth.users(id) on delete cascade,
  agent_id    text not null,
  avatar_url  text not null,
  updated_at  timestamptz not null default now(),
  primary key (user_id, agent_id)
);

alter table public.agent_avatar_overrides enable row level security;

-- All access to this table is via the orchestrator's service role (which bypasses
-- RLS); the browser never reads or writes it directly, so there are NO client
-- policies. Drop any policies a prior version of this migration created so a re-apply
-- converges to the service-role-only state.
drop policy if exists agent_avatar_overrides_self_select on public.agent_avatar_overrides;
drop policy if exists agent_avatar_overrides_self_insert on public.agent_avatar_overrides;
drop policy if exists agent_avatar_overrides_self_update on public.agent_avatar_overrides;
drop policy if exists agent_avatar_overrides_self_delete on public.agent_avatar_overrides;

grant select, insert, update, delete on public.agent_avatar_overrides to service_role;

-- Storage bucket for avatar bytes:
--   per-user override → {user_id}/{agent_id}.jpg
--   shared/company    → shared/{instance_id}/{agent_id}.jpg
-- ALL writes are performed by the orchestrator service role (bypasses storage RLS);
-- the browser only reads. Public read is fine for cosmetic avatars.
insert into storage.buckets (id, name, public)
  values ('agent-avatars', 'agent-avatars', true)
  on conflict (id) do nothing;

-- No authenticated read/LIST policy: the bucket is public, so avatar bytes are
-- served via the /object/public/ path (no RLS) — the frontend only ever renders
-- known public URLs, and the orchestrator (service role) does all reads/writes.
-- Granting authenticated SELECT would let ANY signed-in user LIST/enumerate every
-- object in the bucket (and thus other users' {user_id}/ paths); omit it. Drop any
-- prior authenticated-read policy so a re-apply removes it.
drop policy if exists agent_avatars_read on storage.objects;

-- NO client-facing write policies: the browser's ES256 token isn't accepted by the
-- self-hosted storage-api, and all writes go through the orchestrator service role
-- (which bypasses RLS). Drop any write policies a prior version created so a re-apply
-- removes them cleanly.
drop policy if exists agent_avatars_self_write on storage.objects;
drop policy if exists agent_avatars_shared_admin_write on storage.objects;
