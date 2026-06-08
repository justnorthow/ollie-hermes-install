#!/usr/bin/env bash
# 09-install-identity-sync.sh — install the ollie-set-identity helper and let the
# agent run it without an approval prompt.
#
# Run as: the service user (ollie by default; NOT root). Idempotent.
# The display-name half needs the orchestrator (05); the SOUL-write half works
# without it. Re-run after `hermes update` (which can reset config/PATH).

set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  echo "error: run as the service user, not root" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${SCRIPT_DIR}/../templates/bin/ollie-set-identity"
DEST="${HOME}/.local/bin/ollie-set-identity"
CFG="${HOME}/.hermes/config.yaml"
VENV_PY="${HOME}/.hermes/hermes-agent/venv/bin/python"

[[ -f "${SRC}" ]] || { echo "error: ${SRC} not found" >&2; exit 1; }

echo "==> installing ollie-set-identity → ${DEST} (+ /usr/local/bin symlink)"
mkdir -p "${HOME}/.local/bin"
cp "${SRC}" "${DEST}"
chmod 755 "${DEST}"
sudo ln -sfn "${DEST}" /usr/local/bin/ollie-set-identity
echo "    linked /usr/local/bin/ollie-set-identity"

echo "==> allowlisting ollie-set-identity (so the agent runs it without an approval prompt)"
# Best-effort: a round-trip YAML edit (ruamel preserves comments/formatting).
# If anything goes wrong, the command still works — the agent just gets a
# one-time approval prompt. So we never fail the install on this.
if [[ -x "${VENV_PY}" && -f "${CFG}" ]]; then
  if "${VENV_PY}" - "${CFG}" <<'PY'
import sys
from ruamel.yaml import YAML
path = sys.argv[1]
yaml = YAML()  # round-trip: preserves comments + formatting
with open(path) as f:
    cfg = yaml.load(f)
al = cfg.get("command_allowlist")
if not isinstance(al, list):
    al = []
    cfg["command_allowlist"] = al
if "ollie-set-identity" not in al:
    al.append("ollie-set-identity")
    with open(path, "w") as f:
        yaml.dump(cfg, f)
    print("    added ollie-set-identity to command_allowlist")
else:
    print("    already in command_allowlist")
PY
  then
    # restart running gateways so they pick up the config change
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
    for unit in $(systemctl --user list-units --no-legend --plain 'hermes-gateway*' 2>/dev/null | awk '{print $1}'); do
      systemctl --user restart "${unit}" 2>/dev/null && echo "    restarted ${unit}"
    done
  else
    echo "    WARNING: could not edit command_allowlist; the agent may prompt once for approval." >&2
  fi
else
  echo "    WARNING: ${CFG} or venv python missing; skipped allowlisting (agent may prompt once)." >&2
fi

echo
echo "✓ identity-sync installed."
echo "  ollie-set-identity --name \"<name>\" --soul-file <path> [--id default]"
echo "  (display-name sync needs the orchestrator from 05-install-orchestrator.sh)"
