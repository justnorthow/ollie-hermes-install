-- Ollie-core 0007 — user profile table (display fields + market area + avatar
-- URLs) read/written by the frontend Profile page (ollie-hermes-frontend
-- src/pages/shared/Profile.tsx: sb.from('profiles')).
--
-- PROVENANCE: extracted verbatim from the jnow-site shared schema (the original
-- hosted Ollie projects carried it before the 2026-07-07 ollie-core split). It
-- was omitted from the initial ollie-core extraction because authority/tier
-- moved to user_roles (0003); but the Profile page still stores its display
-- fields + headshot_url/logo_url here, so a trimmed self-hosted stack needs it
-- or the Profile page loads empty and avatar changes cannot persist (hit live
-- on the jnow prod cutover, 2026-07-12).
--
-- profiles.role is the LEGACY role column (distinct from user_roles.tier, which
-- is the source of truth for RBAC). current_role_name() + the pin_role trigger
-- preserve the original jnow-site broker/agent write semantics so behavior is
-- identical to the hosted projects; nothing in ollie-core enforcement reads it.

-- current_role_name()'s SQL body references public.profiles, which is created
-- further down — defer body validation so creation order doesn't matter (this
-- is exactly what pg_dump emits for the same reason).
set check_function_bodies = false;

-- pin_role_on_self_write(): a non-service_role caller may never set/change their
-- own role — INSERT forces 'agent', UPDATE preserves the prior value. Only the
-- service role (admin API / migration) may write role freely.
create or replace function public.pin_role_on_self_write() returns trigger
  language plpgsql security definer
  set search_path to 'public'
  as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    if tg_op = 'INSERT' then
      new.role := 'agent';
    elsif tg_op = 'UPDATE' then
      new.role := old.role;
    end if;
  end if;
  return new;
end;
$$;

-- current_role_name(): the caller's legacy profiles.role (used by the broker
-- write policy below). SECURITY DEFINER so the policy can read the row without
-- recursing through profiles' own RLS.
create or replace function public.current_role_name() returns text
  language sql stable security definer
  set search_path to 'public'
  as $$
  select role from public.profiles where user_id = auth.uid();
$$;

create table if not exists public.profiles (
  user_id         uuid not null primary key
    references auth.users(id) on delete cascade,
  role            text not null default 'agent'
    check (role = any (array['broker','agent','compliance','marketing'])),
  display_name    text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  market_area     jsonb not null default '[]'::jsonb,
  title           text,
  brokerage       text,
  license_number  text,
  phone           text,
  email           text,
  website         text,
  headshot_url    text,
  logo_url        text
);

drop trigger if exists trg_pin_role on public.profiles;
create trigger trg_pin_role before insert or update on public.profiles
  for each row execute function public.pin_role_on_self_write();

alter table public.profiles enable row level security;

-- Policies are not idempotent (no CREATE POLICY IF NOT EXISTS) — drop-first so
-- the file is safe to re-apply outside the migration ledger.
drop policy if exists auth_admin_read_profiles on public.profiles;
create policy auth_admin_read_profiles on public.profiles
  for select to supabase_auth_admin using (true);

drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles
  for select using (
    user_id = auth.uid()
    or public.current_role_name() = any (array['compliance','marketing','broker'])
  );

drop policy if exists profiles_self_insert on public.profiles;
create policy profiles_self_insert on public.profiles
  for insert with check (user_id = auth.uid());

drop policy if exists profiles_self_update on public.profiles;
create policy profiles_self_update on public.profiles
  for update using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists profiles_broker_write on public.profiles;
create policy profiles_broker_write on public.profiles
  using (public.current_role_name() = 'broker')
  with check (public.current_role_name() = 'broker');

-- PostgREST role grants (RLS still gates rows; grants gate table visibility).
grant select, insert, update, delete on public.profiles to anon, authenticated, service_role;
grant select on public.profiles to supabase_auth_admin;
grant execute on function public.current_role_name() to anon, authenticated, service_role;
