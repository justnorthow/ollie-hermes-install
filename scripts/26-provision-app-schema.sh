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

# The stack's compose file must actually CONSUME PGRST_DB_SCHEMAS from .env.
# `rest` has no env_file:, and `docker compose --env-file` only expands ${VAR}
# references — it does not inject arbitrary .env keys into containers. So if
# this compose file still carries the old hardcoded literal
# `PGRST_DB_SCHEMAS=public`, everything below "succeeds" while PostgREST keeps
# serving only `public` and the app's schema 404s. Fail closed instead, before
# touching the database or the .env. 11-install-supabase.sh re-copies the
# template on every deploy, so redeploying is what fixes it.
if ! grep -qF 'PGRST_DB_SCHEMAS=${PGRST_DB_SCHEMAS' "${CORE_DIR}/docker-compose.yml"; then
  echo "error: ${CORE_DIR}/docker-compose.yml does not reference \${PGRST_DB_SCHEMAS} —" \
    "this stack's compose file predates the PGRST_DB_SCHEMAS parameterisation, so the" \
    "rest container hardcodes its schema list and writing PGRST_DB_SCHEMAS to .env would" \
    "be a silent no-op (the new schema would 404). Redeploy the stack first so the" \
    "current template is staged: 11-install-supabase.sh --deploy" >&2
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

# Register the schema with PostgREST. Absent key => start from "public", which
# is the shipped default (verified on the sandbox: PGRST_DB_SCHEMAS=public).
CUR="$(grep -E '^PGRST_DB_SCHEMAS=' "${CORE_DIR}/.env" | tail -1 | cut -d= -f2- || true)"
[[ -z "${CUR}" ]] && CUR="public"

if [[ ",${CUR}," == *",${APP_NAME},"* ]]; then
  echo "    PGRST_DB_SCHEMAS already lists ${APP_NAME}"
else
  NEW="${CUR},${APP_NAME}"
  if grep -qE '^PGRST_DB_SCHEMAS=' "${CORE_DIR}/.env"; then
    # Escape sed special chars in the replacement value (backslash, ampersand, delimiter)
    NEW_esc="$(printf '%s' "${NEW}" | sed -e 's/[\\&|]/\\&/g')"
    sed -i "s|^PGRST_DB_SCHEMAS=.*|PGRST_DB_SCHEMAS=${NEW_esc}|" "${CORE_DIR}/.env"
  else
    echo "PGRST_DB_SCHEMAS=${NEW}" >> "${CORE_DIR}/.env"
  fi
  echo "    PGRST_DB_SCHEMAS -> ${NEW}"
fi

docker compose -f "${CORE_DIR}/docker-compose.yml" --env-file "${CORE_DIR}/.env" \
  up -d --force-recreate rest
echo "    rest recreated"

# Mint the app's runtime key: a JWT claiming role=<name>_owner, signed with the
# core JWT secret. PostgREST switches into that role, so the app has full rights
# inside its own schema and none outside it. This REPLACES service_role for the
# app — core's service_role key must never reach an app container.
JWT_SECRET="$(grep -E '^JWT_SECRET=' "${CORE_DIR}/.env" | tail -1 | cut -d= -f2- || true)"
if [[ -z "${JWT_SECRET}" ]]; then
  echo "error: JWT_SECRET not found in ${CORE_DIR}/.env" >&2; exit 1
fi

mkdir -p "${CORE_DIR}/app-keys"
chmod 700 "${CORE_DIR}/app-keys"
KEYFILE="${CORE_DIR}/app-keys/${APP_NAME}.jwt"
printf '%s' "${JWT_SECRET}" \
  | python3 "${SCRIPT_DIR}/lib/gen-supabase-keys.py" --mint-role "${OWNER_ROLE}" \
  > "${KEYFILE}"
chmod 600 "${KEYFILE}"

echo "    owner JWT -> ${KEYFILE}"
echo
echo "✓ schema '${APP_NAME}' ready. Give the app:"
echo "    SUPABASE_URL       = core stack's public URL"
echo "    SUPABASE_ANON_KEY  = ANON_KEY from ${CORE_DIR}/.env"
echo "    SUPABASE_APP_KEY   = contents of ${KEYFILE}"
echo "    schema             = ${APP_NAME}   (supabase-js: db: { schema: '${APP_NAME}' })"
