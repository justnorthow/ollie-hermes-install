#!/usr/bin/env bash
# 25-install-app-bridge.sh — install a socat bridge unit per NAME:PORT arg so
# the dashboard container (host.docker.internal = docker0 gateway 172.17.0.1)
# can reach a loopback-only (127.0.0.1) tile app server. This is the same fix
# 06-install-stack.sh already applies (hand-built) for the native Hermes
# dashboard on 9119 — parameterized here so any tile app gets its own bridge.
#
# Usage: 25-install-app-bridge.sh NAME:PORT [NAME:PORT …]
# Test hook: BRIDGE_RENDER_ONLY=1 OUT=<dir> renders <OUT>/<name>-bridge.service
#   per arg and exits. Run as root (installs system services).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPL="${SCRIPT_DIR}/../templates/systemd/app-bridge.service.tmpl"

if [[ $# -lt 1 ]]; then
  echo "usage: $0 NAME:PORT [NAME:PORT …]" >&2; exit 1
fi
for a in "$@"; do
  if [[ ! "$a" =~ ^[a-z][a-z0-9-]*:[0-9]+$ ]]; then
    echo "error: bad bridge arg '$a' (want name:port)" >&2; exit 1
  fi
done

render() { # NAME PORT OUT_DIR
  local name="$1" port="$2" out_dir="$3"
  sed -e "s|__NAME__|${name}|g" -e "s|__PORT__|${port}|g" "$TPL" \
    > "${out_dir}/${name}-bridge.service"
}

if [[ "${BRIDGE_RENDER_ONLY:-0}" == "1" ]]; then
  OUT_DIR="${OUT:?OUT required with BRIDGE_RENDER_ONLY}"
  mkdir -p "${OUT_DIR}"
  for a in "$@"; do
    name="${a%%:*}"; port="${a##*:}"
    render "${name}" "${port}" "${OUT_DIR}"
  done
  exit 0
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "error: run as root (installs a system service)" >&2; exit 1
fi

command -v socat >/dev/null 2>&1 || apt-get install -y -q socat

for a in "$@"; do
  name="${a%%:*}"; port="${a##*:}"
  render "${name}" "${port}" /etc/systemd/system
  systemctl daemon-reload
  systemctl enable --now "${name}-bridge.service"
  echo "    bridge (${name}): $(systemctl is-active "${name}-bridge.service")"
done
echo "✓ app bridge(s) installed: $*"
