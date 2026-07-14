#!/usr/bin/env bash
# tests/test-22-caddy-vhosts.sh — render-only checks (no root, no apt): the
# script must support CADDY_RENDER_ONLY=1 OUT=<file> to render and exit.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

CADDY_RENDER_ONLY=1 OUT="$T/Caddyfile" \
  bash "${DIR}/scripts/22-install-caddy-vhosts.sh" \
  sb-hia.jnow.io:8010 sb-ns.jnow.io:8020 >/dev/null 2>&1 \
  && ok "render exits 0" || bad "render exits 0"
grep -q '^sb-hia.jnow.io {' "$T/Caddyfile" && ok "vhost 1 block" || bad "vhost 1 block"
grep -q 'reverse_proxy 127.0.0.1:8010' "$T/Caddyfile" && ok "vhost 1 proxy" || bad "vhost 1 proxy"
grep -q '^sb-ns.jnow.io {' "$T/Caddyfile" && ok "vhost 2 block" || bad "vhost 2 block"
# no args refuses
CADDY_RENDER_ONLY=1 OUT="$T/x" bash "${DIR}/scripts/22-install-caddy-vhosts.sh" >/dev/null 2>&1 \
  && bad "no-args refused" || ok "no-args refused"
# bad arg refuses
CADDY_RENDER_ONLY=1 OUT="$T/x" bash "${DIR}/scripts/22-install-caddy-vhosts.sh" "no-port-here" >/dev/null 2>&1 \
  && bad "bad arg refused" || ok "bad arg refused"

echo; echo "${pass} passed, ${fail} failed"; [ "$fail" -eq 0 ]
