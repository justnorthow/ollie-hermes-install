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
  ( unset FIRECRAWL_API_KEY HERMES_UI_URL VERTICAL INSTANCE_TITLE \
          CORTEX_API_KEY HERMES_UI_HOSTNAME DASHBOARD_BIND HIA_BASE_URL NEWSLETTER_BASE_URL
    render_stack_env "$new" "$old" )
  assert_eq  "HERMES_GATEWAY_KEY derived" "$(grep -E '^HERMES_GATEWAY_KEY=' "$new" | cut -d= -f2-)" "gwkey123"
  assert_eq  "ORCHESTRATOR_KEY derived"   "$(grep -E '^ORCHESTRATOR_KEY=' "$new" | cut -d= -f2-)" "orchkey123"
  assert_eq  "OAuth client id preserved"  "$(grep -E '^OAUTH2_PROXY_CLIENT_ID=' "$new" | cut -d= -f2-)" "abc123"
  assert_eq  "cookie secret preserved"    "$(grep -E '^OAUTH2_PROXY_COOKIE_SECRET=' "$new" | cut -d= -f2-)" "sekret"
  assert_eq  "SUPABASE_URL preserved"     "$(grep -E '^SUPABASE_URL=' "$new" | cut -d= -f2-)" "https://x.supabase.co"
  assert_eq  "DASHBOARD_USER preserved"   "$(grep -E '^DASHBOARD_USER=' "$new" | cut -d= -f2-)" "admin"
  rm -f "$old" "$new"
}

# A box already carrying an OLD pin must end up with exactly ONE pin line = the
# NEW script-derived digest (the duplicate-key/last-wins trap must be gone).
test_pins_single_and_new() {
  local old new; old="$(mktemp)"; new="$(mktemp)"
  cat > "$old" <<'OLD'
CORTEX_IMAGE=justnorthow/cortex@sha256:OLD
FRONTEND_IMAGE=justnorthow/frontend@sha256:OLD
OAUTH2_PROXY_CLIENT_ID=keepme
OLD
  ( unset FIRECRAWL_API_KEY HERMES_UI_URL VERTICAL INSTANCE_TITLE \
          CORTEX_API_KEY HERMES_UI_HOSTNAME DASHBOARD_BIND HIA_BASE_URL NEWSLETTER_BASE_URL
    render_stack_env "$new" "$old" )
  assert_count "exactly one CORTEX_IMAGE line"   "$new" "CORTEX_IMAGE" 1
  assert_count "exactly one FRONTEND_IMAGE line" "$new" "FRONTEND_IMAGE" 1
  assert_eq "CORTEX_IMAGE = new digest"   "$(grep -E '^CORTEX_IMAGE=' "$new" | cut -d= -f2-)"   "justnorthow/cortex@sha256:NEW"
  assert_eq "FRONTEND_IMAGE = new digest" "$(grep -E '^FRONTEND_IMAGE=' "$new" | cut -d= -f2-)" "justnorthow/frontend@sha256:NEW"
  assert_eq "unrelated OAuth key still preserved" "$(grep -E '^OAUTH2_PROXY_CLIENT_ID=' "$new" | cut -d= -f2-)" "keepme"
  rm -f "$old" "$new"
}

test_baseline
test_pins_single_and_new

# CORTEX_API_KEY must survive a re-run (forwarded from old .env), and default to
# empty when neither env var nor old .env set it (stays UNSET on boxes this pass).
test_cortex_api_key_forwarded() {
  local old new; old="$(mktemp)"; new="$(mktemp)"
  printf 'CORTEX_API_KEY=secret-token\n' > "$old"
  ( unset CORTEX_API_KEY FIRECRAWL_API_KEY HERMES_UI_URL VERTICAL INSTANCE_TITLE \
          HERMES_UI_HOSTNAME DASHBOARD_BIND HIA_BASE_URL NEWSLETTER_BASE_URL
    render_stack_env "$new" "$old" )
  assert_eq "CORTEX_API_KEY preserved" "$(grep -E '^CORTEX_API_KEY=' "$new" | cut -d= -f2-)" "secret-token"

  local old2 new2; old2="$(mktemp)"; new2="$(mktemp)"
  : > "$old2"
  ( unset CORTEX_API_KEY FIRECRAWL_API_KEY HERMES_UI_URL VERTICAL INSTANCE_TITLE \
          HERMES_UI_HOSTNAME DASHBOARD_BIND HIA_BASE_URL NEWSLETTER_BASE_URL
    render_stack_env "$new2" "$old2" )
  assert_count "CORTEX_API_KEY line present (empty ok)" "$new2" "CORTEX_API_KEY" 1
  assert_eq "CORTEX_API_KEY empty by default" "$(grep -E '^CORTEX_API_KEY=' "$new2" | cut -d= -f2-)" ""
  rm -f "$old" "$new" "$old2" "$new2"
}

test_cortex_api_key_forwarded

# Operator-set dashboard/host tunables must survive a re-run instead of drifting
# back to the compose defaults.
test_operator_tunables_preserved() {
  local old new; old="$(mktemp)"; new="$(mktemp)"
  cat > "$old" <<'OLD'
HERMES_UI_HOSTNAME=hermes.jnow.io
DASHBOARD_BIND=0.0.0.0
HIA_BASE_URL=https://hia.example.com
NEWSLETTER_BASE_URL=https://ns.example.com
OLD
  ( unset HERMES_UI_HOSTNAME DASHBOARD_BIND HIA_BASE_URL NEWSLETTER_BASE_URL \
          CORTEX_API_KEY FIRECRAWL_API_KEY HERMES_UI_URL VERTICAL INSTANCE_TITLE
    render_stack_env "$new" "$old" )
  assert_eq "HERMES_UI_HOSTNAME preserved" "$(grep -E '^HERMES_UI_HOSTNAME=' "$new" | cut -d= -f2-)" "hermes.jnow.io"
  assert_eq "DASHBOARD_BIND preserved"     "$(grep -E '^DASHBOARD_BIND=' "$new" | cut -d= -f2-)" "0.0.0.0"
  assert_eq "HIA_BASE_URL preserved"       "$(grep -E '^HIA_BASE_URL=' "$new" | cut -d= -f2-)" "https://hia.example.com"
  assert_eq "NEWSLETTER_BASE_URL preserved" "$(grep -E '^NEWSLETTER_BASE_URL=' "$new" | cut -d= -f2-)" "https://ns.example.com"
  rm -f "$old" "$new"
}

test_operator_tunables_preserved

# INSTANCE_TITLE (set from the Ollie UI via the orchestrator) must survive a
# stack re-render, and default to an empty (but present) line when never set.
test_instance_title_forwarded() {
  local old new; old="$(mktemp)"; new="$(mktemp)"
  printf 'INSTANCE_TITLE=JNOW Prod\n' > "$old"
  ( unset INSTANCE_TITLE FIRECRAWL_API_KEY HERMES_UI_URL VERTICAL \
          CORTEX_API_KEY HERMES_UI_HOSTNAME DASHBOARD_BIND HIA_BASE_URL NEWSLETTER_BASE_URL
    render_stack_env "$new" "$old" )
  assert_eq "INSTANCE_TITLE preserved" "$(grep -E '^INSTANCE_TITLE=' "$new" | cut -d= -f2-)" "JNOW Prod"

  local old2 new2; old2="$(mktemp)"; new2="$(mktemp)"
  : > "$old2"
  ( unset INSTANCE_TITLE FIRECRAWL_API_KEY HERMES_UI_URL VERTICAL \
          CORTEX_API_KEY HERMES_UI_HOSTNAME DASHBOARD_BIND HIA_BASE_URL NEWSLETTER_BASE_URL
    render_stack_env "$new2" "$old2" )
  assert_count "INSTANCE_TITLE line present (empty ok)" "$new2" "INSTANCE_TITLE" 1
  rm -f "$old" "$new" "$old2" "$new2"
}

test_instance_title_forwarded

# Comprehensive golden regression: every operator/Fleet key + old pins survive a
# stack re-render exactly once with the right value; pins bump to the new digest.
test_golden_full_env() {
  local old new; old="$(mktemp)"; new="$(mktemp)"
  cat > "$old" <<'OLD'
CORTEX_IMAGE=justnorthow/cortex@sha256:OLD
FRONTEND_IMAGE=justnorthow/frontend@sha256:OLD
OAUTH2_PROXY_CLIENT_ID=cid
OAUTH2_PROXY_CLIENT_SECRET=csecret
OAUTH2_PROXY_COOKIE_SECRET=cookiesecret
OAUTH2_PROXY_REDIRECT_URL=https://x/oauth2/callback
OAUTH2_PROXY_PROVIDER=google
OAUTH2_PROXY_EMAIL_DOMAINS=*
OAUTH2_PROXY_AUTHENTICATED_EMAILS_FILE=/etc/oauth2-proxy/emails
DASHBOARD_PUBLIC_HTTPS=true
DASHBOARD_USER=admin
DASHBOARD_PASS=pw
SUPABASE_URL=https://x.supabase.co
SUPABASE_ANON_KEY=sb_anon
SUPABASE_COOKIE_DOMAIN=.jnow.io
FIRECRAWL_API_KEY=fc_key
HERMES_UI_URL=https://ui.jnow.io
VERTICAL=real-estate
INSTANCE_TITLE=JNOW Prod
CORTEX_API_KEY=cortex-secret
HERMES_UI_HOSTNAME=hermes.jnow.io
DASHBOARD_BIND=0.0.0.0
HIA_BASE_URL=https://hia
NEWSLETTER_BASE_URL=https://ns
OLD
  ( unset FIRECRAWL_API_KEY HERMES_UI_URL VERTICAL INSTANCE_TITLE CORTEX_API_KEY \
          HERMES_UI_HOSTNAME DASHBOARD_BIND HIA_BASE_URL NEWSLETTER_BASE_URL
    render_stack_env "$new" "$old" )
  local k
  for k in OAUTH2_PROXY_CLIENT_ID OAUTH2_PROXY_CLIENT_SECRET OAUTH2_PROXY_COOKIE_SECRET \
           OAUTH2_PROXY_REDIRECT_URL OAUTH2_PROXY_PROVIDER OAUTH2_PROXY_EMAIL_DOMAINS \
           OAUTH2_PROXY_AUTHENTICATED_EMAILS_FILE DASHBOARD_PUBLIC_HTTPS DASHBOARD_USER \
           DASHBOARD_PASS SUPABASE_URL SUPABASE_ANON_KEY SUPABASE_COOKIE_DOMAIN \
           FIRECRAWL_API_KEY HERMES_UI_URL VERTICAL INSTANCE_TITLE CORTEX_API_KEY HERMES_UI_HOSTNAME \
           DASHBOARD_BIND HIA_BASE_URL NEWSLETTER_BASE_URL CORTEX_IMAGE FRONTEND_IMAGE; do
    assert_count "exactly one ${k}" "$new" "$k" 1
  done
  assert_eq "pin bumped to new" "$(grep -E '^CORTEX_IMAGE=' "$new" | cut -d= -f2-)" "justnorthow/cortex@sha256:NEW"
  assert_eq "supabase cookie domain preserved" "$(grep -E '^SUPABASE_COOKIE_DOMAIN=' "$new" | cut -d= -f2-)" ".jnow.io"
  assert_eq "apollo-not-a-key sanity: vertical preserved" "$(grep -E '^VERTICAL=' "$new" | cut -d= -f2-)" "real-estate"
  assert_eq "instance title preserved" "$(grep -E '^INSTANCE_TITLE=' "$new" | cut -d= -f2-)" "JNOW Prod"
  rm -f "$old" "$new"
}

test_golden_full_env
finish
