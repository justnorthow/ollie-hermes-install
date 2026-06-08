#!/usr/bin/env bash
# 03-install-profile.sh — create an additional Hermes profile (gateway + dashboard).
#
# Run as: the service user (ollie by default)
# Idempotent: safe to re-run.
#
# Usage:
#   bash 03-install-profile.sh <name> <gateway_port> <dashboard_port>
#
# Example:
#   bash 03-install-profile.sh paige 8643 9121
#   bash 03-install-profile.sh karl  8644 9122
#
# Port conventions:
#   gateway:   8642 (default) + N for each profile
#   dashboard: 9119 (default), 9121, 9122, ... (skip 9120 — reserved for Cortex)
#
# What it does:
#   1. Creates the profile via `hermes profile create <name>` (installs a per-profile shim binary)
#   2. Writes ~/.hermes/profiles/<name>/.env with API_SERVER_* + shared key
#   3. Sets gateway.port via `<name> config set`
#   4. Installs the per-profile gateway systemd service
#   5. Installs a hardened per-profile dashboard systemd service

set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  echo "error: run as the service user, not root" >&2
  exit 1
fi
if [[ $# -ne 3 ]]; then
  echo "usage: $0 <name> <gateway_port> <dashboard_port>" >&2
  exit 1
fi

NAME="$1"
GATEWAY_PORT="$2"
DASHBOARD_PORT="$3"

# Sanity-check inputs
if [[ ! "${NAME}" =~ ^[a-z][a-z0-9-]{1,30}$ ]]; then
  echo "error: profile name '${NAME}' must be lowercase alphanumeric + hyphens, 2-31 chars, start with a letter" >&2
  exit 1
fi
for p in "${GATEWAY_PORT}" "${DASHBOARD_PORT}"; do
  if [[ ! "${p}" =~ ^[0-9]+$ ]] || (( p < 1024 || p > 65535 )); then
    echo "error: port '${p}' must be 1024-65535" >&2
    exit 1
  fi
done

export PATH="${HOME}/.local/bin:${PATH}"
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
PROFILE_DIR="${HOME}/.hermes/profiles/${NAME}"
PROFILE_ENV="${PROFILE_DIR}/.env"
DEFAULT_ENV="${HOME}/.hermes/.env"

echo "==> step 1: pull shared API_SERVER_KEY from default profile (so the dashboard can auth against every profile with one key)"
if ! grep -q '^API_SERVER_KEY=' "${DEFAULT_ENV}"; then
  echo "error: default profile has no API_SERVER_KEY in ${DEFAULT_ENV}" >&2
  echo "       run 02-install-hermes.sh first" >&2
  exit 1
fi
SHARED_KEY="$(grep '^API_SERVER_KEY=' "${DEFAULT_ENV}" | cut -d= -f2-)"

echo "==> step 2: hermes profile create ${NAME} (creates ~/.local/bin/${NAME} shim if missing)"
if [[ ! -d "${PROFILE_DIR}" ]]; then
  hermes profile create "${NAME}"
else
  echo "    profile dir already exists at ${PROFILE_DIR} — skipping create"
fi

echo "==> step 3: write profile .env (idempotent)"
mkdir -p "${PROFILE_DIR}"
touch "${PROFILE_ENV}"
chmod 600 "${PROFILE_ENV}"
ensure_env() {
  local key="$1" value="$2"
  if ! grep -q "^${key}=" "${PROFILE_ENV}"; then
    echo "${key}=${value}" >> "${PROFILE_ENV}"
  fi
}
ensure_env API_SERVER_ENABLED true
ensure_env API_SERVER_HOST 0.0.0.0
ensure_env API_SERVER_PORT "${GATEWAY_PORT}"
ensure_env API_SERVER_KEY "${SHARED_KEY}"
ensure_env API_SERVER_CORS_ORIGINS '*'

echo "==> step 4: <name> config set gateway.port = ${GATEWAY_PORT}"
"${NAME}" config set gateway.port "${GATEWAY_PORT}" >/dev/null

echo "==> step 5: install per-profile gateway service"
printf 'y\ny\ny\ny\ny\n' | "${NAME}" gateway install 2>&1 | tail -3 || true

echo "==> step 6: install per-profile dashboard service (hardened)"
DASHBOARD_UNIT="${SYSTEMD_USER_DIR}/hermes-dashboard-${NAME}.service"
mkdir -p "${SYSTEMD_USER_DIR}"
cat > "${DASHBOARD_UNIT}" <<EOF
[Unit]
Description=Hermes Agent Dashboard (${NAME} profile)
After=network.target

[Service]
Type=simple
Environment=PATH=%h/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=%h/.local/bin/hermes -p ${NAME} dashboard --host 0.0.0.0 --port ${DASHBOARD_PORT} --insecure --no-open
Restart=always
RestartSec=5
StartLimitBurst=10
StartLimitIntervalSec=60

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now "hermes-dashboard-${NAME}"

echo
echo "==> verification (waiting for ports — first start can be slow)"
set +e
echo "    hermes-gateway-${NAME}:   $(systemctl --user is-active hermes-gateway-${NAME})"
echo "    hermes-dashboard-${NAME}: $(systemctl --user is-active hermes-dashboard-${NAME})"
for i in $(seq 1 15); do
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 3 "http://localhost:${DASHBOARD_PORT}/" || true)
  if [[ "${code}" == "200" ]]; then
    echo "    dashboard http :${DASHBOARD_PORT} → 200 ✓"
    break
  fi
  [[ "${i}" == "15" ]] && echo "    dashboard http :${DASHBOARD_PORT} → ${code:-none} (not 200 after 30s — check logs)"
  sleep 2
done
code=$(curl -s -o /dev/null -w '%{http_code}' -m 5 "http://localhost:${GATEWAY_PORT}/v1/runs" || true)
case "${code}" in
  ''|000) echo "    gateway   http :${GATEWAY_PORT} → no response (check 'systemctl --user status hermes-gateway-${NAME}')" ;;
  *) echo "    gateway   http :${GATEWAY_PORT} → ${code} ✓ (any HTTP response = listening)" ;;
esac
set -e

echo
echo "✓ Profile '${NAME}' installed on gateway :${GATEWAY_PORT}, dashboard :${DASHBOARD_PORT}"
