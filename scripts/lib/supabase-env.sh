#!/usr/bin/env bash
# supabase-env.sh — testable core for 11-install-supabase.sh. Source, don't exec.
set -uo pipefail

supabase_validate_inputs() {
  local url="$1" key="$2"
  if [[ -z "${url}" || -z "${key}" ]]; then
    echo "error: SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are both required" >&2; return 1
  fi
  if [[ ! "${url}" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?/?$ ]]; then
    echo "error: SUPABASE_URL must be an https origin with no path — hosted (https://<ref>.supabase.co) or self-hosted (got: ${url})" >&2; return 1
  fi
  if [[ "${key}" == *$'\n'* || "${key}" == *" "* ]]; then
    echo "error: SUPABASE_SERVICE_ROLE_KEY must be a single-line value" >&2; return 1
  fi
  return 0
}

_supabase_set_env_key() {
  local file="$1" k="$2" v="$3"
  if grep -q "^${k}=" "${file}" 2>/dev/null; then
    sed -i "s|^${k}=.*|${k}=${v}|" "${file}"
  else
    echo "${k}=${v}" >> "${file}"
  fi
}

supabase_write_orch_env() {
  local url="${1%/}" key="$2"
  local env_file="${ORCH_ENV:-$HOME/.config/ollie-orchestrator/.env}"
  mkdir -p "$(dirname "${env_file}")"
  touch "${env_file}"
  _supabase_set_env_key "${env_file}" SUPABASE_URL "${url}"
  _supabase_set_env_key "${env_file}" SUPABASE_SERVICE_ROLE_KEY "${key}"
  chmod 600 "${env_file}"
}

supabase_schema_probe_url() {
  printf '%s/rest/v1/user_roles?select=user_id&limit=1' "${1%/}"
}
