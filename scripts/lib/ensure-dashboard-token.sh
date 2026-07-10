#!/usr/bin/env bash
# ensure-dashboard-token.sh — stable dashboard session token, everywhere it must match.
# Reuses HERMES_DASHBOARD_TOKEN from the orchestrator .env if present, else generates
# one. Writes it to the orchestrator .env AND as a session-token.conf drop-in for every
# hermes-dashboard*.service unit. Without the matching drop-in the dashboard randomizes
# its session token each restart and every management call 401s (S75 incident).
# Env: ORCH_ENV, SYSTEMD_USER_DIR, ENSURE_TOKEN_NO_RESTART=1 (skip systemctl).
set -uo pipefail

ORCH_ENV="${ORCH_ENV:-$HOME/.config/ollie-orchestrator/.env}"
UNIT_DIR="${SYSTEMD_USER_DIR:-$HOME/.config/systemd/user}"

mkdir -p "$(dirname "${ORCH_ENV}")"
touch "${ORCH_ENV}"

TOKEN="$(grep '^HERMES_DASHBOARD_TOKEN=' "${ORCH_ENV}" | tail -1 | cut -d= -f2- || true)"
if [[ -z "${TOKEN}" ]]; then
  TOKEN="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
  echo "HERMES_DASHBOARD_TOKEN=${TOKEN}" >> "${ORCH_ENV}"
  echo "dashboard-token: generated"
else
  echo "dashboard-token: reused"
fi

changed_units=()
shopt -s nullglob
for unit in "${UNIT_DIR}"/hermes-dashboard*.service; do
  unit_name="$(basename "${unit}")"
  dropdir="${UNIT_DIR}/${unit_name}.d"
  conf="${dropdir}/session-token.conf"
  want="$(printf '[Service]\nEnvironment=HERMES_DASHBOARD_SESSION_TOKEN=%s' "${TOKEN}")"
  if [[ -f "${conf}" && "$(cat "${conf}")" == "${want}" ]]; then
    continue
  fi
  mkdir -p "${dropdir}"
  printf '%s' "${want}" > "${conf}"
  chmod 600 "${conf}"
  changed_units+=("${unit_name}")
  echo "drop-in written: ${unit_name}"
done

if [[ "${ENSURE_TOKEN_NO_RESTART:-0}" == "1" ]]; then
  exit 0
fi
if [[ ${#changed_units[@]} -gt 0 ]]; then
  systemctl --user daemon-reload
  for u in "${changed_units[@]}"; do
    systemctl --user restart "${u}" || echo "warning: restart ${u} failed" >&2
  done
fi
