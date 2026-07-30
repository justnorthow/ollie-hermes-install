#!/usr/bin/env bash
# 27-install-nginx.sh — host nginx for the Hermes UI proxy (loopback only).
#
# NOTE this is NOT 22-install-caddy-vhosts.sh's situation. That script needs
# :80+:443 open and grey-cloud DNS for Let's Encrypt and MUST be skipped on a
# cloudflared box. This one binds loopback only, opens no ports, and therefore
# runs on EVERY box, cloudflared or not.
set -euo pipefail

if ! command -v nginx >/dev/null 2>&1; then
  echo "==> installing nginx"
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx
else
  echo "==> nginx already installed"
fi

# The stock default site listens on :80 on all interfaces. Nothing should claim
# :80 on these boxes — the front door is cloudflared.
if [[ -e /etc/nginx/sites-enabled/default ]]; then
  echo "==> removing stock nginx default site (:80 catch-all)"
  sudo rm -f /etc/nginx/sites-enabled/default
fi

sudo systemctl enable nginx >/dev/null 2>&1 || true

# reload-or-restart, NOT restart: this script is on the routine `ollie-fleetctl
# update hermes|all` path, and a hard restart drops every in-flight connection —
# including an operator's SSH-forwarded Hermes dashboard session. reload-or-restart
# reloads a running nginx in place and starts it when it isn't running, so the
# fresh-install case still works. Still gated on `nginx -t`: never (re)load a
# config nginx has rejected.
if sudo nginx -t; then
  sudo systemctl reload-or-restart nginx
  echo "==> nginx active: $(systemctl is-active nginx)"
else
  echo "27-install-nginx: FATAL — config test failed; not reloading nginx" >&2
  exit 1
fi
