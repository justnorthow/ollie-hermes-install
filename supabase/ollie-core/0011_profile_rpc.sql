-- Ollie-core 0011 — service-role RPC: resolve a profile by the user's VERIFIED
-- auth email (auth.users.email), for the orchestrator's GET /v1/profile (the
-- app-facing profile read used by Newsletter Studio and other vertical apps).
-- Keys on auth.users.email, NOT the user-editable public.profiles.email column.
--
-- PROVENANCE: ported from jnow-site development/core 0003_profile_rpc.sql —
-- omitted from the initial ollie-core extraction, so self-hosted instances
-- 404 on rpc/get_profile_by_email and /v1/profile 502s (hit live on the
-- sandbox Newsletter Studio, 2026-07-22: no coverage-area prefill and the
-- "Auto-fill market data" control never renders).

create or replace function public.get_profile_by_email(p_email text)
returns setof public.profiles
language sql
stable
security definer
set search_path = public
as $$
  select p.*
  from public.profiles p
  join auth.users u on u.id = p.user_id
  where u.email = p_email
  limit 1;
$$;

revoke execute on function public.get_profile_by_email(text) from authenticated, anon, public;
grant execute on function public.get_profile_by_email(text) to service_role;
