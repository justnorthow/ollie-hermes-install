#!/usr/bin/env bash
# 04-install-cortex-plugin.sh — register the Cortex memory plugin with Hermes.
#
# Run as: ubuntu
# Idempotent: safe to re-run.
#
# What it does:
#   1. Clones (or refreshes) the cortex repo at /tmp
#   2. Copies plugins/memory/cortex/ into Hermes' bundled memory plugins dir
#   3. Activates cortex as the memory provider via `hermes config set memory.provider cortex`
#   4. Restarts every running gateway so they pick up the provider for new sessions
#
# Why it lives in hermes-agent/plugins/memory/ (not ~/.hermes/plugins/):
#   Hermes discovers memory provider plugins from its bundled plugins/memory/
#   tree. User-installed plugins via `hermes plugins install` are for tool
#   plugins, not memory providers. The plugin's __init__.py registers via
#   register_memory_provider().
#
# Tradeoff: this dir is reset by `hermes update`, so this script needs to be
# re-run after every Hermes update. Mitigation: docs/post-install.md tells
# operators to re-run scripts/04-install-cortex-plugin.sh after hermes update.

set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  echo "error: run as the ubuntu user, not root" >&2
  exit 1
fi

CORTEX_REPO="${CORTEX_REPO:-https://github.com/justnorthow/ollie-hermes-cortex.git}"
CORTEX_SRC="${CORTEX_SRC:-/tmp/ollie-hermes-cortex}"
HERMES_PLUGINS_DIR="${HOME}/.hermes/hermes-agent/plugins/memory"
TARGET_DIR="${HERMES_PLUGINS_DIR}/cortex"

export PATH="${HOME}/.local/bin:${PATH}"

echo "==> step 1: clone or refresh cortex repo at ${CORTEX_SRC}"
if [[ -d "${CORTEX_SRC}/.git" ]]; then
  git -C "${CORTEX_SRC}" fetch -q --depth 1 origin master
  git -C "${CORTEX_SRC}" reset -q --hard origin/master
else
  rm -rf "${CORTEX_SRC}"
  git clone -q --depth 1 "${CORTEX_REPO}" "${CORTEX_SRC}"
fi

PLUGIN_SRC="${CORTEX_SRC}/plugins/memory/cortex"
if [[ ! -f "${PLUGIN_SRC}/plugin.yaml" ]]; then
  echo "error: ${PLUGIN_SRC}/plugin.yaml not found — cortex repo layout changed?" >&2
  exit 1
fi

echo "==> step 2: install plugin to ${TARGET_DIR}"
mkdir -p "${HERMES_PLUGINS_DIR}"
rm -rf "${TARGET_DIR}"
cp -r "${PLUGIN_SRC}" "${TARGET_DIR}"
echo "    installed: $(ls "${TARGET_DIR}" | tr '\n' ' ')"

echo "==> step 3: activate cortex as the memory provider"
hermes config set memory.provider cortex >/dev/null
hermes memory status 2>&1 | head -5 || true

echo "==> step 4: restart all running Hermes gateways so they pick up the provider"
# Iterate every gateway unit on the box (default + per-profile).
for unit in $(systemctl --user list-units --no-legend --type=service 'hermes-gateway*' | awk '{print $1}'); do
  echo "    restarting ${unit}"
  systemctl --user restart "${unit}"
done

echo
echo "✓ Cortex memory plugin installed and activated."
echo
echo "After 'hermes update' (which wipes this plugin dir), re-run THIS script."
echo "Memory extraction happens per-session, so start a new chat to see it fire."
