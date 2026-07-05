#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/assert.sh"
. "$HERE/../scripts/lib/stack-env.sh"

# Derived host values that 06 computes before rendering.
export GATEWAY_KEY="gwkey123" ORCH_KEY="orchkey123"
export CORTEX_IMAGE="justnorthow/cortex@sha256:NEW"
export FRONTEND_IMAGE="justnorthow/frontend@sha256:NEW"
export AGENTS_JSON='[{"id":"default","name":"Ollie"}]'

# Baseline: derived keys land; a preserved OAuth key survives.
test_baseline() {
  local old new; old="$(mktemp)"; new="$(mktemp)"
  cat > "$old" <<'OLD'
OAUTH2_PROXY_CLIENT_ID=abc123
OAUTH2_PROXY_COOKIE_SECRET=sekret
SUPABASE_URL=https://x.supabase.co
DASHBOARD_USER=admin
OLD
  ( unset FIRECRAWL_API_KEY HERMES_UI_URL VERTICAL \
          CORTEX_API_KEY HERMES_UI_HOSTNAME DASHBOARD_BIND HIA_BASE_URL
    render_stack_env "$new" "$old" )
  assert_eq  "HERMES_GATEWAY_KEY derived" "$(grep -E '^HERMES_GATEWAY_KEY=' "$new" | cut -d= -f2-)" "gwkey123"
  assert_eq  "ORCHESTRATOR_KEY derived"   "$(grep -E '^ORCHESTRATOR_KEY=' "$new" | cut -d= -f2-)" "orchkey123"
  assert_eq  "OAuth client id preserved"  "$(grep -E '^OAUTH2_PROXY_CLIENT_ID=' "$new" | cut -d= -f2-)" "abc123"
  assert_eq  "cookie secret preserved"    "$(grep -E '^OAUTH2_PROXY_COOKIE_SECRET=' "$new" | cut -d= -f2-)" "sekret"
  assert_eq  "SUPABASE_URL preserved"     "$(grep -E '^SUPABASE_URL=' "$new" | cut -d= -f2-)" "https://x.supabase.co"
  assert_eq  "DASHBOARD_USER preserved"   "$(grep -E '^DASHBOARD_USER=' "$new" | cut -d= -f2-)" "admin"
  rm -f "$old" "$new"
}

test_baseline
finish
