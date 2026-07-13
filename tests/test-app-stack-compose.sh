#!/usr/bin/env bash
# tests/test-app-stack-compose.sh — render checks for templates/supabase-app.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TPL="${DIR}/templates/supabase-app/docker-compose.yml"
KONG="${DIR}/templates/supabase-app/kong.yml"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

[ -f "$TPL" ] && ok "compose template exists" || bad "compose template exists"
[ -f "$KONG" ] && ok "kong template exists" || bad "kong template exists"

grep -q '^name:' "$TPL" && bad "no top-level name: (project set via -p)" || ok "no top-level name:"
grep -q 'container_name: \${STACK_NAME}-db' "$TPL" && ok "db container parameterized" || bad "db container parameterized"
grep -q '127.0.0.1:\${KONG_PORT}:8000' "$TPL" && ok "kong port parameterized" || bad "kong port parameterized"
grep -q 'GOTRUE_HOOK_CUSTOM_ACCESS_TOKEN' "$TPL" && bad "no ollie-core token hook" || ok "no ollie-core token hook"
grep -q 'GOTRUE_EXTERNAL_GOOGLE' "$TPL" && bad "no google oauth envs" || ok "no google oauth envs"
grep -q 'GOTRUE_MAILER_AUTOCONFIRM=true' "$TPL" && ok "autoconfirm on" || bad "autoconfirm on"
grep -q 'KONG_NGINX_HTTP_LARGE_CLIENT_HEADER_BUFFERS=8 24k' "$TPL" && ok "24k header buffers kept" || bad "24k header buffers kept"
grep -Eq 'profiles:.*realtime|profiles: \["realtime"\]' "$TPL" && ok "realtime behind profile" || bad "realtime behind profile"
grep -q 'realtime-dev.supabase-realtime' "$TPL" && ok "realtime tenant network alias" || bad "realtime tenant network alias"
grep -q '/realtime/v1/' "$KONG" && ok "kong realtime route" || bad "kong realtime route"
grep -q '__ANON_KEY__' "$KONG" && ok "kong key placeholders" || bad "kong key placeholders"

# compose config must interpolate cleanly with a full env file
TMP="$(mktemp -d)"
cat > "${TMP}/.env" <<'EOF'
STACK_NAME=hia
KONG_PORT=8010
POSTGRES_PASSWORD=x
JWT_SECRET=x
GOTRUE_JWT_KEYS=[]
JWT_JWKS={}
ANON_KEY=x
SERVICE_ROLE_KEY=x
SUPABASE_PUBLIC_URL=https://sb-hia.jnow.io
SITE_URL=https://hia.example.com
REALTIME_ENC_KEY=0123456789abcdef
REALTIME_SECRET_KEY_BASE=x
SB_DB_IMAGE=supabase/postgres:15.8.1.085
SB_AUTH_IMAGE=supabase/gotrue:v2.177.0
SB_REST_IMAGE=postgrest/postgrest:v12.2.12
SB_STORAGE_IMAGE=supabase/storage-api:v1.25.7
SB_KONG_IMAGE=kong:2.8.1
SB_REALTIME_IMAGE=supabase/realtime:pin
EOF
if command -v docker >/dev/null 2>&1; then
  docker compose -p hia -f "$TPL" --env-file "${TMP}/.env" config >/dev/null 2>&1 \
    && ok "compose config interpolates" || bad "compose config interpolates"
  docker compose -p hia -f "$TPL" --env-file "${TMP}/.env" --profile realtime config 2>/dev/null \
    | grep -q 'hia-realtime' && ok "profile enables realtime container" || bad "profile enables realtime container"
else
  echo "SKIP: docker not available (compose config checks)"
fi
rm -rf "$TMP"
echo; echo "${pass} passed, ${fail} failed"; [ "$fail" -eq 0 ]
