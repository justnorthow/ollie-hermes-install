#!/usr/bin/env bash
# tests/test-25-install-app-bridge.sh — render-only checks (no root, no apt):
# the script must support BRIDGE_RENDER_ONLY=1 OUT=<dir> to render one
# <name>-bridge.service per NAME:PORT arg and exit before the root check.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

BRIDGE_RENDER_ONLY=1 OUT="$T/out" \
  bash "${DIR}/scripts/25-install-app-bridge.sh" \
  popbys:8130 otherapp:9200 >/dev/null 2>&1 \
  && ok "render exits 0" || bad "render exits 0"

grep -q 'TCP4-LISTEN:8130,bind=172.17.0.1' "$T/out/popbys-bridge.service" \
  && ok "popbys bridge listens on docker0 :8130" || bad "popbys bridge listens on docker0 :8130"
grep -q 'TCP4:127.0.0.1:8130' "$T/out/popbys-bridge.service" \
  && ok "popbys bridge forwards to loopback :8130" || bad "popbys bridge forwards to loopback :8130"
grep -q 'Description=Bridge docker0 172.17.0.1:8130' "$T/out/popbys-bridge.service" \
  && ok "popbys bridge description" || bad "popbys bridge description"

grep -q 'TCP4-LISTEN:9200,bind=172.17.0.1' "$T/out/otherapp-bridge.service" \
  && ok "otherapp bridge listens on docker0 :9200 (own file)" || bad "otherapp bridge listens on docker0 :9200 (own file)"
grep -q 'TCP4:127.0.0.1:9200' "$T/out/otherapp-bridge.service" \
  && ok "otherapp bridge forwards to loopback :9200" || bad "otherapp bridge forwards to loopback :9200"

# no args refuses
BRIDGE_RENDER_ONLY=1 OUT="$T/x" bash "${DIR}/scripts/25-install-app-bridge.sh" >/dev/null 2>&1 \
  && bad "no-args refused" || ok "no-args refused"

# bad args refuse
BRIDGE_RENDER_ONLY=1 OUT="$T/x" bash "${DIR}/scripts/25-install-app-bridge.sh" "no-port" >/dev/null 2>&1 \
  && bad "bad arg (no port) refused" || ok "bad arg (no port) refused"
BRIDGE_RENDER_ONLY=1 OUT="$T/x" bash "${DIR}/scripts/25-install-app-bridge.sh" "UPPER:8130" >/dev/null 2>&1 \
  && bad "bad arg (uppercase name) refused" || ok "bad arg (uppercase name) refused"
BRIDGE_RENDER_ONLY=1 OUT="$T/x" bash "${DIR}/scripts/25-install-app-bridge.sh" "x:notaport" >/dev/null 2>&1 \
  && bad "bad arg (non-numeric port) refused" || ok "bad arg (non-numeric port) refused"

echo; echo "${pass} passed, ${fail} failed"; [ "$fail" -eq 0 ]
