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
  local file="$1" k="$2" v="$3" v_esc
  v_esc="$(printf '%s' "${v}" | sed -e 's/[\\&|]/\\&/g')"
  if grep -q "^${k}=" "${file}" 2>/dev/null; then
    sed -i "s|^${k}=.*|${k}=${v_esc}|" "${file}"
  else
    echo "${k}=${v}" >> "${file}"
  fi
}

supabase_write_orch_env() {
  local url="${1%/}" key="$2"
  local env_file="${ORCH_ENV:-$HOME/.config/ollie-orchestrator/.env}"
  mkdir -p "$(dirname "${env_file}")"
  touch "${env_file}"
  chmod 600 "${env_file}"
  _supabase_set_env_key "${env_file}" SUPABASE_URL "${url}"
  _supabase_set_env_key "${env_file}" SUPABASE_SERVICE_ROLE_KEY "${key}"
}

supabase_schema_probe_url() {
  printf '%s/rest/v1/user_roles?select=user_id&limit=1' "${1%/}"
}

# Render kong.yml from template, substituting the generated API keys.
supabase_render_kong() { # TEMPLATE OUT ANON_KEY SERVICE_KEY
  sed -e "s|__ANON_KEY__|$3|" -e "s|__SERVICE_ROLE_KEY__|$4|" "$1" > "$2"
  # kong.yml contains the anon/service keys, but the container's non-root
  # kong user reads this file via the "other" bit on the bind mount — 600
  # (owner-only) makes kong fail with "Permission denied" at startup. 644
  # is safe here because host-side protection comes from the stack dir
  # itself being 0700 (set by the deploy script), not this file's mode.
  chmod 644 "$2"
}

# Write the dashboard-facing Supabase vars into ~/hermes-stack/.env.
# SUPABASE_COOKIE_DOMAIN is deliberately untouched (Fleet/operator-managed).
supabase_write_stack_dashboard_env() { # STACK_ENV URL ANON_KEY
  local f="$1"
  [ -f "$f" ] || return 1
  _supabase_set_env_key "$f" SUPABASE_URL "${2%/}"
  _supabase_set_env_key "$f" SUPABASE_ANON_KEY "$3"
}
