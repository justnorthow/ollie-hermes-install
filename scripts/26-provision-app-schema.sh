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

core_psql() {  # SQL on stdin
  docker compose -f "${CORE_DIR}/docker-compose.yml" --env-file "${CORE_DIR}/.env" \
    exec -T db psql -v ON_ERROR_STOP=1 -U postgres -d postgres
}

core_psql <<SQL
-- Owner role. CREATE ROLE has no IF NOT EXISTS, so guard it.
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${OWNER_ROLE}') THEN
    CREATE ROLE ${OWNER_ROLE} NOLOGIN;
  END IF;
END
\$\$;

CREATE SCHEMA IF NOT EXISTS ${APP_NAME} AUTHORIZATION ${OWNER_ROLE};
ALTER SCHEMA ${APP_NAME} OWNER TO ${OWNER_ROLE};

-- PostgREST's roles must reach the schema; the owner is switched into by
-- authenticator when the app presents its <name>_owner JWT.
GRANT USAGE ON SCHEMA ${APP_NAME} TO anon, authenticated, service_role;
GRANT ${OWNER_ROLE} TO authenticator;

-- Narrow, unavoidable cross-schema need: app rows FK to identity.
-- USAGE + REFERENCES only. No other privilege grants.
GRANT USAGE ON SCHEMA auth TO ${OWNER_ROLE};
GRANT REFERENCES ON TABLE auth.users TO ${OWNER_ROLE};

-- Tables the owner creates later must be reachable by the PostgREST roles.
ALTER DEFAULT PRIVILEGES FOR ROLE ${OWNER_ROLE} IN SCHEMA ${APP_NAME}
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE ${OWNER_ROLE} IN SCHEMA ${APP_NAME}
  GRANT USAGE, SELECT ON SEQUENCES TO anon, authenticated, service_role;

-- Defence in depth: strip any explicit grant this role may have received on public.
-- NOTE: This does NOT remove the ambient USAGE every role inherits from the PUBLIC
-- pseudo-role (verified on PG15.8). That ambient USAGE provides name resolution only,
-- not table access. Real isolation is enforced by never granting this role table
-- privileges in public.
REVOKE ALL ON SCHEMA public FROM ${OWNER_ROLE};
SQL

echo "    schema + owner role provisioned"
