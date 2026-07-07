-- Ollie-core 0006 — access-token hook: stamp global `tags` (and a default
-- `user_role`) into every JWT.
--
-- OLLIE VARIANT of jnow-site 0015_hook_emit_tags.sql: the site's hook reads
-- `public.profiles.role` (a jnow-site table that does NOT exist in an Ollie
-- instance project). Here `user_role` is a constant 'agent' — its only
-- consumers on an instance are the orchestrator's /v1/auth/validate (which
-- already defaults absent claims to 'agent') and the governance_events
-- user_role audit column. Authority (tier) comes from user_roles (0003) and is
-- deliberately never a JWT claim. `tags` (0004) is what governance RLS (0005)
-- reads.
--
-- A broken hook BLOCKS ALL LOGINS. Apply only after 0004 (user_tags + the
-- supabase_auth_admin grant) and register it in the dashboard afterwards:
-- Authentication -> Hooks -> "Customize Access Token (JWT) Claims" -> this function.

-- Defensive: some project vintages don't grant the auth-hook role schema usage.
grant usage on schema public to supabase_auth_admin;

create or replace function public.custom_access_token_hook(event jsonb)
returns jsonb
language plpgsql
as $$
declare
  claims jsonb;
  found_tags jsonb;
begin
  select coalesce(jsonb_agg(tag), '[]'::jsonb) into found_tags
    from public.user_tags where user_id = (event->>'user_id')::uuid;
  claims := event->'claims';
  claims := jsonb_set(claims, '{user_role}', to_jsonb('agent'::text));
  claims := jsonb_set(claims, '{tags}', coalesce(found_tags, '[]'::jsonb));
  event := jsonb_set(event, '{claims}', claims);
  return event;
end;
$$;

grant execute on function public.custom_access_token_hook to supabase_auth_admin;
revoke execute on function public.custom_access_token_hook from authenticated, anon, public;
