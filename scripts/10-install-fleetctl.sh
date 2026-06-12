#!/usr/bin/env bash
# 10-install-fleetctl.sh — install ollie-fleetctl (the verb CLI that Ollie Fleet
# invokes over SSH) and the fleet-heartbeat systemd user timer.
#
# Run as: the service user (ollie by default; NOT root). Idempotent.
# The heartbeat no-ops until ~/.config/ollie-fleet/.env exists (Fleet writes it
# at enrollment with FLEET_URL + FLEET_TOKEN), so this script is safe to run on
# a box that has never been enrolled. Re-run after `hermes update` is NOT
# required (fleetctl lives outside ~/.hermes/hermes-agent), but re-running is
# always safe and picks up new fleetctl versions after `git pull`.

set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  echo "error: run as the service user, not root" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_BIN="${SCRIPT_DIR}/../templates/bin/ollie-fleetctl"
SRC_SVC="${SCRIPT_DIR}/../templates/systemd/ollie-fleet-heartbeat.service"
DEST_BIN="${HOME}/.local/bin/ollie-fleetctl"

for f in "${SRC_BIN}" "${SRC_SVC}"; do
  [[ -f "${f}" ]] || { echo "error: ${f} not found" >&2; exit 1; }
done

echo "==> installing ollie-fleetctl → ${DEST_BIN} (+ /usr/local/bin symlink)"
mkdir -p "${HOME}/.local/bin"
cp "${SRC_BIN}" "${DEST_BIN}"
chmod 755 "${DEST_BIN}"
sudo ln -sfn "${DEST_BIN}" /usr/local/bin/ollie-fleetctl
echo "    linked /usr/local/bin/ollie-fleetctl"

echo "==> smoke test"
ollie-fleetctl version

echo "==> installing ollie-fleet-heartbeat system service"
sudo cp "${SRC_SVC}" /etc/systemd/system/ollie-fleet-heartbeat.service
# Retire the old per-user timer if a previous install left one behind.
systemctl --user disable --now fleet-heartbeat.timer 2>/dev/null || true
rm -f "${HOME}/.config/systemd/user/fleet-heartbeat.service" "${HOME}/.config/systemd/user/fleet-heartbeat.timer"
sudo systemctl daemon-reload
sudo systemctl enable --now ollie-fleet-heartbeat.service
echo "    service active: $(systemctl is-active ollie-fleet-heartbeat.service)"

echo
echo "✓ fleetctl installed."
echo "  verbs: health | agents <action> | restart <target> | logs <service> | update | backup | heartbeat | version"
echo "  heartbeat-daemon is a no-op until enrollment writes ${HOME}/.config/ollie-fleet/.env"
echo "  (FLEET_URL=... and FLEET_TOKEN=..., mode 600 — the Fleet dashboard does this for you)"
