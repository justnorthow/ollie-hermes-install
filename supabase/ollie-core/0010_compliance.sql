-- Ollie-core 0010 — compliance rule KB + per-tier auto-approve + review RPCs, plus
-- the TRAIGA-readiness aggregation RPCs. Ported from jnow-site core (0006/0007/0010)
-- and ADAPTED for the self-hosted / orchestrator-service-role model:
--
--   * jnow-site gated these on a JWT `user_role` claim ('broker'/'compliance') that
--     does NOT exist on Ollie boxes, and stamped verified_by from the JWT email.
--     Here, the ONLY caller is the orchestrator via the service role (browser ES256
--     tokens are rejected by PostgREST on self-hosted). The orchestrator enforces
--     the compliance authz (compliance tag OR governance_view) before calling, so
--     the RPCs drop the JWT gate and take `p_verified_by` as a parameter (the
--     orchestrator passes the caller's X-Auth-Email).
--   * Tables get RLS enabled with NO client-facing policies (service-role only,
--     which bypasses RLS) — the browser never touches them directly.
--   * Per-box self-hosted Supabase means governance_events holds only this box's
--     rows, so the TRAIGA aggregations are naturally instance-scoped.

create table if not exists public.compliance_rules (
  id             uuid primary key default gen_random_uuid(),
  rule_key       text not null unique,
  hub            text not null,
  type           text not null,
  text           text not null,
  citation       text,
  source         text not null,
  confidence     text not null check (confidence in ('high','medium','low')),
  status         text not null default 'pending' check (status in ('pending','verified','rejected')),
  review_reasons jsonb not null default '[]'::jsonb,
  reviewer_note  text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  verified_at    timestamptz,
  verified_by    text
);
create index if not exists compliance_rules_status_idx on public.compliance_rules (status);
create index if not exists compliance_rules_hub_idx    on public.compliance_rules (hub);
create index if not exists compliance_rules_conf_idx   on public.compliance_rules (confidence);

create table if not exists public.compliance_config (
  id           int primary key default 1 check (id = 1),
  -- Only 'high'/'medium' are toggleable; 'low' is NEVER auto-approvable (hard floor).
  auto_approve jsonb not null default '{"high":false,"medium":false}'::jsonb,
  updated_at   timestamptz not null default now()
);
insert into public.compliance_config (id) values (1) on conflict (id) do nothing;

-- Service-role-only: RLS enabled, no client policies (browser never reads/writes these;
-- the orchestrator service role does, bypassing RLS). Drop-first so a re-apply of any
-- prior version converges to the no-client-policy state.
alter table public.compliance_rules  enable row level security;
alter table public.compliance_config enable row level security;
drop policy if exists compliance_rules_select  on public.compliance_rules;
drop policy if exists compliance_config_select on public.compliance_config;
drop policy if exists compliance_config_update on public.compliance_config;

grant select, insert, update, delete on public.compliance_rules  to service_role;
grant select, insert, update, delete on public.compliance_config to service_role;

-- Bulk reviewer action (N=1 or N-many). TIER-AGNOSTIC: a human reviewer MAY manually
-- verify a low-confidence rule; the hard floor governs only the AUTO path below.
-- p_verified_by supplied by the orchestrator (the caller's email); no JWT gate here.
create or replace function public.review_rules(
  p_rule_keys text[], p_decision text, p_note text default null, p_verified_by text default null
) returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if p_decision not in ('verified','rejected') then
    raise exception 'invalid decision';
  end if;
  update public.compliance_rules
     set status = p_decision, reviewer_note = p_note,
         verified_by = p_verified_by, verified_at = now(), updated_at = now()
   where rule_key = any(p_rule_keys);
  get diagnostics n = row_count;
  return n;
end; $$;
revoke execute on function public.review_rules(text[],text,text,text) from public, anon, authenticated;
grant execute on function public.review_rules(text[],text,text,text) to service_role;

-- Atomic per-tier auto-approve toggle. HARD FLOOR: 'low' (and any non high/medium)
-- is rejected. Enabling sweeps existing pending rules at that tier to verified;
-- disabling updates config only (never un-verifies).
create or replace function public.set_auto_approve(
  p_tier text, p_enabled boolean, p_verified_by text default null
) returns integer language plpgsql security definer set search_path = public as $$
declare n integer := 0;
begin
  if p_tier is null or p_tier not in ('high','medium') then
    raise exception 'low is never auto-approvable';
  end if;
  update public.compliance_config
     set auto_approve = jsonb_set(auto_approve, array[p_tier], to_jsonb(p_enabled)),
         updated_at = now()
   where id = 1;
  if p_enabled then
    update public.compliance_rules
       set status = 'verified', verified_by = p_verified_by,
           verified_at = now(), updated_at = now()
     where status = 'pending' and confidence = p_tier;
    get diagnostics n = row_count;
  end if;
  return n;
end; $$;
revoke execute on function public.set_auto_approve(text,boolean,text) from public, anon, authenticated;
grant execute on function public.set_auto_approve(text,boolean,text) to service_role;

-- Read-only aggregation over governance_events for the TRAIGA-readiness report.
-- Called by the orchestrator service role; on a per-box stack governance_events holds
-- only this box's rows, so the window aggregation is already instance-scoped.
create or replace function public.traiga_readiness_counts(p_from timestamptz, p_to timestamptz)
returns table (app text, event_type text, status text, n bigint)
language sql stable security definer set search_path = public as $$
  select app, event_type, status, count(*)::bigint as n
  from public.governance_events
  where created_at >= p_from and created_at < p_to
  group by app, event_type, status
$$;

create or replace function public.traiga_readiness_window(p_from timestamptz, p_to timestamptz)
returns table (total bigint, first_at timestamptz, last_at timestamptz)
language sql stable security definer set search_path = public as $$
  select count(*)::bigint as total, min(created_at) as first_at, max(created_at) as last_at
  from public.governance_events
  where created_at >= p_from and created_at < p_to
$$;

revoke execute on function public.traiga_readiness_counts(timestamptz,timestamptz) from public, anon, authenticated;
revoke execute on function public.traiga_readiness_window(timestamptz,timestamptz) from public, anon, authenticated;
grant execute on function public.traiga_readiness_counts(timestamptz,timestamptz) to service_role;
grant execute on function public.traiga_readiness_window(timestamptz,timestamptz) to service_role;
