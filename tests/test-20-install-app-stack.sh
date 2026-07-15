#!/usr/bin/env bash
# tests/test-20-install-app-stack.sh — shim-based checks for the app-stack deployer.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
mkdir -p "$T/bin"
cat > "$T/bin/docker" <<'SH'
#!/usr/bin/env bash
echo "docker $*" >> "${DOCKER_LOG}"
# compose exec psql reads stdin — swallow it
[[ "$*" == *" exec "* ]] && cat >/dev/null
exit 0
SH
cat > "$T/bin/curl" <<'SH'
#!/usr/bin/env bash
echo "curl $*" >> "${CURL_LOG}"
echo -n "200"
SH
chmod +x "$T/bin/docker" "$T/bin/curl"
export PATH="$T/bin:$PATH" DOCKER_LOG="$T/docker.log" CURL_LOG="$T/curl.log"

run() { printf '%s\n' "$@" | bash "${DIR}/scripts/20-install-app-stack.sh"; }

# 1. missing STACK_NAME refuses
run "KONG_PORT=8010" "SUPABASE_PUBLIC_URL=https://sb-hia.jnow.io" "SITE_URL=https://hia.example.com" \
  >/dev/null 2>&1 && bad "missing STACK_NAME refused" || ok "missing STACK_NAME refused"

# 2. bad name refuses
run "STACK_NAME=Bad_Name" "KONG_PORT=8010" "SUPABASE_PUBLIC_URL=https://x.example" "SITE_URL=https://y.example" \
  >/dev/null 2>&1 && bad "bad name refused" || ok "bad name refused"

# 3. happy path, no realtime
: > "$DOCKER_LOG"; : > "$CURL_LOG"
run "STACK_NAME=hia" "KONG_PORT=8010" "SUPABASE_PUBLIC_URL=https://sb-hia.jnow.io" "SITE_URL=https://hia.example.com" \
  >/dev/null 2>&1 && ok "deploy exits 0" || bad "deploy exits 0"
[ -f "$HOME/stacks/hia/.env" ] && ok "env staged" || bad "env staged"
[ -f "$HOME/stacks/hia/kong.yml" ] && ok "kong staged" || bad "kong staged"
# Check if filesystem supports POSIX modes (skip on Windows NTFS)
_mode_probe="$T/mode-probe"; mkdir "$_mode_probe"; chmod 700 "$_mode_probe"
if [[ "$(stat -c %a "$_mode_probe" 2>/dev/null || stat -f %Lp "$_mode_probe")" == "700" ]]; then
  [ "$(stat -c %a "$HOME/stacks/hia" 2>/dev/null || stat -f %Lp "$HOME/stacks/hia")" = "700" ] \
    && ok "stack dir 0700" || bad "stack dir 0700"
else
  echo "SKIP: stack dir 0700 (filesystem does not enforce POSIX modes)"
fi
rm -rf "$_mode_probe"
grep -q '^KONG_PORT=8010$' "$HOME/stacks/hia/.env" && ok "port in env" || bad "port in env"
grep -q -- '-p hia -f' "$DOCKER_LOG" && ok "compose project -p hia" || bad "compose project -p hia"
grep -q -- '--profile realtime' "$DOCKER_LOG" && bad "no realtime profile by default" || ok "no realtime profile by default"
grep -q 'ALTER USER supabase_auth_admin' "$DOCKER_LOG" && ok "role passwords synced" || bad "role passwords synced"
grep -q '127.0.0.1:8010/auth/v1/health' "$CURL_LOG" && ok "health wait on kong port" || bad "health wait on kong port"
K1="$(grep '^JWT_SECRET=' "$HOME/stacks/hia/.env")"

# 4. realtime profile
: > "$DOCKER_LOG"
run "STACK_NAME=fieldkit" "KONG_PORT=8000" "SUPABASE_PUBLIC_URL=https://sb.fk.example" "SITE_URL=https://fk.example" "REALTIME=1" \
  >/dev/null 2>&1 && ok "realtime deploy exits 0" || bad "realtime deploy exits 0"
grep -q -- '--profile realtime' "$DOCKER_LOG" && ok "realtime profile passed" || bad "realtime profile passed"
grep -q 'CREATE SCHEMA IF NOT EXISTS _realtime' "$DOCKER_LOG" && ok "realtime schema pre-created" || bad "realtime schema pre-created"
grep -q 'restart realtime' "$DOCKER_LOG" && ok "realtime restarted after schema" || bad "realtime restarted after schema"

# 5. idempotent re-run (carry-forward, secrets preserved)
run "STACK_NAME=hia" >/dev/null 2>&1 && ok "carry-forward re-run exits 0" || bad "carry-forward re-run exits 0"
[ "$(grep '^JWT_SECRET=' "$HOME/stacks/hia/.env")" = "$K1" ] && ok "secrets preserved" || bad "secrets preserved"

# 6. .realtime marker persists the profile across re-runs (REALTIME omitted)
: > "$DOCKER_LOG"
run "STACK_NAME=fieldkit" >/dev/null 2>&1 && ok "realtime carry-forward re-run exits 0" || bad "realtime carry-forward re-run exits 0"
grep -q -- '--profile realtime' "$DOCKER_LOG" && ok "realtime profile persists via marker" || bad "realtime profile persists via marker"

echo; echo "${pass} passed, ${fail} failed"; [ "$fail" -eq 0 ]
