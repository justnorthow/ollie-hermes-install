#!/usr/bin/env bash
# tests/test-supabase-app-env.sh
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${DIR}/scripts/lib/supabase-app-env.sh" || { echo "FAIL: lib sources"; exit 1; }
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# fresh render generates everything
export STACK_NAME=hia KONG_PORT=8010 \
  SUPABASE_PUBLIC_URL=https://sb-hia.jnow.io SITE_URL=https://hia.example.com REALTIME=0
render_supabase_app_env "${TMP}/a.env" "" || bad "fresh render exits 0"
for k in POSTGRES_PASSWORD JWT_SECRET GOTRUE_JWT_KEYS JWT_JWKS ANON_KEY SERVICE_ROLE_KEY \
         REALTIME_ENC_KEY REALTIME_SECRET_KEY_BASE STACK_NAME KONG_PORT \
         SUPABASE_PUBLIC_URL SITE_URL SB_DB_IMAGE SB_REALTIME_IMAGE; do
  grep -q "^${k}=." "${TMP}/a.env" && ok "renders ${k}" || bad "renders ${k}"
done
[ "$(grep -c '^REALTIME_ENC_KEY=.\{16\}$' "${TMP}/a.env")" = "1" ] \
  && ok "enc key is 16 chars" || bad "enc key is 16 chars"
[ "$(stat -c %a "${TMP}/a.env" 2>/dev/null || stat -f %Lp "${TMP}/a.env")" = "600" ] \
  && ok "env is 0600" || bad "env is 0600"

# re-render preserves all secrets, restamps pins
sed -i.bak 's|^SB_DB_IMAGE=.*|SB_DB_IMAGE=stale:0|' "${TMP}/a.env"
OLD_JWT="$(grep '^JWT_SECRET=' "${TMP}/a.env")"
OLD_ENC="$(grep '^REALTIME_ENC_KEY=' "${TMP}/a.env")"
render_supabase_app_env "${TMP}/b.env" "${TMP}/a.env" || bad "re-render exits 0"
[ "$(grep '^JWT_SECRET=' "${TMP}/b.env")" = "$OLD_JWT" ] && ok "JWT preserved" || bad "JWT preserved"
[ "$(grep '^REALTIME_ENC_KEY=' "${TMP}/b.env")" = "$OLD_ENC" ] && ok "realtime enc preserved" || bad "realtime enc preserved"
grep -q '^SB_DB_IMAGE=stale:0' "${TMP}/b.env" && bad "pin restamped" || ok "pin restamped"

# partial JWT bundle refuses (all-or-nothing rule)
grep -v '^ANON_KEY=' "${TMP}/b.env" > "${TMP}/c.env"
render_supabase_app_env "${TMP}/d.env" "${TMP}/c.env" 2>/dev/null && bad "partial bundle refused" || ok "partial bundle refused"

echo; echo "${pass} passed, ${fail} failed"; [ "$fail" -eq 0 ]
