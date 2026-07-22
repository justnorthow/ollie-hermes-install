-- Ollie-core 0012 — Redfin/FRED-backed local market stats (SP3), read by the
-- orchestrator /v1/market-data endpoint (Newsletter Studio "Auto-fill market
-- data"). Latest-month snapshot per geography we serve; service-role only.
--
-- PROVENANCE: ported from jnow-site development/core 0004_market_data.sql —
-- omitted from the initial ollie-core extraction. Populated by the monthly
-- Redfin ingest (jnow-workspace development/core/market-data/ingest_redfin.py)
-- pointed at the instance's Supabase; without rows the endpoint degrades to
-- "No market data on file" + FRED rates only.

create table if not exists public.market_data (
  region_type            text        not null check (region_type in ('zip','city','county')),
  region_key             text        not null,   -- normalized join key: 'williamson', 'round rock', '78664'
  region_label           text        not null,   -- display/citation label: 'Williamson County, TX'
  state_code             text        not null default 'TX',
  period_begin           date,
  period_end             date        not null,   -- the month this row covers
  median_sale_price      numeric,
  median_sale_price_yoy  numeric,                -- fractional: -0.023 = down 2.3%
  homes_sold             numeric,
  inventory              numeric,
  months_of_supply       numeric,
  median_dom             numeric,
  source                 text        not null default 'Redfin Data Center',
  as_of                  timestamptz not null default now(),
  primary key (region_type, region_key, period_end)
);

-- Service-role-only: RLS enabled with NO policies, so anon/authenticated get nothing
-- and only the service_role key (which bypasses RLS) can read/write. Matches the
-- read model used for profiles via get_profile_by_email.
alter table public.market_data enable row level security;

comment on table public.market_data is
  'SP3: latest-month local market stats ingested from Redfin Data Center; read by the orchestrator /v1/market-data endpoint via service role.';
