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

# Cross-schema grants must be issued by the OWNER of schema auth, which is
# supabase_admin (the only superuser). `postgres` holds USAGE on auth WITHOUT
# GRANT OPTION, and PostgreSQL answers a grant you may not make with
#   WARNING: no privileges were granted for "auth"
# and a SUCCESS exit — ON_ERROR_STOP=1 does not trap warnings. Issuing these as
# postgres therefore looked fine and silently did nothing, leaving any app that
# foreign-keys to auth.users to fail later with `permission denied for schema
# auth`. Connects over TCP because the socket path rejects password auth.
admin_psql() {  # SQL on stdin
  docker compose -f "${CORE_DIR}/docker-compose.yml" --env-file "${CORE_DIR}/.env" \
    exec -T -e PGPASSWORD="${CORE_DB_PASSWORD}" db \
    psql -v ON_ERROR_STOP=1 -U supabase_admin -h 127.0.0.1 -d postgres
}

CORE_DB_PASSWORD="$(grep -E '^POSTGRES_PASSWORD=' "${CORE_DIR}/.env" | tail -1 | cut -d= -f2-)"
if [[ -z "${CORE_DB_PASSWORD}" ]]; then
  echo "error: POSTGRES_PASSWORD not found in ${CORE_DIR}/.env — needed to grant" \
    "cross-schema access as supabase_admin" >&2
  exit 1
fi

core_psql <<SQL
-- Owner role. CREATE ROLE has no IF NOT EXISTS, so guard it.
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${OWNER_ROLE}') THEN
    CREATE ROLE ${OWNER_ROLE} NOLOGIN;
  END IF;
END
\$\$;

-- Make the connecting role a MEMBER of the owner role before anything is
-- created AUTHORIZATION-ed to it. Supabase's postgres is NOT a superuser
-- (rolsuper=f), and on PG15 creating a role grants the creator no membership
-- in it, so the CREATE SCHEMA below fails outright with
--   ERROR: must be member of role "<name>_owner"
-- Observed on a real box; the test harness never executes SQL, so no amount of
-- SQL-text assertion could have caught it.
--
-- Grantee is the LITERAL role, never CURRENT_USER: on PostgreSQL 15.8
-- `GRANT <role> TO CURRENT_USER` SEGFAULTS the backend (signal 11), which
-- terminates every other connection and forces database-wide recovery. Seen on
-- the dev box. core_psql always connects -U postgres, so the name is known.
GRANT ${OWNER_ROLE} TO postgres;

CREATE SCHEMA IF NOT EXISTS ${APP_NAME} AUTHORIZATION ${OWNER_ROLE};
ALTER SCHEMA ${APP_NAME} OWNER TO ${OWNER_ROLE};

-- PostgREST's roles must reach the schema; the owner is switched into by
-- authenticator when the app presents its <name>_owner JWT.
GRANT USAGE ON SCHEMA ${APP_NAME} TO anon, authenticated, service_role;
GRANT ${OWNER_ROLE} TO authenticator;


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

# Narrow, unavoidable cross-schema need: app rows FK to identity.
# USAGE + REFERENCES only, no other privilege — and issued as supabase_admin,
# which owns schema auth. See admin_psql above for why postgres cannot do this.
admin_psql <<SQL
GRANT USAGE ON SCHEMA auth TO ${OWNER_ROLE};
GRANT REFERENCES ON TABLE auth.users TO ${OWNER_ROLE};
SQL

# Supabase installs uuid-ossp, pgcrypto and friends in `extensions`. A migration
# calling uuid_generate_v4() UNQUALIFIED cannot be relocated into the app schema
# — it is not `public.`-qualified, it resolves through search_path — so the app
# schema alone is not enough. Putting `extensions` on the search_path is also
# not enough: without USAGE the role cannot see anything in it. Both are needed,
# and this is the half that lives here. USAGE only — the role may CALL extension
# functions, never create objects there.
# (An app using only gen_random_uuid() never notices: that one also exists in
# pg_catalog, which is always implicitly on the path. HIA's first migration is
# what surfaced it.)
admin_psql <<SQL
GRANT USAGE ON SCHEMA extensions TO ${OWNER_ROLE};
SQL

# PROVE it landed rather than trusting the exit code: the failure mode this
# replaces was a WARNING with a success exit, so a silent no-op would otherwise
# look identical to success and only surface when an app migration tried to
# reference auth.users.
core_psql <<SQL
DO \$\$
BEGIN
  IF NOT has_schema_privilege('${OWNER_ROLE}', 'auth', 'USAGE')
     OR NOT has_table_privilege('${OWNER_ROLE}', 'auth.users', 'REFERENCES') THEN
    RAISE EXCEPTION 'cross-schema grants did not land for ${OWNER_ROLE}: an app FK to auth.users would fail with "permission denied for schema auth"';
  END IF;
  IF NOT has_schema_privilege('${OWNER_ROLE}', 'extensions', 'USAGE') THEN
    RAISE EXCEPTION 'extensions grant did not land for ${OWNER_ROLE}: a migration calling uuid_generate_v4() would fail with "function does not exist"';
  END IF;
END
\$\$;
SQL

echo "    schema + owner role provisioned (auth grants verified)"

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

# umask 077 closes two windows the trailing chmods cannot: `mkdir -p` would
# create app-keys/ at the default umask, and `>` would create the key file 0644
# — both readable by every local user for the instant before chmod runs. The
# chmods stay for a directory or file that already exists from an earlier run.
umask 077
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
