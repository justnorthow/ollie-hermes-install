#!/usr/bin/env bash
# tests/test-supabase-stack-env.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/assert.sh"
. "$HERE/../scripts/lib/supabase-stack-env.sh"

test_fresh_render_generates_secrets_and_pins() {
  local d; d="$(mktemp -d)"
  export SUPABASE_PUBLIC_URL="https://sb.example.jnow.io"
  export GOOGLE_CLIENT_ID="" GOOGLE_CLIENT_SECRET=""
  render_supabase_stack_env "$d/.env" ""
  for k in POSTGRES_PASSWORD JWT_SECRET GOTRUE_JWT_KEYS JWT_JWKS ANON_KEY \
           SERVICE_ROLE_KEY SB_DB_IMAGE SB_AUTH_IMAGE SB_REST_IMAGE \
           SB_STORAGE_IMAGE SB_KONG_IMAGE; do
    v="$(supabase_stack_env_val "$d/.env" "$k")"
    assert_nonempty "fresh render sets $k" "$v"
  done
  assert_eq "google disabled when no client id" \
    "$(supabase_stack_env_val "$d/.env" GOOGLE_ENABLED)" "false"
  # No image pin may ever be 'latest'.
  ! grep -E '^SB_.*_IMAGE=.*latest' "$d/.env"
  assert_eq "no latest pins" "$?" "0"
}

test_rerun_preserves_secrets_and_restamps_pins() {
  local d; d="$(mktemp -d)"
  export SUPABASE_PUBLIC_URL="https://sb.example.jnow.io"
  export GOOGLE_CLIENT_ID="gid" GOOGLE_CLIENT_SECRET="gsec"
  render_supabase_stack_env "$d/.env" ""
  local secret1 anon1
  secret1="$(supabase_stack_env_val "$d/.env" JWT_SECRET)"
  anon1="$(supabase_stack_env_val "$d/.env" ANON_KEY)"
  # Simulate an old pin so we can prove pins get restamped, secrets don't.
  sed -i 's|^SB_KONG_IMAGE=.*|SB_KONG_IMAGE=kong:0.0-old|' "$d/.env"
  cp "$d/.env" "$d/.env.old"
  render_supabase_stack_env "$d/.env" "$d/.env.old"
  assert_eq "JWT_SECRET preserved" \
    "$(supabase_stack_env_val "$d/.env" JWT_SECRET)" "$secret1"
  assert_eq "ANON_KEY preserved" \
    "$(supabase_stack_env_val "$d/.env" ANON_KEY)" "$anon1"
  assert_eq "google creds preserved" \
    "$(supabase_stack_env_val "$d/.env" GOOGLE_CLIENT_SECRET)" "gsec"
  assert_eq "google enabled with client id" \
    "$(supabase_stack_env_val "$d/.env" GOOGLE_ENABLED)" "true"
  [ "$(supabase_stack_env_val "$d/.env" SB_KONG_IMAGE)" != "kong:0.0-old" ]
  assert_eq "pin restamped from renderer" "$?" "0"
}

test_fresh_render_generates_secrets_and_pins
test_rerun_preserves_secrets_and_restamps_pins
finish
