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
CORTEX_IMAGE="${CORTEX_IMAGE:-justnorthow/ollie-hermes-cortex@sha256:19104f0d92ef2aa3fe8450d872f76a5ee6b0fd3166bbe6bb99ce3afa987ae44a}"
FRONTEND_IMAGE="${FRONTEND_IMAGE:-justnorthow/ollie-hermes-frontend@sha256:8d0592254c8ac6ebde62f49be149198f110ab121138b5a0b01bb2cec90bc65af}"

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
# Default profile is always present. Use its port from .env.
DEFAULT_PORT="$(grep '^API_SERVER_PORT=' "${HERMES_ENV}" | cut -d= -f2-)"
DEFAULT_DASH=9119
# Detected profiles: just id + ports. Hand-rolled JSON (numbers unquoted) for portability.
det_entries=()
det_entries+=("$(printf '{"id":"default","gw":%s,"dash":%s}' "${DEFAULT_PORT}" "${DEFAULT_DASH}")")
for prof_env in "${HOME}"/.hermes/profiles/*/.env; do
  [[ -f "${prof_env}" ]] || continue
  prof_name="$(basename "$(dirname "${prof_env}")")"
  gw_port="$(grep '^API_SERVER_PORT=' "${prof_env}" | cut -d= -f2-)"
  # Resolve the dashboard port from the systemd unit ExecStart line.
  unit="${HOME}/.config/systemd/user/hermes-dashboard-${prof_name}.service"
  if [[ -f "${unit}" ]]; then
    dash_port="$(grep -oE -- '--port [0-9]+' "${unit}" | awk '{print $2}' | head -1)"
  else
    dash_port=""
  fi
  if [[ -z "${gw_port}" || -z "${dash_port}" ]]; then
    echo "    skipping profile '${prof_name}' (missing port info)" >&2
    continue
  fi
  det_entries+=("$(printf '{"id":"%s","gw":%s,"dash":%s}' "${prof_name}" "${gw_port}" "${dash_port}")")
done
DETECTED="[$(IFS=,; echo "${det_entries[*]}")]"

# Merge detection with the EXISTING AGENTS_JSON so the orchestrator wizard's
# displayName/color/model survive a re-run. Ports/URLs are refreshed from
# detection; agents whose profile is gone are dropped.
EXISTING_AGENTS="$(grep -E '^AGENTS_JSON=' "${STACK_ENV}" 2>/dev/null | cut -d= -f2- || true)"
AGENTS_JSON="$(EXISTING_AGENTS="${EXISTING_AGENTS}" DETECTED="${DETECTED}" python3 <<'PY'
import json, os
try:
    prev = {a["id"]: a for a in json.loads(os.environ.get("EXISTING_AGENTS") or "[]")}
except Exception:
    prev = {}
out = []
for d in json.loads(os.environ["DETECTED"]):
    p = prev.get(d["id"], {})
    entry = {
        "id": d["id"],
        # Preserve a wizard-set displayName; else default (capitalized id; "Ollie" for default).
        "name": p.get("name") or ("Ollie" if d["id"] == "default" else d["id"].capitalize()),
        "gatewayUrl": f'http://host.docker.internal:{d["gw"]}',
        "dashboardUrl": f'http://host.docker.internal:{d["dash"]}',
    }
    if p.get("color"):
        entry["color"] = p["color"]
    if p.get("model"):
        entry["model"] = p["model"]
    out.append(entry)
print(json.dumps(out, separators=(",", ":")))
PY
)"
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
