#!/usr/bin/env bash
# detect-agents.sh — enumerate installed agents and their ports as JSON.
# Source this file, then call detect_agents. Output (stdout, one line):
#   [{"id":"default","gw":<port>,"dash":9119},{"id":"<profile>","gw":<port>,"dash":<port>},...]
# Skips profiles with missing port info (warning on stderr) — same rule as 06.
set -uo pipefail

detect_agents() {
  local hermes_env="${HERMES_ENV_FILE:-$HOME/.hermes/.env}"
  local profiles_dir="${PROFILES_DIR:-$HOME/.hermes/profiles}"
  local unit_dir="${SYSTEMD_USER_DIR:-$HOME/.config/systemd/user}"
  local default_dash=9119
  local default_port prof_env prof_name gw_port unit dash_port
  local entries=()

  default_port="$(grep '^API_SERVER_PORT=' "${hermes_env}" | cut -d= -f2-)"
  entries+=("$(printf '{"id":"default","gw":%s,"dash":%s}' "${default_port}" "${default_dash}")")

  shopt -s nullglob
  for prof_env in "${profiles_dir}"/*/.env; do
    [[ -f "${prof_env}" ]] || continue
    prof_name="$(basename "$(dirname "${prof_env}")")"
    gw_port="$(grep '^API_SERVER_PORT=' "${prof_env}" | cut -d= -f2- || true)"
    unit="${unit_dir}/hermes-dashboard-${prof_name}.service"
    if [[ -f "${unit}" ]]; then
      dash_port="$(grep -oE -- '--port [0-9]+' "${unit}" | awk '{print $2}' | head -1)"
    else
      dash_port=""
    fi
    if [[ -z "${gw_port}" || -z "${dash_port}" ]]; then
      echo "    skipping profile '${prof_name}' (missing port info)" >&2
      continue
    fi
    entries+=("$(printf '{"id":"%s","gw":%s,"dash":%s}' "${prof_name}" "${gw_port}" "${dash_port}")")
  done
  (IFS=,; printf '[%s]' "${entries[*]}")
}
