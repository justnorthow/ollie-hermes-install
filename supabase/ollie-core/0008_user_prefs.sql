-- 0008_user_prefs.sql — per-user dashboard preferences (Dashboard Settings page;
-- spec: ollie-fleet docs/superpowers/specs/2026-07-17-dashboard-settings-design.md).
-- One jsonb blob per user (viewMode, sidebarLayout, sidebarLabels). The dashboard
-- reads/writes it directly with the anon-key client; RLS scopes rows to their owner.
-- Idempotent except `create policy` (same caveat as the other ollie-core files).

create table if not exists public.user_prefs (
  user_id     uuid primary key references auth.users (id) on delete cascade,
  prefs       jsonb not null default '{}'::jsonb,
  updated_at  timestamptz not null default now()
);

alter table public.user_prefs enable row level security;

create policy user_prefs_select_own on public.user_prefs
  for select to authenticated
  using (user_id = auth.uid());

create policy user_prefs_insert_own on public.user_prefs
  for insert to authenticated
  with check (user_id = auth.uid());

create policy user_prefs_update_own on public.user_prefs
  for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

comment on table public.user_prefs is
  'Per-user dashboard preferences blob (view mode, sidebar layout/labels). Owner-only via RLS.';
