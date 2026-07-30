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

# Apply the drop-ins FIRST. `changed_units` is computed per-run, so a restart
# skipped now is skipped forever: the next run finds the drop-ins already
# matching, restarts nothing, and the dashboards keep serving with the OLD
# session token while nginx injects the new one. Anything below that can abort
# must therefore come after this. (Sandbox 2026-07-30: making the render fatal
# without this reordering left all four listeners permanently at 401.)
if [[ "${ENSURE_TOKEN_NO_RESTART:-0}" != "1" && ${#changed_units[@]} -gt 0 ]]; then
  systemctl --user daemon-reload
  for u in "${changed_units[@]}"; do
    systemctl --user restart "${u}" || echo "warning: restart ${u} failed" >&2
  done
fi

# The Hermes UI proxy embeds this token in an nginx include file. Re-render it
# so a rotation can never leave the two out of step. A MISSING proxy script
# (older boxes) is fine and must never fail the token path — but a proxy script
# that is present and FAILS is exactly the rotation drift this design exists to
# prevent, so it is fatal. Downgrading it to a warning lets the caller believe
# the rotation landed while nginx still serves the PREVIOUS token.
# Runs on BOTH paths, including ENSURE_TOKEN_NO_RESTART=1 — which is how
# 05-install-orchestrator.sh always calls this script, so a block skipped in
# that mode would never run in the real install path either (task-2-report.md).
UI_PROXY="$(dirname "${BASH_SOURCE[0]}")/ensure-hermes-ui-proxy.sh"
if [[ -f "${UI_PROXY}" ]]; then
  if ! ORCH_ENV="${ORCH_ENV}" SYSTEMD_USER_DIR="${UNIT_DIR}" bash "${UI_PROXY}"; then
    echo "ensure-dashboard-token: FATAL — ui-proxy refresh failed (see the error above). The token in ${ORCH_ENV} and the dashboard drop-ins are applied, but nginx is NOT serving it, so every hermes-ui-proxy request will 401 until this is resolved. Fix the nginx config, then re-run this script." >&2
    exit 1
  fi
fi
