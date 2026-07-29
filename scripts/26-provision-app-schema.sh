#!/usr/bin/env bash
# 26-provision-app-schema.sh — prepare the CORE Supabase stack to host one app
# as a Postgres schema: schema, scoped owner role, grants, PostgREST
# registration, and the app's <name>_owner JWT.
#
# Stage 1 of the single-Supabase app-schema design. Touches nothing an app or
# user currently uses — safe to run before anything migrates.
#
# Run as: the service user. Idempotent.
# Input (stdin, KEY=VALUE lines):
#   APP_NAME=<^[a-z][a-z0-9_]*$, required>   Postgres identifier; hyphens invalid
#   CORE_STACK_DIR=<path>                    default $HOME/supabase-stack
set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  echo "error: run as the service user, not root" >&2; exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

APP_NAME="" ; CORE_STACK_DIR=""
while IFS='=' read -r k v || [[ -n "${k:-}" ]]; do
  case "${k}" in
    APP_NAME) APP_NAME="${v}" ;;
    CORE_STACK_DIR) CORE_STACK_DIR="${v}" ;;
  esac
done

if [[ ! "${APP_NAME}" =~ ^[a-z][a-z0-9_]*$ ]]; then
  echo "error: APP_NAME required, ^[a-z][a-z0-9_]*\$ — Postgres identifier, hyphens are not valid (got: '${APP_NAME}')" >&2
  exit 1
fi

CORE_DIR="${CORE_STACK_DIR:-${HOME}/supabase-stack}"
if [[ ! -f "${CORE_DIR}/.env" || ! -f "${CORE_DIR}/docker-compose.yml" ]]; then
  echo "error: core stack not found at ${CORE_DIR} (expected .env and docker-compose.yml)" >&2
  exit 1
fi

OWNER_ROLE="${APP_NAME}_owner"

echo "==> provisioning schema '${APP_NAME}' (owner role '${OWNER_ROLE}') in ${CORE_DIR}"
