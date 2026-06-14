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
# Best-effort + data-safe: ruamel round-trip preserves comments/formatting, and
# we write via a temp file + atomic os.replace so config.yaml can NEVER be left
# truncated. Python exit codes: 0 = changed, 10 = already present, other = error.
# We never fail the install on this — worst case the agent prompts once.
if [[ -x "${VENV_PY}" && -f "${CFG}" ]]; then
  set +e
  "${VENV_PY}" - "${CFG}" <<'PY'
import os, sys, tempfile
from ruamel.yaml import YAML
path = sys.argv[1]
yaml = YAML()  # round-trip: preserves comments + formatting
with open(path) as f:
    cfg = yaml.load(f)
al = cfg.get("command_allowlist")
if al is not None and not isinstance(al, list):
    sys.exit("command_allowlist is not a list; leaving config untouched")
if al is None:
    al = []
    cfg["command_allowlist"] = al
if "ollie-set-identity" in al:
    print("    already in command_allowlist")
    sys.exit(10)
al.append("ollie-set-identity")
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".", prefix=".hermes-cfg-")
try:
    with os.fdopen(fd, "w") as f:
        yaml.dump(cfg, f)
    os.replace(tmp, path)
except BaseException:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
print("    added ollie-set-identity to command_allowlist")
PY
  rc=$?
  set -e
  if [[ "${rc}" -eq 0 ]]; then
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
    for unit in $(systemctl --user list-units --no-legend --plain --type=service --state=active 'hermes-gateway*' 2>/dev/null | awk '{print $1}'); do
      systemctl --user restart "${unit}" 2>/dev/null && echo "    restarted ${unit}" || true
    done
  elif [[ "${rc}" -ne 10 ]]; then
    echo "    WARNING: could not edit command_allowlist (rc=${rc}); the agent may prompt once for approval." >&2
  fi
else
  echo "    WARNING: ${CFG} or venv python missing; skipped allowlisting (agent may prompt once)." >&2
fi

echo
echo "✓ identity-sync installed."
echo "  ollie-set-identity --name \"<name>\" --soul-file <path> [--id default]"
echo "  (display-name sync needs the orchestrator from 05-install-orchestrator.sh)"
