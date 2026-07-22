#!/usr/bin/env bash
# 23-install-app-server.sh — run ONE dockerized HTTP app on a loopback port
# behind caddy (the scripted Fieldkit/Plan-4 precedent). Mirrors 20's shape:
# stdin KEY=VALUE, idempotent re-runs carry forward from ~/apps/<name>/.env.
# Images arrive registry-free: IMAGE_TARBALL is docker-load'ed and pinned by
# image ID (tarballs carry no RepoDigests).
# Input (stdin): APP_NAME (req), APP_PORT (req first run), CONTAINER_PORT
#   (default 8080), HEALTH_PATH (default /api/health), IMAGE_TARBALL|IMAGE_REF,
#   APP_ENV_<KEY>=<value>... (rendered bare into .env; SUPABASE_URL +
#   SUPABASE_ANON_KEY must be present in the rendered env — the app refuses to
#   boot without them).
# Test hooks: APPS_DIR overrides ~/apps; HEALTH_TRIES/HEALTH_SLEEP override the
# health-check retry loop (default 30 tries, 2s apart) so shim tests can force
# a fast failing-health case.
set -euo pipefail
if [[ "$(id -u)" -eq 0 ]]; then
  echo "error: run as the service user, not root" >&2; exit 1
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/lib/app-server-env.sh"
TEMPLATES="${SCRIPT_DIR}/../templates/app-server"

APP_NAME="" ; APP_PORT="" ; CONTAINER_PORT="" ; HEALTH_PATH="" ; IMAGE_TARBALL="" ; IMAGE_REF=""
while IFS='=' read -r k v || [[ -n "${k:-}" ]]; do
  case "${k}" in
    APP_NAME) APP_NAME="${v}" ;;
    APP_PORT) APP_PORT="${v}" ;;
    CONTAINER_PORT) CONTAINER_PORT="${v}" ;;
    HEALTH_PATH) HEALTH_PATH="${v}" ;;
    IMAGE_TARBALL) IMAGE_TARBALL="${v}" ;;
    IMAGE_REF) IMAGE_REF="${v}" ;;
    APP_ENV_*) export "${k}=${v}" ;;
  esac
done
if [[ ! "${APP_NAME}" =~ ^[a-z][a-z0-9-]*$ ]]; then
  echo "error: APP_NAME required, ^[a-z][a-z0-9-]*$ (got: '${APP_NAME}')" >&2; exit 1
fi
APP_DIR="${APPS_DIR:-$HOME/apps}/${APP_NAME}"
[[ -z "${APP_PORT}" ]] && APP_PORT="$(app_server_env_val "${APP_DIR}/.env" APP_PORT)"
[[ -z "${CONTAINER_PORT}" ]] && CONTAINER_PORT="$(app_server_env_val "${APP_DIR}/.env" CONTAINER_PORT)"
[[ -z "${CONTAINER_PORT}" ]] && CONTAINER_PORT="8080"
[[ -z "${HEALTH_PATH}" ]] && HEALTH_PATH="$(app_server_env_val "${APP_DIR}/.env" HEALTH_PATH)"
[[ -z "${HEALTH_PATH}" ]] && HEALTH_PATH="/api/health"
if [[ ! "${APP_PORT}" =~ ^[0-9]+$ ]]; then
  echo "error: APP_PORT required (numeric), got '${APP_PORT}'" >&2; exit 1
fi

APP_IMAGE=""
if [[ -n "${IMAGE_TARBALL}" ]]; then
  [[ -f "${IMAGE_TARBALL}" ]] || { echo "error: IMAGE_TARBALL not found: ${IMAGE_TARBALL}" >&2; exit 1; }
  echo "==> app 1: docker load ${IMAGE_TARBALL}"
  LOADED="$(docker load -i "${IMAGE_TARBALL}" | tail -n1)"
  REF="${LOADED##*: }"
  APP_IMAGE="$(docker inspect --format '{{.Id}}' "${REF}")"
elif [[ -n "${IMAGE_REF}" ]]; then
  APP_IMAGE="$(docker inspect --format '{{.Id}}' "${IMAGE_REF}")"
fi

echo "==> app 2: stage ${APP_DIR}"
mkdir -p "${APP_DIR}"
chmod 700 "${APP_DIR}"
cp "${TEMPLATES}/docker-compose.yml" "${APP_DIR}/docker-compose.yml"
ENV_OLD=""
if [[ -f "${APP_DIR}/.env" ]]; then ENV_OLD="$(mktemp)"; cp "${APP_DIR}/.env" "${ENV_OLD}"; fi
export APP_NAME APP_PORT CONTAINER_PORT HEALTH_PATH APP_IMAGE
render_app_server_env "${APP_DIR}/.env" "${ENV_OLD}"
[[ -n "${ENV_OLD}" ]] && rm -f "${ENV_OLD}"

for req in SUPABASE_URL SUPABASE_ANON_KEY; do
  if [[ -z "$(app_server_env_val "${APP_DIR}/.env" "${req}")" ]]; then
    echo "error: ${req} missing from app env (pass APP_ENV_${req}=...)" >&2; exit 1
  fi
done
if [[ -z "$(app_server_env_val "${APP_DIR}/.env" APP_IMAGE)" ]]; then
  echo "error: no image (pass IMAGE_TARBALL or IMAGE_REF on first run)" >&2; exit 1
fi

COMPOSE=(docker compose -p "${APP_NAME}-app" -f "${APP_DIR}/docker-compose.yml" --env-file "${APP_DIR}/.env")
echo "==> app 3: docker compose up -d (project ${APP_NAME}-app)"
"${COMPOSE[@]}" up -d

echo "==> app 4: health check 127.0.0.1:${APP_PORT}${HEALTH_PATH}"
ok=""
for i in $(seq 1 "${HEALTH_TRIES:-30}"); do
  if curl -fsS "http://127.0.0.1:${APP_PORT}${HEALTH_PATH}" >/dev/null 2>&1; then ok=1; break; fi
  sleep "${HEALTH_SLEEP:-2}"
done
[[ -n "${ok}" ]] || { echo "error: app failed health check" >&2; exit 1; }
echo "✓ ${APP_NAME} serving on 127.0.0.1:${APP_PORT}"
