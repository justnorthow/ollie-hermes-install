#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${DIR}/tests/lib/assert.sh"
. "${DIR}/scripts/lib/app-server-env.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# fresh render
export APP_NAME=popbys APP_PORT=8130 CONTAINER_PORT=8080 HEALTH_PATH=/api/health
export APP_IMAGE="sha256:abc" APP_ENV_SUPABASE_URL="https://sb-popbys.jnow.io" APP_ENV_GOOGLE_MAPS_API_KEY="secret1"
render_app_server_env "$T/.env" ""
assert_eq "APP_PORT rendered" "$(app_server_env_val "$T/.env" APP_PORT)" "8130"
assert_eq "bare env key rendered" "$(app_server_env_val "$T/.env" SUPABASE_URL)" "https://sb-popbys.jnow.io"
assert_eq "PORT wired to container port" "$(app_server_env_val "$T/.env" PORT)" "8080"

# re-render with empty exports preserves; new APP_ENV overrides
cp "$T/.env" "$T/.env.old"
export APP_PORT="" APP_IMAGE="" APP_ENV_GOOGLE_MAPS_API_KEY="secret2"
unset APP_ENV_SUPABASE_URL
render_app_server_env "$T/.env" "$T/.env.old"
assert_eq "port carried forward" "$(app_server_env_val "$T/.env" APP_PORT)" "8130"
assert_eq "image carried forward" "$(app_server_env_val "$T/.env" APP_IMAGE)" "sha256:abc"
assert_eq "operator env preserved" "$(app_server_env_val "$T/.env" SUPABASE_URL)" "https://sb-popbys.jnow.io"
assert_eq "operator env overridden" "$(app_server_env_val "$T/.env" GOOGLE_MAPS_API_KEY)" "secret2"
assert_count "no duplicate SUPABASE_URL" "$T/.env" SUPABASE_URL 1
finish
