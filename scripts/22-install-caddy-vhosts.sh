#!/usr/bin/env bash
# 22-install-caddy-vhosts.sh — install caddy (apt, official repo) and render
# /etc/caddy/Caddyfile with one HTTPS reverse-proxy vhost per HOST:PORT arg.
# Let's Encrypt certs are automatic (domains must already resolve to this box,
# DNS-only/grey-cloud — no Cloudflare proxy). Run as root. Idempotent.
#
# Usage: 22-install-caddy-vhosts.sh sb-hia.jnow.io:8010 [sb-ns.jnow.io:8020 …]
# Test hook: CADDY_RENDER_ONLY=1 OUT=<file> renders the Caddyfile and exits.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPL="${SCRIPT_DIR}/../templates/caddy/Caddyfile.vhost"

if [[ $# -lt 1 ]]; then
  echo "usage: $0 HOST:PORT [HOST:PORT …]" >&2; exit 1
fi
for a in "$@"; do
  if [[ ! "$a" =~ ^[a-z0-9.-]+:[0-9]+$ ]]; then
    echo "error: bad vhost arg '$a' (want host:port)" >&2; exit 1
  fi
done

render() { # OUT
  local out="$1" a host port
  : > "$out"
  for a in "${VHOSTS[@]}"; do
    host="${a%%:*}"; port="${a##*:}"
    sed -e "s|__HOST__|${host}|" -e "s|__PORT__|${port}|" "$TPL" >> "$out"
    echo >> "$out"
  done
}
VHOSTS=("$@")

if [[ "${CADDY_RENDER_ONLY:-0}" == "1" ]]; then
  render "${OUT:?OUT required with CADDY_RENDER_ONLY}"
  exit 0
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "error: run as root (installs a system service)" >&2; exit 1
fi

if ! command -v caddy >/dev/null 2>&1; then
  echo "==> caddy 1: install (official apt repo)"
  apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update && apt-get install -y caddy
fi

echo "==> caddy 2: render /etc/caddy/Caddyfile (${#VHOSTS[@]} vhost(s))"
[[ -f /etc/caddy/Caddyfile ]] && cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.bak-$(date +%Y%m%d-%H%M%S)"
render /etc/caddy/Caddyfile
caddy validate --config /etc/caddy/Caddyfile

echo "==> caddy 3: enable + reload"
systemctl enable --now caddy
systemctl reload caddy
echo "✓ caddy serving: ${VHOSTS[*]} (certs auto-issue on first request — DNS must already point here; open :80 AND :443 in the cloud firewall)"
