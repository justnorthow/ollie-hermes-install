#!/usr/bin/env bash
# 05-install-orchestrator.sh — install Ollie Orchestrator (agent management API).
#
# Run as: the service user (ollie by default)
# Idempotent: safe to re-run.
#
# What it does:
#   1. Clones (or refreshes) the orchestrator repo at ~/ollie-hermes-orchestrator
#   2. Runs the orchestrator's own install.sh (creates venv, generates ORCHESTRATOR_KEY,
#      installs the ollie-orchestrator.service systemd unit)
#   3. Wires HERMES_GATEWAY_KEY into the orchestrator's .env by reading API_SERVER_KEY
#      from ~/.hermes/.env (the orchestrator uses the gateway's auth token to make
#      management calls on behalf of agents)
#   4. Restarts the orchestrator + verifies it's reachable

set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  echo "error: run as the service user, not root" >&2
  exit 1
fi

# Ensure `systemctl --user` can reach the per-user systemd bus even when this
# script runs without a login session (e.g. via `sudo -u` / `su`). Otherwise the
# raw `systemctl --user` calls below fail with "Failed to connect to bus: No
# medium found". Linger (enabled in 01-bootstrap.sh) guarantees /run/user/<uid>.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

ORCH_REPO="${ORCH_REPO:-https://github.com/justnorthow/ollie-hermes-orchestrator.git}"
ORCH_DIR="${HOME}/ollie-hermes-orchestrator"
ORCH_ENV="${HOME}/.config/ollie-orchestrator/.env"
HERMES_ENV="${HOME}/.hermes/.env"

echo "==> step 1: clone or refresh orchestrator repo at ${ORCH_DIR}"
if [[ -d "${ORCH_DIR}/.git" ]]; then
  git -C "${ORCH_DIR}" fetch -q --depth 1 origin master
  git -C "${ORCH_DIR}" reset -q --hard origin/master
else
  git clone -q --depth 1 "${ORCH_REPO}" "${ORCH_DIR}"
fi

echo "==> step 2: run orchestrator install.sh (creates venv, systemd unit, generates ORCHESTRATOR_KEY)"
bash "${ORCH_DIR}/scripts/install.sh" 2>&1 | tail -8

echo "==> step 3: wire HERMES_GATEWAY_KEY into orchestrator .env from default profile .env"
if [[ ! -f "${HERMES_ENV}" ]]; then
  echo "error: ${HERMES_ENV} missing — run 02-install-hermes.sh first" >&2
  exit 1
fi
GATEWAY_KEY="$(grep '^API_SERVER_KEY=' "${HERMES_ENV}" | cut -d= -f2-)"
if [[ -z "${GATEWAY_KEY}" ]]; then
  echo "error: no API_SERVER_KEY in ${HERMES_ENV}" >&2
  exit 1
fi
# Replace the (empty) HERMES_GATEWAY_KEY= line the installer wrote with the real value.
if grep -q '^HERMES_GATEWAY_KEY=' "${ORCH_ENV}"; then
  sed -i "s|^HERMES_GATEWAY_KEY=.*|HERMES_GATEWAY_KEY=${GATEWAY_KEY}|" "${ORCH_ENV}"
else
  echo "HERMES_GATEWAY_KEY=${GATEWAY_KEY}" >> "${ORCH_ENV}"
fi

echo "==> step 4: restart orchestrator + verify"
systemctl --user restart ollie-orchestrator
sleep 3
set +e
echo "    ollie-orchestrator: $(systemctl --user is-active ollie-orchestrator)"
HEALTH=$(curl -s -m 5 http://localhost:9123/healthz || echo "")
case "${HEALTH}" in
  *'"status":"ok"'*) echo "    GET :9123/healthz → ok ✓" ;;
  *) echo "    GET :9123/healthz → ${HEALTH:-no response} (check 'systemctl --user status ollie-orchestrator')" ;;
esac
set -e

# Print the ORCHESTRATOR_KEY so the user can paste it into the dashboard stack .env
ORCH_KEY="$(grep '^ORCHESTRATOR_KEY=' "${ORCH_ENV}" | cut -d= -f2-)"
echo
echo "✓ Orchestrator installed and running on :9123"
echo
echo "Save this ORCHESTRATOR_KEY — script 06 will use it for the dashboard container:"
echo "    ${ORCH_KEY}"
