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

# The plugin files are vendored into this repo at templates/cortex-plugin/ so the
# install is self-contained (cortex repo is private; we avoid needing GH auth on
# the install target). The source of truth still lives in ollie-hermes-cortex/
# plugins/memory/cortex/ — bump the vendored copy when the upstream plugin
# changes (rare).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_SRC="${SCRIPT_DIR}/../templates/cortex-plugin"
HERMES_PLUGINS_DIR="${HOME}/.hermes/hermes-agent/plugins/memory"
TARGET_DIR="${HERMES_PLUGINS_DIR}/cortex"

export PATH="${HOME}/.local/bin:${PATH}"

if [[ ! -f "${PLUGIN_SRC}/plugin.yaml" ]]; then
  echo "error: vendored plugin not found at ${PLUGIN_SRC}" >&2
  echo "       expected plugin.yaml, __init__.py, provider.py, http_client.py" >&2
  exit 1
fi

echo "==> step 1: install plugin to ${TARGET_DIR} (from vendored copy)"
mkdir -p "${HERMES_PLUGINS_DIR}"
rm -rf "${TARGET_DIR}"
mkdir -p "${TARGET_DIR}"
# Copy contents (avoid copying any pycache)
find "${PLUGIN_SRC}" -maxdepth 1 -type f -name '*.py' -o -name '*.yaml' \
  | while read -r f; do cp "${f}" "${TARGET_DIR}/"; done
echo "    installed: $(ls "${TARGET_DIR}" | tr '\n' ' ')"

echo "==> step 2: activate cortex as the memory provider"
hermes config set memory.provider cortex >/dev/null
hermes memory status 2>&1 | head -5 || true

echo "==> step 3: restart all running Hermes gateways so they pick up the provider"
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
