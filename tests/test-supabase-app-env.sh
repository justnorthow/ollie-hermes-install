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
case "$(uname -s)" in
  MINGW*|MSYS*) echo "SKIP: env is 0600 (NTFS cannot enforce unix mode bits)" ;;
  *) [ "$(stat -c %a "${TMP}/a.env" 2>/dev/null || stat -f %Lp "${TMP}/a.env")" = "600" ] \
       && ok "env is 0600" || bad "env is 0600" ;;
esac

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

# required params carried forward from OLD when unset (mirrors
# test_site_url_carried_forward_when_unset in test-supabase-stack-env.sh)
unset STACK_NAME KONG_PORT SUPABASE_PUBLIC_URL SITE_URL
render_supabase_app_env "${TMP}/e.env" "${TMP}/b.env" && ok "params carried forward exits 0" || bad "params carried forward exits 0"
[ "$(supabase_app_env_val "${TMP}/e.env" STACK_NAME)" = "hia" ] \
  && ok "STACK_NAME carried forward" || bad "STACK_NAME carried forward"
[ "$(supabase_app_env_val "${TMP}/e.env" KONG_PORT)" = "8010" ] \
  && ok "KONG_PORT carried forward" || bad "KONG_PORT carried forward"
[ "$(supabase_app_env_val "${TMP}/e.env" SUPABASE_PUBLIC_URL)" = "https://sb-hia.jnow.io" ] \
  && ok "SUPABASE_PUBLIC_URL carried forward" || bad "SUPABASE_PUBLIC_URL carried forward"
[ "$(supabase_app_env_val "${TMP}/e.env" SITE_URL)" = "https://hia.example.com" ] \
  && ok "SITE_URL carried forward" || bad "SITE_URL carried forward"

# required params missing everywhere (unset + stripped from OLD) hard-errors
grep -vE '^(STACK_NAME|KONG_PORT|SUPABASE_PUBLIC_URL|SITE_URL)=' "${TMP}/b.env" > "${TMP}/f.env"
ERR="$(render_supabase_app_env "${TMP}/g.env" "${TMP}/f.env" 2>&1)" \
  && bad "missing params refused" || ok "missing params refused"
printf '%s' "$ERR" | grep -q 'ERROR:.*STACK_NAME' \
  && ok "missing-param error names the param" || bad "missing-param error names the param"

# EMAIL_ENABLED: defaults true, explicit false honored, carried forward, junk refused
export STACK_NAME=hia KONG_PORT=8010 \
  SUPABASE_PUBLIC_URL=https://sb-hia.jnow.io SITE_URL=https://hia.example.com
unset EMAIL_ENABLED
render_supabase_app_env "${TMP}/h.env" "" || bad "email default render exits 0"
[ "$(supabase_app_env_val "${TMP}/h.env" EMAIL_ENABLED)" = "true" ] \
  && ok "EMAIL_ENABLED defaults true" || bad "EMAIL_ENABLED defaults true"
export EMAIL_ENABLED=false
render_supabase_app_env "${TMP}/i.env" "" || bad "email false render exits 0"
[ "$(supabase_app_env_val "${TMP}/i.env" EMAIL_ENABLED)" = "false" ] \
  && ok "EMAIL_ENABLED=false honored" || bad "EMAIL_ENABLED=false honored"
unset EMAIL_ENABLED
render_supabase_app_env "${TMP}/j.env" "${TMP}/i.env" || bad "email carry render exits 0"
[ "$(supabase_app_env_val "${TMP}/j.env" EMAIL_ENABLED)" = "false" ] \
  && ok "EMAIL_ENABLED carried forward" || bad "EMAIL_ENABLED carried forward"
export EMAIL_ENABLED=maybe
render_supabase_app_env "${TMP}/k.env" "" 2>/dev/null \
  && bad "EMAIL_ENABLED junk refused" || ok "EMAIL_ENABLED junk refused"
unset EMAIL_ENABLED

echo; echo "${pass} passed, ${fail} failed"; [ "$fail" -eq 0 ]
