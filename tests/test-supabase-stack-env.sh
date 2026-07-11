#!/usr/bin/env bash
# tests/test-supabase-stack-env.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/assert.sh"
. "$HERE/../scripts/lib/supabase-stack-env.sh"

test_fresh_render_generates_secrets_and_pins() {
  local d; d="$(mktemp -d)"
  export SUPABASE_PUBLIC_URL="https://sb.example.jnow.io"
  export SITE_URL="https://example.jnow.io"
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
  assert_eq "fresh render sets SITE_URL" \
    "$(supabase_stack_env_val "$d/.env" SITE_URL)" "https://example.jnow.io"
  # No image pin may ever be 'latest'.
  ! grep -E '^SB_.*_IMAGE=.*latest' "$d/.env"
  assert_eq "no latest pins" "$?" "0"
}

test_site_url_carried_forward_when_unset() {
  local d; d="$(mktemp -d)"
  export SUPABASE_PUBLIC_URL="https://sb.example.jnow.io"
  export SITE_URL="https://example.jnow.io"
  export GOOGLE_CLIENT_ID="" GOOGLE_CLIENT_SECRET=""
  render_supabase_stack_env "$d/.env" ""
  cp "$d/.env" "$d/.env.old"
  unset SITE_URL
  render_supabase_stack_env "$d/.env" "$d/.env.old"
  assert_eq "SITE_URL carried forward from old .env" \
    "$(supabase_stack_env_val "$d/.env" SITE_URL)" "https://example.jnow.io"
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

test_partial_secrets_rejected() {
  local d; d="$(mktemp -d)"
  # Old env has only 2 of the 6 secret keys (simulates manual edit / interrupted write).
  cat > "$d/.env.old" <<EOF
JWT_SECRET=old-jwt-secret
ANON_KEY=old-anon-key
SB_KONG_IMAGE=kong:0.0-old
EOF
  local out="$d/.env"
  # Sentinel content: proves the renderer does not create/overwrite the output file.
  printf 'SENTINEL=untouched\n' > "$out"
  local before; before="$(cat "$out")"
  local err rc
  err="$(render_supabase_stack_env "$out" "$d/.env.old" 2>&1 1>/dev/null)"
  rc=$?
  assert_eq "partial secrets: non-zero return" "$rc" "1"
  echo "$err" | grep -qE 'POSTGRES_PASSWORD|GOTRUE_JWT_KEYS|JWT_JWKS|SERVICE_ROLE_KEY'
  assert_eq "stderr mentions a missing key name" "$?" "0"
  assert_eq "output file not overwritten" "$(cat "$out")" "$before"

  # Also prove it doesn't *create* the file when none exists yet.
  local out2="$d/.env2"
  render_supabase_stack_env "$out2" "$d/.env.old" 2>/dev/null
  [ ! -f "$out2" ]
  assert_eq "output file not created" "$?" "0"
}

test_fresh_render_generates_secrets_and_pins
test_site_url_carried_forward_when_unset
test_rerun_preserves_secrets_and_restamps_pins
test_partial_secrets_rejected
finish
