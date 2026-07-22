#!/usr/bin/env bash
# tests/test-23-install-app-server.sh — shim-based checks for the app-server deployer.
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
case "$1" in
  load)
    n=0
    [[ -f "${DOCKER_STATE}" ]] && n="$(cat "${DOCKER_STATE}")"
    n=$((n+1))
    echo "$n" > "${DOCKER_STATE}"
    echo "Loaded image: pop-bys:local"
    ;;
  inspect)
    n="$(cat "${DOCKER_STATE}" 2>/dev/null || echo 1)"
    if [[ "$n" -ge 2 ]]; then echo "sha256:fake2"; else echo "sha256:fake1"; fi
    ;;
  compose)
    : # logged above; nothing else to do
    ;;
esac
exit 0
SH

cat > "$T/bin/curl" <<'SH'
#!/usr/bin/env bash
echo "curl $*" >> "${CURL_LOG}"
mode="ok"
[[ -f "${CURL_MODE}" ]] && mode="$(cat "${CURL_MODE}")"
[[ "$mode" == "fail" ]] && exit 1
exit 0
SH
chmod +x "$T/bin/docker" "$T/bin/curl"
export PATH="$T/bin:$PATH"
export DOCKER_LOG="$T/docker.log" DOCKER_STATE="$T/docker-state" CURL_LOG="$T/curl.log" CURL_MODE="$T/curl-mode"
: > "$DOCKER_LOG"; : > "$CURL_LOG"
export APPS_DIR="$HOME/apps"

run() { printf '%s\n' "$@" | HEALTH_TRIES="${HEALTH_TRIES:-30}" HEALTH_SLEEP="${HEALTH_SLEEP:-0}" bash "${DIR}/scripts/23-install-app-server.sh"; }

# 1. fresh install
: > "$T/img.tar"
: > "$DOCKER_LOG"; : > "$CURL_LOG"
run "APP_NAME=popbys" "APP_PORT=8130" "IMAGE_TARBALL=$T/img.tar" \
  "APP_ENV_SUPABASE_URL=https://sb-popbys.jnow.io" "APP_ENV_SUPABASE_ANON_KEY=anon1" \
  >/dev/null 2>&1 && ok "fresh install exits 0" || bad "fresh install exits 0"
grep -q -- "load -i $T/img.tar" "$DOCKER_LOG" && ok "docker load invoked" || bad "docker load invoked"
[ -f "$HOME/apps/popbys/.env" ] && ok "env staged" || bad "env staged"
grep -q '^APP_IMAGE=sha256:fake1$' "$HOME/apps/popbys/.env" && ok "APP_IMAGE pinned from inspect" || bad "APP_IMAGE pinned from inspect"
grep -q -- "-p popbys-app" "$DOCKER_LOG" && ok "compose project -p popbys-app" || bad "compose project -p popbys-app"
grep -q "127.0.0.1:8130/api/health" "$CURL_LOG" && ok "health check hit right url" || bad "health check hit right url"

# 2. missing SUPABASE_URL -> exit 1 before compose up
: > "$T/img2a.tar"
: > "$DOCKER_LOG"; : > "$CURL_LOG"
run "APP_NAME=popbys2" "APP_PORT=8131" "IMAGE_TARBALL=$T/img2a.tar" \
  "APP_ENV_SUPABASE_ANON_KEY=anon-only" \
  >/dev/null 2>&1 && bad "missing SUPABASE_URL refused" || ok "missing SUPABASE_URL refused"
grep -q -- "up -d" "$DOCKER_LOG" && bad "no compose up on missing env" || ok "no compose up on missing env"

# 3. re-run with only APP_NAME carries APP_PORT/APP_IMAGE forward
: > "$DOCKER_LOG"; : > "$CURL_LOG"
run "APP_NAME=popbys" \
  >/dev/null 2>&1 && ok "carry-forward re-run exits 0" || bad "carry-forward re-run exits 0"
grep -q '^APP_PORT=8130$' "$HOME/apps/popbys/.env" && ok "APP_PORT carried forward" || bad "APP_PORT carried forward"
grep -q '^APP_IMAGE=sha256:fake1$' "$HOME/apps/popbys/.env" && ok "APP_IMAGE carried forward" || bad "APP_IMAGE carried forward"

# 4. re-run with new IMAGE_TARBALL restamps APP_IMAGE
: > "$T/img2.tar"
: > "$DOCKER_LOG"; : > "$CURL_LOG"
run "APP_NAME=popbys" "IMAGE_TARBALL=$T/img2.tar" \
  >/dev/null 2>&1 && ok "restamp re-run exits 0" || bad "restamp re-run exits 0"
grep -q '^APP_IMAGE=sha256:fake2$' "$HOME/apps/popbys/.env" && ok "APP_IMAGE restamped to new id" || bad "APP_IMAGE restamped to new id"

# 5. bad APP_NAME (Uppercase) refused
: > "$DOCKER_LOG"; : > "$CURL_LOG"
run "APP_NAME=PopBys" "APP_PORT=8132" \
  >/dev/null 2>&1 && bad "bad APP_NAME refused" || ok "bad APP_NAME refused"

# 6. health check failure -> exit 1 (fail loud), fast via HEALTH_TRIES/HEALTH_SLEEP
echo "fail" > "$CURL_MODE"
: > "$DOCKER_LOG"; : > "$CURL_LOG"
HEALTH_TRIES=2 HEALTH_SLEEP=0 run "APP_NAME=popbys" \
  >/dev/null 2>&1 && bad "failing health check exits 1" || ok "failing health check exits 1"
rm -f "$CURL_MODE"

echo; echo "${pass} passed, ${fail} failed"; [ "$fail" -eq 0 ]
