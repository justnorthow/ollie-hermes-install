#!/usr/bin/env bash
# app-server-env.sh — idempotent .env renderer for generic app servers
# (~/apps/<name>). Managed keys: APP_NAME APP_PORT CONTAINER_PORT HEALTH_PATH
# APP_IMAGE. Every exported APP_ENV_<KEY> renders as a bare <KEY>= line and is
# passed to the container via env_file. Carry-forward: empty export -> keep OLD
# value; bare keys in OLD survive unless an APP_ENV_<KEY> export overrides.

app_server_env_val() { # FILE KEY
  [[ -f "$1" ]] || { echo ""; return 0; }
  local line
  line="$(grep -E "^$2=" "$1" | tail -n1 || true)"
  echo "${line#*=}"
}

render_app_server_env() { # OUT OLD_FILE(optional, "" for none)
  local out="$1" old="${2:-}"
  local managed=(APP_NAME APP_PORT CONTAINER_PORT HEALTH_PATH APP_IMAGE)
  local tmp; tmp="$(mktemp)"
  local k v
  for k in "${managed[@]}"; do
    v="${!k:-}"
    [[ -z "$v" && -n "$old" ]] && v="$(app_server_env_val "$old" "$k")"
    echo "${k}=${v}" >> "$tmp"
  done
  # operator app-env keys: start from OLD's bare keys (minus managed + PORT),
  # then apply APP_ENV_* exports on top
  declare -A appenv=()
  if [[ -n "$old" && -f "$old" ]]; then
    while IFS='=' read -r k v; do
      [[ "$k" =~ ^[A-Z][A-Z0-9_]*$ ]] || continue
      case "$k" in APP_NAME|APP_PORT|CONTAINER_PORT|HEALTH_PATH|APP_IMAGE|PORT) continue ;; esac
      appenv["$k"]="$v"
    done < "$old"
  fi
  local var
  for var in $(compgen -A variable APP_ENV_ || true); do
    appenv["${var#APP_ENV_}"]="${!var}"
  done
  if [[ ${#appenv[@]} -gt 0 ]]; then
    for k in $(printf '%s\n' "${!appenv[@]}" | sort); do
      echo "${k}=${appenv[$k]}" >> "$tmp"
    done
  fi
  # container PORT follows CONTAINER_PORT
  echo "PORT=$(grep -E '^CONTAINER_PORT=' "$tmp" | tail -n1 | cut -d= -f2)" >> "$tmp"
  install -m 600 "$tmp" "$out"
  rm -f "$tmp"
}
