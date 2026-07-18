#!/usr/bin/env bash
# 06-install-stack.sh — install the Docker stack (cortex + ollie-dashboard).
#
# Run as: the service user (ollie by default; in the `docker` group)
# Idempotent: safe to re-run.
#
# What it does:
#   1. Creates ~/hermes-stack/ with docker-compose.yml (vendored from frontend repo)
#   2. Writes ~/hermes-stack/.env populated from existing host config:
#        - HERMES_GATEWAY_KEY ← ~/.hermes/.env's API_SERVER_KEY
#        - ORCHESTRATOR_KEY   ← ~/.config/ollie-orchestrator/.env's value
#        - AGENTS_JSON        ← auto-built by walking installed profiles
#   3. docker compose pull + up -d
#   4. Verifies the dashboard responds on :3000

set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  echo "error: run as the service user, not root" >&2
  exit 1
fi
if ! id -nG | grep -qw docker; then
  echo "error: service user not in docker group — log out and back in after running 01-bootstrap.sh" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/stack-env.sh
. "${SCRIPT_DIR}/lib/stack-env.sh"
COMPOSE_SRC="${SCRIPT_DIR}/../templates/docker-compose.yml"
OAUTH_TEMPLATES_SRC="${SCRIPT_DIR}/../templates/oauth2-templates"
STACK_DIR="${HOME}/hermes-stack"
STACK_ENV="${STACK_DIR}/.env"
HERMES_ENV="${HOME}/.hermes/.env"
ORCH_ENV="${HOME}/.config/ollie-orchestrator/.env"
CORTEX_IMAGE="${CORTEX_IMAGE:-justnorthow/ollie-hermes-cortex@sha256:927f2edc93929fb10598b12c45ccc16a9fe9a4a8120a1c5eaf5c6fab391e753c}"
FRONTEND_IMAGE="${FRONTEND_IMAGE:-justnorthow/ollie-hermes-frontend@sha256:c02fc1d80929e4b70980b0d53fff6f71e65f4f6f8799436b2ddfea80cd5f9d2d}"

echo "==> step 1: stage ${STACK_DIR}/docker-compose.yml"
mkdir -p "${STACK_DIR}"
cp "${COMPOSE_SRC}" "${STACK_DIR}/docker-compose.yml"
# Stage the oauth2-proxy custom templates (friendly "not authorized" page,
# bind-mounted into the oauth2-proxy container via docker-compose.yml).
mkdir -p "${STACK_DIR}/oauth2-templates"
cp "${OAUTH_TEMPLATES_SRC}/"* "${STACK_DIR}/oauth2-templates/"
# The compose bind-mounts ./oauth2-emails as a file (oauth2-proxy's allowed-emails
# list, written by Fleet). If the host path is missing, Docker creates a DIRECTORY
# at mount time, which breaks oauth2-proxy. Ensure a FILE exists — never clobber
# an existing list Fleet may have written.
[ -f "${STACK_DIR}/oauth2-emails" ] || : > "${STACK_DIR}/oauth2-emails"

echo "==> step 2: derive secrets from host config"
if [[ ! -f "${HERMES_ENV}" ]]; then
  echo "error: ${HERMES_ENV} missing — run 02-install-hermes.sh first" >&2; exit 1
fi
if [[ ! -f "${ORCH_ENV}" ]]; then
  echo "error: ${ORCH_ENV} missing — run 05-install-orchestrator.sh first" >&2; exit 1
fi
GATEWAY_KEY="$(grep '^API_SERVER_KEY=' "${HERMES_ENV}" | cut -d= -f2-)"
ORCH_KEY="$(grep '^ORCHESTRATOR_KEY=' "${ORCH_ENV}" | cut -d= -f2-)"

echo "==> step 3: build AGENTS_JSON (auto-detect profiles, preserve wizard-set fields)"
. "${SCRIPT_DIR}/lib/detect-agents.sh"
DETECTED="$(HERMES_ENV_FILE="${HERMES_ENV}" detect_agents)"

# Merge detection with the EXISTING AGENTS_JSON so operator/wizard-set fields
# (displayName/color/model/scope/manager_visible) survive a re-run; ports/URLs are
# refreshed from detection; agents whose profile is gone are dropped.
EXISTING_AGENTS="$(grep -E '^AGENTS_JSON=' "${STACK_ENV}" 2>/dev/null | cut -d= -f2- || true)"
AGENTS_JSON="$(EXISTING_AGENTS="${EXISTING_AGENTS}" DETECTED="${DETECTED}" python3 "${SCRIPT_DIR}/lib/merge-agents-json.py")"
echo "    detected agents: $(echo "${AGENTS_JSON}" | python3 -c 'import sys,json; print(", ".join(a["id"] for a in json.load(sys.stdin)))')"

echo "==> step 4: write ${STACK_ENV} (rewrites every run to keep it canonical)"
# Snapshot the current .env so we can carry forward OAuth keys Fleet wrote (this
# script doesn't manage them but must not wipe them — see preserve_env_keys).
ENV_OLD=""
if [[ -f "${STACK_ENV}" ]]; then
  ENV_OLD="$(mktemp)"
  cp "${STACK_ENV}" "${ENV_OLD}"
fi
export GATEWAY_KEY ORCH_KEY CORTEX_IMAGE FRONTEND_IMAGE AGENTS_JSON
render_stack_env "${STACK_ENV}" "${ENV_OLD}"
[[ -n "${ENV_OLD}" ]] && rm -f "${ENV_OLD}"
chmod 600 "${STACK_ENV}"
# Re-read the two operator-supplied keys back out of the rendered .env for the
# verification "note" checks below (render_stack_env resolves/writes them but
# keeps them function-local; this does not change their resolved value).
FIRECRAWL_API_KEY="$(grep -E '^FIRECRAWL_API_KEY=' "${STACK_ENV}" | cut -d= -f2-)"
HERMES_UI_URL="$(grep -E '^HERMES_UI_URL=' "${STACK_ENV}" | cut -d= -f2-)"

echo "==> step 5: docker compose pull + up -d"
# If OAuth is configured (Fleet wrote a non-empty CLIENT_ID), activate the "oauth"
# profile so oauth2-proxy starts — otherwise a re-run would leave an OAuth-enabled
# box with the dashboard in OAuth mode but no proxy backend behind /oauth2/.
PROFILE_ARGS=""
if grep -qE '^OAUTH2_PROXY_CLIENT_ID=.+' "${STACK_ENV}"; then
  PROFILE_ARGS="--profile oauth"
  echo "    OAuth configured — bringing stack up with the oauth profile"
fi
docker compose -f "${STACK_DIR}/docker-compose.yml" ${PROFILE_ARGS} pull --quiet
docker compose -f "${STACK_DIR}/docker-compose.yml" ${PROFILE_ARGS} up -d

# Cortex runs as non-root (uid 100) since the 2026-07-05 security batch, but
# volumes created by the earlier root-running image are root-owned — sqlite
# writes then fail with "attempt to write a readonly database" (bit jnow prod
# 2026-07-07 on POST /brain/discover). Normalize ownership every run; no-op on
# healthy volumes.
docker compose -f "${STACK_DIR}/docker-compose.yml" exec -T -u 0 cortex \
  chown -R 100:101 /data /plugin 2>/dev/null \
  || echo "    (cortex volume chown skipped — container not running)"

echo
echo "==> step 5b: hermes dashboard bridge (docker bridge IP -> loopback :9119)"
# The native Hermes dashboard binds 127.0.0.1:9119 (DNS-rebinding guard), but
# the dashboard container reaches it via host.docker.internal = 172.17.0.1 —
# unreachable for a loopback-only bind. A socat unit bridges the docker bridge
# IP to loopback (bound to 172.17.0.1 only; the host firewall covers external
# exposure). Without it, /hermes-proxy (transcripts) and the gated
# <instance>-hermes hostname 502 (hit live on the GetBilled box, 2026-07-11 —
# the unit existed only hand-built on older boxes).
if ! command -v socat >/dev/null; then
  sudo apt-get install -y -q socat >/dev/null
fi
sudo install -m 0644 "${SCRIPT_DIR}/../templates/systemd/hermes-dashboard-bridge.service" \
  /etc/systemd/system/hermes-dashboard-bridge.service
sudo systemctl daemon-reload
sudo systemctl enable --now hermes-dashboard-bridge.service
echo "    bridge: $(systemctl is-active hermes-dashboard-bridge.service)"

echo
echo "==> verification (give nginx 5s to finish its agents.conf regen)"
sleep 5
set +e
echo "    container state:"
docker compose -f "${STACK_DIR}/docker-compose.yml" ps --format 'table {{.Service}}\t{{.Status}}'
code=$(curl -s -o /dev/null -w '%{http_code}' -m 5 http://localhost:3000/)
echo "    dashboard http :3000 → ${code:-no response} ($([ "${code}" = "200" ] && echo "✓" || echo "expected 200"))"
code=$(curl -s -o /dev/null -w '%{http_code}' -m 5 http://localhost:9120/health)
echo "    cortex    http :9120/health → ${code:-no response} ($([ "${code}" = "200" ] && echo "✓" || echo "expected 200"))"
if [[ -z "${FIRECRAWL_API_KEY}" ]]; then
  echo "    note: Brain Discovery web crawl is disabled — set FIRECRAWL_API_KEY in ${STACK_ENV}"
  echo "          (or export it and re-run) to enable website crawling. Document uploads work without it."
fi
if [[ -z "${HERMES_UI_URL}" ]]; then
  echo "    note: HERMES_UI_URL unset — the dashboard's \"Backend Settings\" link points to"
  echo "          http://<host>:9119, which HTTPS-First browsers reject (ERR_SSL_PROTOCOL_ERROR)."
  echo "          Set HERMES_UI_URL in ${STACK_ENV} to the Cloudflare Access URL for the dashboard"
  echo "          (see docs/runbooks/hermes-dashboard-cloudflare.md)."
fi
set -e

echo
echo "✓ Stack installed and running."
echo
echo "Open in your browser: http://<this-host-ip>:3000/chat"
