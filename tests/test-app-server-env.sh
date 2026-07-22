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

# reserved-name collisions are ignored, never duplicated
export APP_NAME=popbys APP_PORT=9000 CONTAINER_PORT=8000 HEALTH_PATH=/api/health APP_IMAGE="sha256:abc"
export APP_ENV_PORT=9999 APP_ENV_APP_PORT=7777 APP_ENV_SUPABASE_URL=u APP_ENV_SUPABASE_ANON_KEY=k
render_app_server_env "$T/.env3" ""
assert_count "single PORT line" "$T/.env3" PORT 1
assert_count "single APP_PORT line" "$T/.env3" APP_PORT 1
assert_eq "managed APP_PORT wins" "$(app_server_env_val "$T/.env3" APP_PORT)" "9000"
assert_eq "synthesized PORT wins" "$(app_server_env_val "$T/.env3" PORT)" "8000"
unset APP_ENV_PORT APP_ENV_APP_PORT

# app_image_from_env: reads APP_IMAGE from ${APPS_DIR:-$HOME/apps}/<name>/.env
export APPS_DIR="$T/apps"
mkdir -p "$APPS_DIR/popbys"
cp "$T/.env" "$APPS_DIR/popbys/.env"
assert_eq "app_image_from_env reads APP_IMAGE" "$(app_image_from_env popbys)" "sha256:abc"
assert_eq "app_image_from_env empty for missing app" "$(app_image_from_env nope)" ""

finish
