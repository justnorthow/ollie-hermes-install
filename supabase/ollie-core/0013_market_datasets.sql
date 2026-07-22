-- Ollie-core 0013 — broker-uploaded MLS market datasets (Newsletter Studio MLS
-- mode; spec: newsletter-studio docs/superpowers/specs/2026-07-22-mls-data-upload-design.md).
-- Instance-shared: one brokerage per box, so no per-user visibility filtering.
-- Service-role only; the orchestrator mediates all access and a human confirms
-- every dataset before it is saved (the model never writes here).

create table if not exists public.market_datasets (
  id            uuid primary key default gen_random_uuid(),
  label         text not null,              -- parser-extracted, user-editable ("Teravista", "Round Rock ISD")
  linked_area   jsonb,                      -- optional {type, value} from the profile's market_area
  period_label  text not null,              -- "June 2026" — what the studio form's Month field wants
  period_end    date,                       -- sort key, newest first
  figures       jsonb not null,             -- {medianSoldPrice, inventoryMonths, daysOnMarket, salesVolume} display strings
  source_label  text not null,              -- citation, e.g. "Unlock MLS — June 2026 Market Report"
  file_path     text,                       -- original upload in bucket market-uploads (provenance only)
  uploaded_by   uuid not null,              -- auth user id (trusted X-Auth-User-Id)
  uploader_name text,
  created_at    timestamptz not null default now()
);

-- Service-role-only: RLS enabled with NO policies (same posture as market_data).
alter table public.market_datasets enable row level security;

-- Private bucket for original uploads; served to no one (no public read, no
-- client RLS policies — orchestrator reads/writes with the service role).
insert into storage.buckets (id, name, public)
  values ('market-uploads', 'market-uploads', false)
  on conflict (id) do nothing;

comment on table public.market_datasets is
  'Broker-uploaded MLS market datasets (instance-shared); read by the orchestrator /v1/market-datasets endpoints via service role.';
