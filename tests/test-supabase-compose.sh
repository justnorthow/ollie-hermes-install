#!/usr/bin/env bash
# tests/test-supabase-compose.sh — static checks; docker not required.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/assert.sh"
COMPOSE="$HERE/../templates/supabase/docker-compose.yml"
KONG="$HERE/../templates/supabase/kong.yml"

test_compose_shape() {
  assert_file_exists "compose exists" "$COMPOSE"
  for svc in "db:" "auth:" "rest:" "storage:" "kong:"; do
    grep -qE "^  ${svc}" "$COMPOSE"; assert_eq "service ${svc}" "$?" "0"
  done
  # Only Kong publishes, loopback only.
  assert_eq "exactly one ports block" "$(grep -c 'ports:' "$COMPOSE")" "1"
  grep -q '127.0.0.1:8000:8000' "$COMPOSE"; assert_eq "kong loopback" "$?" "0"
  # Trimmed: no realtime/functions/analytics/studio services.
  for absent in realtime functions analytics studio imgproxy; do
    ! grep -qE "^  ${absent}:" "$COMPOSE"
    assert_eq "no ${absent} service" "$?" "0"
  done
  # Every image comes from a required .env pin (no inline tags, no latest).
  assert_eq "5 pinned image refs" \
    "$(grep -cE 'image: \$\{SB_(DB|AUTH|REST|STORAGE|KONG)_IMAGE:\?' "$COMPOSE")" "5"
  # Hook + signing keys env present on auth.
  grep -q 'GOTRUE_HOOK_CUSTOM_ACCESS_TOKEN_ENABLED' "$COMPOSE"; assert_eq "hook env" "$?" "0"
  grep -q 'GOTRUE_JWT_KEYS' "$COMPOSE"; assert_eq "signing keys env" "$?" "0"
  grep -q 'GOTRUE_HOOK_CUSTOM_ACCESS_TOKEN_URI=pg-functions://postgres/public/custom_access_token_hook' "$COMPOSE"
  assert_eq "hook uri env" "$?" "0"
  grep -q 'PGRST_JWT_SECRET=${JWT_JWKS}' "$COMPOSE"; assert_eq "rest jwt secret env" "$?" "0"
  # Site URL drives GoTrue's Site URL + scoped redirect allow-list — not
  # the wildcard/API-hostname combo the hosted-Supabase migration replaced.
  grep -F -q 'GOTRUE_SITE_URL=${SITE_URL}' "$COMPOSE"; assert_eq "site url env" "$?" "0"
  grep -F -q 'GOTRUE_URI_ALLOW_LIST=${SITE_URL}/**' "$COMPOSE"; assert_eq "scoped redirect allow-list" "$?" "0"
  # sb-<host> shares the apex cookie domain, so browsers send the zone's
  # whole cookie jar — beyond nginx's 8k default header buffer, kong 400s
  # every request before routing (sandbox cutover, 2026-07-11).
  grep -F -q 'KONG_NGINX_HTTP_LARGE_CLIENT_HEADER_BUFFERS=8 24k' "$COMPOSE"
  assert_eq "kong enlarged client header buffers" "$?" "0"
  # Without GOTRUE_JWT_ISSUER the self-hosted GoTrue mints iss-less tokens,
  # which issuer-enforcing validators reject (GetBilled, 2026-07-11).
  grep -F -q 'GOTRUE_JWT_ISSUER=${SUPABASE_PUBLIC_URL}/auth/v1' "$COMPOSE"
  assert_eq "gotrue jwt issuer env" "$?" "0"
}

test_jwt_secret_split_rest_vs_storage() {
  # PostgREST accepts a JWKS; storage-api (v1.25.7, verified) treats
  # PGRST_JWT_SECRET as a raw HS256 secret and 403s on a JWKS. Scope each
  # grep to its own service block (rest: up to storage:, storage: up to kong:)
  # so a regression in either direction is caught.
  local rest_block storage_block
  rest_block="$(sed -n '/^  rest:/,/^  storage:/p' "$COMPOSE")"
  storage_block="$(sed -n '/^  storage:/,/^  kong:/p' "$COMPOSE")"
  echo "$rest_block" | grep -F -q 'PGRST_JWT_SECRET=${JWT_JWKS}'
  assert_eq "rest service uses JWT_JWKS" "$?" "0"
  echo "$storage_block" | grep -F -q 'PGRST_JWT_SECRET=${JWT_SECRET}'
  assert_eq "storage service uses JWT_SECRET (raw HS256)" "$?" "0"
  echo "$storage_block" | grep -F -q 'PGRST_JWT_SECRET=${JWT_JWKS}'
  assert_eq "storage service does NOT use JWT_JWKS" "$?" "1"
}

test_kong_routes_and_consumers() {
  assert_file_exists "kong.yml exists" "$KONG"
  for path in "/auth/v1" "/rest/v1" "/storage/v1"; do
    grep -q -- "$path" "$KONG"; assert_eq "route $path" "$?" "0"
  done
  for consumer in "anon" "service_role"; do
    grep -q "username: ${consumer}" "$KONG"; assert_eq "consumer $consumer" "$?" "0"
  done
}

test_compose_shape
test_kong_routes_and_consumers
test_jwt_secret_split_rest_vs_storage
finish
