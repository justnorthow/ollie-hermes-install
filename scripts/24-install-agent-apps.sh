#!/usr/bin/env bash
# 24-install-agent-apps.sh <profile> [app-name] — install every app the manifest
# (apps/<profile>.json) bundles with an agent profile: 26 (app schema + owner
# role) -> app migrations (extracted from the app image; applied into the
# core database as the app's owner role, tracked in <name>._migrations) ->
# 23 (app server) -> dashboard tile registration (manifest apps with a "tile"
# key are upserted into the orchestrator's per-profile app registry) -> app
# bridge check. There is NO caddy step: consolidated apps are served
# same-origin under /apps/<name>/ through the dashboard's nginx, so no app has
# a vhost or hostname of its own. Bridges need root, so this prints the exact
# commands: one per app, plus core-sb once per box.
# Box-derived config is resolved here (core anon key, orchestrator loopback);
# operator secrets arrive on stdin and flow through, never argv.
# An optional second argument narrows the run to ONE app in the manifest —
# the only safe way to install a single app while others in the same profile
# are still on the old per-app-stack path.
# Input (stdin): IMAGE_TARBALL_<NAME> per app on first install (e.g.
#   IMAGE_TARBALL_POPBYS); the bare IMAGE_TARBALL key is legal ONLY when this
#   run installs exactly one app — a single-app manifest, or a manifest
#   narrowed by the app-name argument. Re-runs need neither: the image is
#   already pinned in ~/apps/<name>/.env. Also GOOGLE_CLIENT_ID,
#   GOOGLE_CLIENT_SECRET, ORCH_ENV_FILE, ORCH_PORT, STACK_ENV_FILE,
#   manifest-declared bare runtime inputs (for example GOOGLE_MAPS_API_KEY),
#   plus APP_ENV_<KEY>... global passthrough (which overrides server.env and
#   manifest-scoped inputs). A server.required_env input must be supplied on
#   first install; server.optional_env is routed when present. Existing values
#   in ~/apps/<name>/.env satisfy required inputs and survive re-runs.
# APP_HOST/SB_HOST are retired: apps are served same-origin under
#   /apps/<name>/, so none has a hostname or a Supabase of its own.
# STACK_ENV_FILE (default ${HOME}/hermes-stack/.env) is the dashboard's OWN
# stack env — distinct from ORCH_ENV_FILE, which may point elsewhere (e.g.
# ~/.config/ollie-orchestrator/.env). Tile apps get <NAME>_BASE_URL written
# here so generate-nginx.sh proxies /apps/<name>/ instead of rendering blank.
# ORCH_ENV_FILE also supplies ORCHESTRATOR_KEY (used both as
# APP_ENV_OLLIE_ORCHESTRATOR_KEY and as the bearer for the tile-registry POST).
# The app's Supabase identity comes entirely from the CORE stack: its public
# URL and ANON_KEY (from CORE_STACK_DIR/.env), and its runtime key — a JWT
# claiming role=<name>_owner, minted by 26 into CORE_STACK_DIR/app-keys/<name>.jwt
# — passed through as APP_ENV_SUPABASE_APP_KEY. This REPLACES service_role for
# the app; core's SERVICE_ROLE_KEY must never reach an app container, so it is
# never read here.
set -euo pipefail
if [[ "$(id -u)" -eq 0 ]]; then
  echo "error: run as the service user, not root" >&2; exit 1
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/lib/supabase-app-env.sh"
. "${SCRIPT_DIR}/lib/app-server-env.sh"
. "${SCRIPT_DIR}/lib/app-migrations.sh"
PROFILE="${1:-}"
MANIFEST="${MANIFEST_DIR:-${SCRIPT_DIR}/../apps}/${PROFILE}.json"
[[ -n "${PROFILE}" && -f "${MANIFEST}" ]] || { echo "error: no manifest for profile '${PROFILE}'" >&2; exit 1; }
SUB20="${SUB20:-${SCRIPT_DIR}/20-install-app-stack.sh}"
SUB23="${SUB23:-${SCRIPT_DIR}/23-install-app-server.sh}"
SUB26="${SUB26:-${SCRIPT_DIR}/26-provision-app-schema.sh}"
SUB27="${SUB27:-${SCRIPT_DIR}/27-provision-app-storage.sh}"
CORE_DIR="${CORE_STACK_DIR:-$HOME/supabase-stack}"
STACKS="${STACKS_DIR:-$HOME/stacks}"
# The CORE stack's kong port is fixed (compose publishes 127.0.0.1:8000) and is
# the only Supabase a consolidated app talks to. Kept as one constant so the
# value written to APP_ENV_SUPABASE_INTERNAL_URL and the value the bridge probe
# checks can never drift apart — they did, and the probe spent that time
# reporting a failure for a per-app kong the app never used.
CORE_KONG_PORT=8000

APP_HOST="" ; SB_HOST="" ; IMAGE_TARBALL="" ; GOOGLE_CLIENT_ID="" ; GOOGLE_CLIENT_SECRET=""
ORCH_ENV_FILE="" ; ORCH_PORT="" ; STACK_ENV_FILE=""
declare -a PASSTHRU=()
declare -A INPUT_ENV=()
while IFS='=' read -r k v || [[ -n "${k:-}" ]]; do
  case "${k}" in
    APP_HOST) APP_HOST="${v}" ;;
    SB_HOST) SB_HOST="${v}" ;;
    IMAGE_TARBALL) IMAGE_TARBALL="${v}" ;;
    GOOGLE_CLIENT_ID) GOOGLE_CLIENT_ID="${v}" ;;
    GOOGLE_CLIENT_SECRET) GOOGLE_CLIENT_SECRET="${v}" ;;
    ORCH_ENV_FILE) ORCH_ENV_FILE="${v}" ;;
    ORCH_PORT) ORCH_PORT="${v}" ;;
    STACK_ENV_FILE) STACK_ENV_FILE="${v}" ;;
    # Per-app image, resolved into a per-iteration local inside the loop.
    IMAGE_TARBALL_*) export "${k}=${v}" ;;
    APP_ENV_*) PASSTHRU+=("${k}=${v}") ;;
    # Bare runtime inputs are inert unless a target app explicitly declares
    # the key in server.required_env or server.optional_env. This lets one
    # multi-app install receive a secret once without broadcasting it to every
    # app container (the legacy APP_ENV_* passthrough is intentionally global).
    *) [[ "${k}" =~ ^[A-Z][A-Z0-9_]*$ ]] && INPUT_ENV["${k}"]="${v}" ;;
  esac
done
ORCH_ENV_FILE="${ORCH_ENV_FILE:-$HOME/hermes-stack/.env}"
ORCH_PORT="${ORCH_PORT:-9123}"
STACK_ENV_FILE="${STACK_ENV_FILE:-$HOME/hermes-stack/.env}"

mf() { # JQPATH — read a manifest value
  python3 -c "import json,sys; d=json.load(open('${MANIFEST}')); print(eval('d'+sys.argv[1]))" "$1"
}
APP_COUNT="$(mf "['apps'].__len__()")"
# Every app name is used three ways with three different character rules:
#   26-provision-app-schema.sh  ^[a-z][a-z0-9_]*$   Postgres identifier, no hyphens
#   23-install-app-server.sh    ^[a-z][a-z0-9-]*$   compose project, no underscores
#   25-install-app-bridge.sh    ^[a-z][a-z0-9-]*$   systemd unit, no underscores
# So a name with an underscore breaks the bridge and a name with a hyphen
# breaks the schema. Enforce the intersection here, before any install work,
# rather than half-installing and failing at whichever script runs first.
for i in $(seq 0 $((APP_COUNT-1))); do
  _n="$(mf "['apps'][${i}]['name']")"
  if [[ ! "${_n}" =~ ^[a-z][a-z0-9]*$ ]]; then
    echo "error: manifest app name '${_n}' is invalid — must match ^[a-z][a-z0-9]*\$ (the intersection of the Postgres identifier rule used by 26 and the systemd/compose unit rule used by 23 and 25)" >&2
    exit 1
  fi
done
unset _n
# Which apps THIS RUN installs. An optional second argument narrows a
# multi-app manifest to one app — the only safe way to install a single app
# while others in the same profile are still on the old per-app-stack path.
APP_FILTER="${2:-}"
TARGETS=()
if [[ -n "${APP_FILTER}" ]]; then
  for i in $(seq 0 $((APP_COUNT-1))); do
    [[ "$(mf "['apps'][${i}]['name']")" == "${APP_FILTER}" ]] && TARGETS+=("${i}")
  done
  if [[ ${#TARGETS[@]} -eq 0 ]]; then
    NAMES=""
    for i in $(seq 0 $((APP_COUNT-1))); do NAMES="${NAMES} $(mf "['apps'][${i}]['name']")"; done
    echo "error: no app '${APP_FILTER}' in ${MANIFEST} — manifest apps are:${NAMES}" >&2
    exit 1
  fi
else
  for i in $(seq 0 $((APP_COUNT-1))); do TARGETS+=("${i}"); done
fi
# How many apps this RUN installs — NOT how many the manifest holds. The bare
# stdin keys are legal only when this is 1.
TARGET_COUNT=${#TARGETS[@]}

# Validate every manifest runtime-input declaration before contacting the
# orchestrator or mutating a schema. Only declarations for this run's targets
# are emitted. Required inputs may come from this stdin or an existing app env;
# script 23's carry-forward then preserves the latter without exposing it here.
declare -A APP_INPUT_KEYS=()
ENV_DECLS="$(python3 -c '
import json, re, sys

path = sys.argv[1]
targets = {int(v) for v in sys.argv[2:]}
d = json.load(open(path))
for i, app in enumerate(d["apps"]):
    server = app.get("server") or {}
    seen = set()
    for field, mode in (("required_env", "required"), ("optional_env", "optional")):
        values = server.get(field, [])
        if not isinstance(values, list):
            raise SystemExit("error: manifest app %r server.%s must be an array" % (app.get("name"), field))
        for key in values:
            if not isinstance(key, str) or not re.fullmatch(r"[A-Z][A-Z0-9_]*", key):
                raise SystemExit("error: manifest app %r has invalid %s key %r - keys must match ^[A-Z][A-Z0-9_]*$" % (app.get("name"), field, key))
            if key in seen:
                raise SystemExit("error: manifest app %r declares %s more than once" % (app.get("name"), key))
            seen.add(key)
            if i in targets:
                print("%s\t%s\t%s\t%s" % (i, app["name"], mode, key))
' "${MANIFEST}" "${TARGETS[@]}")"
while IFS=$'\t' read -r env_i env_name env_mode env_key; do
  [[ -n "${env_key}" ]] || continue
  APP_INPUT_KEYS["${env_i}"]+="${env_key}"$'\n'
  if [[ "${env_mode}" == "required" \
     && -z "${INPUT_ENV[${env_key}]:-}" \
     && -z "$(app_server_env_val "${APPS_DIR:-$HOME/apps}/${env_name}/.env" "${env_key}")" ]]; then
    echo "error: missing required env ${env_key} for app '${env_name}' - pass ${env_key}=<value> on stdin" >&2
    exit 1
  fi
done <<< "${ENV_DECLS}"

ORCH_KEY="$(grep -E '^ORCHESTRATOR_KEY=' "${ORCH_ENV_FILE}" | tail -n1 | cut -d= -f2- || true)"
[[ -n "${ORCH_KEY}" ]] || {
  echo "error: no ORCHESTRATOR_KEY in ${ORCH_ENV_FILE} — pass ORCH_ENV_FILE=<path> (on many boxes the orchestrator reads ~/.config/ollie-orchestrator/.env, not ~/hermes-stack/.env)" >&2
  exit 1
}

# WARNINGS counts every non-fatal WARNING emitted below (an unreachable kong
# bridge probe, a BASE_URL skip/no-op, a failed dashboard recreate, ...). A non-zero count
# suppresses the final ✓ banner (see the end of this script) — the run still
# exits 0, but the operator gets an unmissable ⚠ instead of a false-positive
# success line.
WARNINGS=0

# Preflight: the orchestrator 404s the dashboard-tile POST (stage 5/6, below)
# if no agent with id == PROFILE exists yet — on a real box that kills the
# run after the Supabase stack and app server are already built. Confirm (or
# create) the agent FIRST so a missing agent fails before any install work.
echo "==> agent-apps: preflight — agent '${PROFILE}' must exist"
AGENTS_BODY="$(mktemp)"
AGENTS_STATUS="$(curl -sS -o "${AGENTS_BODY}" -w '%{http_code}' \
  -H "Authorization: Bearer ${ORCH_KEY}" \
  "http://127.0.0.1:${ORCH_PORT}/v1/agents")" || true
if [[ "${AGENTS_STATUS}" != "200" ]]; then
  # A 401/500/connection-refused must NOT collapse into "agent absent" — that
  # would misreport a broken orchestrator as a missing-agent condition and
  # send the operator chasing the wrong fix.
  echo "error: could not list agents from the orchestrator (http ${AGENTS_STATUS:-000}) — check ORCH_PORT/ORCH_ENV_FILE and that the orchestrator is reachable" >&2
  rm -f "${AGENTS_BODY}"
  exit 1
fi
AGENTS_JSON="$(cat "${AGENTS_BODY}")"
rm -f "${AGENTS_BODY}"
AGENT_PRESENT="$(printf '%s' "${AGENTS_JSON}" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
if not isinstance(d, dict):
    d = {}
print('1' if any(a.get('id') == '${PROFILE}' for a in (d.get('agents') or [])) else '')
")"
if [[ -z "${AGENT_PRESENT}" ]]; then
  HAS_AGENT_BLOCK="$(python3 -c "
import json
d = json.load(open('${MANIFEST}'))
print('1' if (d.get('agent') or {}) else '')
")"
  if [[ -z "${HAS_AGENT_BLOCK}" ]]; then
    echo "error: no agent '${PROFILE}' on this box and the manifest declares no agent defaults — create it in Fleet's Agents tab first" >&2
    exit 1
  fi
  AGENT_PAYLOAD="$(python3 -c "
import json
d = json.load(open('${MANIFEST}'))
a = d.get('agent') or {}
payload = {'name': d['profile'], 'authMethod': 'inherit'}
if a.get('display_name'): payload['displayName'] = a['display_name']
if a.get('subtitle'):     payload['subtitle']    = a['subtitle']
if a.get('color'):        payload['color']       = a['color']
print(json.dumps(payload))
")"
  curl -fsS -X POST "http://127.0.0.1:${ORCH_PORT}/v1/agents" \
    -H "Authorization: Bearer ${ORCH_KEY}" \
    -H 'Content-Type: application/json' \
    -d "${AGENT_PAYLOAD}" >/dev/null \
    || { echo "error: could not create agent '${PROFILE}'" >&2; exit 1; }
  # The create endpoint returns 202 ACCEPTED with a streaming (SSE) body —
  # creation failures show up as an `event: error` INSIDE that stream, not as
  # an HTTP error status, so the POST exiting 0 proves nothing. Creation is
  # asynchronous, so poll GET /v1/agents/<profile> (404 until it really
  # exists) with a short bounded retry before trusting it.
  AGENT_VERIFY_ATTEMPTS="${AGENT_VERIFY_ATTEMPTS:-10}"
  AGENT_VERIFY_INTERVAL="${AGENT_VERIFY_INTERVAL:-2}"
  AGENT_VERIFIED=""
  for _ in $(seq 1 "${AGENT_VERIFY_ATTEMPTS}"); do
    VERIFY_STATUS="$(curl -sS -o /dev/null -w '%{http_code}' \
      -H "Authorization: Bearer ${ORCH_KEY}" \
      "http://127.0.0.1:${ORCH_PORT}/v1/agents/${PROFILE}")" || true
    if [[ "${VERIFY_STATUS}" == "200" ]]; then AGENT_VERIFIED=1; break; fi
    sleep "${AGENT_VERIFY_INTERVAL}"
  done
  if [[ -z "${AGENT_VERIFIED}" ]]; then
    echo "error: agent '${PROFILE}' was not created (the orchestrator accepted the request but the agent does not exist — check the orchestrator logs)" >&2
    exit 1
  fi
  echo "    agent '${PROFILE}' created from manifest defaults (authMethod=inherit)"
else
  echo "    agent '${PROFILE}' already exists — leaving it untouched"
fi

# ONE core Supabase serves every app on this box, so this is a per-RUN check,
# not a per-app one — probing it inside the loop turns one missing bridge into
# N identical warnings and inflates the final count. /api/health does not touch
# Supabase, so a missing bridge leaves every app "healthy" while every API call
# fails. The bridge is shared, hence the fixed `core-sb` name.
if ! curl -fsS --max-time 10 "http://172.17.0.1:${CORE_KONG_PORT}/auth/v1/health" >/dev/null 2>&1; then
  echo "    WARNING: core Supabase at http://172.17.0.1:${CORE_KONG_PORT} is unreachable from the docker0 gateway — apps will look healthy but every API call will fail. Install the bridge: sudo bash ${SCRIPT_DIR}/25-install-app-bridge.sh core-sb:${CORE_KONG_PORT}" >&2
  WARNINGS=$((WARNINGS+1))
fi

for i in "${TARGETS[@]}"; do
  NAME="$(mf "['apps'][${i}]['name']")"
  # KONG_PORT / EMAIL_ENABLED are gone with the per-app stack: nothing consumes
  # them, and reading them would fail on a manifest that has dropped its
  # now-meaningless `stack` block.
  APP_PORT="$(mf "['apps'][${i}]['server']['app_port']")"
  CONTAINER_PORT="$(mf "['apps'][${i}]['server']['container_port']")"
  HEALTH_PATH="$(mf "['apps'][${i}]['server']['health_path']")"
  # APP_HOST / SB_HOST are gone with tile-only serving: apps are reached solely
  # at <box>/apps/<name>/ through the dashboard's nginx, so no app has a
  # hostname of its own, and a consolidated app has no Supabase of its own to
  # give one to. They were also single-app globals — requiring them here would
  # have forced every app in a profile to share one hostname.

  # Per-iteration local. NEVER assign back to IMAGE_TARBALL: with two apps that
  # leaks app 0's tarball into app 1, installing app 0's IMAGE under app 1's
  # name and port — where it passes app 1's own health check. Nothing looks
  # broken, which makes it far worse than a wrong hostname.
  UPPER="$(printf '%s' "${NAME}" | tr '[:lower:]' '[:upper:]')"
  PER_APP_VAR="IMAGE_TARBALL_${UPPER}"
  APP_TARBALL="${!PER_APP_VAR:-}"
  # An explicitly passed tarball ALWAYS wins over the image pinned in the app's
  # own .env. The pin is a convenience for re-runs that supply no tarball;
  # preferring it over an explicit argument turns `IMAGE_TARBALL=<new>` into a
  # silent no-op that reports success while installing the OLD image. Three
  # rebuilds were shipped to the sandbox box with no effect before this was
  # found, because the app's .env still pinned a two-day-old image.
  if [[ -z "${APP_TARBALL}" && "${TARGET_COUNT}" -eq 1 && -n "${IMAGE_TARBALL}" ]]; then
    APP_TARBALL="${IMAGE_TARBALL}"
  fi
  if [[ -z "${APP_TARBALL}" ]]; then
    if [[ -n "$(app_image_from_env "${NAME}")" ]]; then
      # Re-run path: no tarball supplied, so use the image already pinned.
      APP_TARBALL=""
    elif [[ "${TARGET_COUNT}" -eq 1 ]]; then
      APP_TARBALL="${IMAGE_TARBALL}"
    else
      echo "error: no image for '${NAME}' — pass ${PER_APP_VAR}=<path>. The bare IMAGE_TARBALL key is only legal when exactly one app is being installed (a single-app manifest, or narrow this run: 24-install-agent-apps.sh ${PROFILE} ${NAME})" >&2
      exit 1
    fi
    if [[ -z "${APP_TARBALL}" && -z "$(app_image_from_env "${NAME}")" ]]; then
      echo "error: no image for '${NAME}' — pass ${PER_APP_VAR}=<path> on first install" >&2
      exit 1
    fi
  fi

  # Manifest server.env, emitted BEFORE the operator passthrough so an
  # APP_ENV_<KEY> on stdin still wins.
  MF_ENV="$(python3 -c "
import json
d = json.load(open('${MANIFEST}'))
for k, v in ((d['apps'][${i}].get('server') or {}).get('env') or {}).items():
    print('APP_ENV_%s=%s' % (k, v))
")"

  echo "==> agent-apps [${NAME}] 1/6: app schema + owner role in the core stack"
  {
    echo "APP_NAME=${NAME}"
    echo "CORE_STACK_DIR=${CORE_DIR}"
  } | bash "${SUB26}"

  echo "==> agent-apps [${NAME}] 2/6: app migrations into schema '${NAME}'"
  if [[ -n "${APP_TARBALL}" ]]; then
    LOAD_OUT="$(docker load -i "${APP_TARBALL}")"
    if [[ "$(grep -c '^Loaded image' <<<"${LOAD_OUT}")" -ne 1 ]]; then
      echo "error: tarball must contain exactly one image (got: ${LOAD_OUT})" >&2; exit 1
    fi
    LOADED="$(tail -n1 <<<"${LOAD_OUT}")"; IMG="${LOADED##*: }"
  else
    IMG="$(app_image_from_env "${NAME}")"   # helper: APP_IMAGE from ~/apps/<name>/.env
  fi
  CORE_PGPASS="$(supabase_app_env_val "${CORE_DIR}/.env" POSTGRES_PASSWORD)"
  [[ -n "${CORE_PGPASS}" ]] || { echo "error: POSTGRES_PASSWORD missing from ${CORE_DIR}/.env" >&2; exit 1; }
  core_psql() {
    # ${NAME}_owner is NOLOGIN by design (26 CREATEs it that way and only
    # GRANTs it to authenticator, for PostgREST's role-switching — it was
    # never meant to be connected to directly). Postgres rejects a NOLOGIN
    # role at connection time, before authentication is even consulted, so
    # connecting with `-U ${NAME}_owner` fails outright regardless of
    # PGPASSWORD/pg_hba. Connect as postgres instead and switch the SESSION
    # role via PGOPTIONS. Objects created under that session role are still
    # OWNED BY ${NAME}_owner (ownership follows the session/current role, not
    # the login role), so they still inherit the default privileges 26
    # installed for the PostgREST roles — the ownership requirement this
    # comment used to describe is preserved; only the connection mechanism
    # changed. Do not "simplify" this back to `-U ${NAME}_owner`.
    docker compose -f "${CORE_DIR}/docker-compose.yml" --env-file "${CORE_DIR}/.env" \
      exec -T -e PGPASSWORD="${CORE_PGPASS}" -e PGOPTIONS="-c role=${NAME}_owner" db \
      psql -h 127.0.0.1 -U postgres -d postgres -v ON_ERROR_STOP=1 -qtA "$@"
  }
  app_migrations_apply "${IMG}" core_psql "${NAME}._migrations" "${NAME}"

  STORAGE_JSON="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps(d["apps"][int(sys.argv[2])].get("storage") or {}))' "${MANIFEST}" "${i}")"
  if [[ "${STORAGE_JSON}" != "{}" ]]; then
    echo "==> agent-apps [${NAME}] 3/6: private storage contract"
    {
      echo "APP_NAME=${NAME}"
      echo "CORE_STACK_DIR=${CORE_DIR}"
      printf 'STORAGE_CONFIG_JSON=%s\n' "${STORAGE_JSON}"
    } | bash "${SUB27}"
  fi

  echo "==> agent-apps [${NAME}] 4/6: app server (port ${APP_PORT})"
  # ORCH_KEY was already resolved above (before the preflight).
  CORE_URL="$(supabase_app_env_val "${CORE_DIR}/.env" SUPABASE_PUBLIC_URL)"
  ANON="$(supabase_app_env_val "${CORE_DIR}/.env" ANON_KEY)"
  [[ -n "${CORE_URL}" ]] || { echo "error: SUPABASE_PUBLIC_URL missing from ${CORE_DIR}/.env" >&2; exit 1; }
  [[ -n "${ANON}" ]] || { echo "error: ANON_KEY missing from ${CORE_DIR}/.env" >&2; exit 1; }
  # The app's runtime key: a JWT claiming role=<name>_owner, minted by 26.
  # This REPLACES service_role for the app. Core's service_role key bypasses
  # RLS and reaches every schema plus auth, so it must never reach a container.
  APP_KEY_FILE="${CORE_DIR}/app-keys/${NAME}.jwt"
  [[ -f "${APP_KEY_FILE}" ]] || { echo "error: ${APP_KEY_FILE} not found — 26 should have minted it in step 1/6" >&2; exit 1; }
  APP_KEY="$(cat "${APP_KEY_FILE}")"
  [[ -n "${APP_KEY}" ]] || { echo "error: ${APP_KEY_FILE} is empty" >&2; exit 1; }

  # A pre-consolidation ~/apps/<name>/.env may still carry credentials for
  # the retired per-app Supabase stack. Script 23 deliberately preserves bare
  # app env keys across re-runs, so without an explicit scrub those stale
  # service-role/SSO credentials survive the cutover and enter the consolidated
  # container. They are unnecessary with the shared first-party session and,
  # more importantly, a service-role key must never be present in an app that
  # now talks to the core stack. Remove only the fixed retired keys before 23
  # snapshots the old file; the running container is unchanged until 23 has
  # successfully rendered the replacement and recreated it.
  OLD_APP_ENV="${APPS_DIR:-$HOME/apps}/${NAME}/.env"
  if [[ -f "${OLD_APP_ENV}" ]]; then
    sed -i -E '/^(SUPABASE_SERVICE_ROLE_KEY|HIA_SSO_SECRET|NEWSLETTER_SSO_SECRET)=/d' "${OLD_APP_ENV}"
  fi
  {
    echo "APP_NAME=${NAME}"
    echo "APP_PORT=${APP_PORT}"
    echo "CONTAINER_PORT=${CONTAINER_PORT}"
    echo "HEALTH_PATH=${HEALTH_PATH}"
    [[ -n "${APP_TARBALL}" ]] && echo "IMAGE_TARBALL=${APP_TARBALL}"
    echo "APP_ENV_SUPABASE_URL=${CORE_URL}"
    # Server-side callers must NOT use the public hostname: on a cloudflared
    # box it resolves to Cloudflare's edge, which bot-challenges non-browser
    # clients (HTTP 403) and breaks auth on every route. Core kong is
    # loopback-only, so reach it over the docker0 gateway bridge from 25.
    echo "APP_ENV_SUPABASE_INTERNAL_URL=http://172.17.0.1:${CORE_KONG_PORT}"
    echo "APP_ENV_SUPABASE_ANON_KEY=${ANON}"
    echo "APP_ENV_SUPABASE_APP_KEY=${APP_KEY}"
    echo "APP_ENV_SUPABASE_DB_SCHEMA=${NAME}"
    echo "APP_ENV_OLLIE_ENDPOINT=http://127.0.0.1:${ORCH_PORT}"
    echo "APP_ENV_OLLIE_AGENT=${PROFILE}"
    [[ -n "${ORCH_KEY}" ]] && echo "APP_ENV_OLLIE_ORCHESTRATOR_KEY=${ORCH_KEY}"
    echo "APP_ENV_APP_BASE_PATH=/apps/${NAME}"
    # Static manifest env first, then manifest-scoped bare inputs, then global
    # operator passthrough. Script 23 keeps the last value for a repeated key.
    [[ -n "${MF_ENV}" ]] && printf '%s\n' "${MF_ENV}"
    while IFS= read -r env_key; do
      [[ -n "${env_key}" && -n "${INPUT_ENV[${env_key}]:-}" ]] \
        && echo "APP_ENV_${env_key}=${INPUT_ENV[${env_key}]}"
    done <<< "${APP_INPUT_KEYS[${i}]:-}"
    printf '%s\n' "${PASSTHRU[@]:-}" | grep -v '^$' || true
    true   # group's exit status must not hinge on the last optional/passthrough line (pipefail)
  } | bash "${SUB23}"

  echo "==> agent-apps [${NAME}] 5/6: dashboard tile registration"
  HAS_TILE="$(python3 -c "import json; d=json.load(open('${MANIFEST}')); print('1' if 'tile' in d['apps'][${i}] else '')")"
  if [[ -n "${HAS_TILE}" ]]; then
    # Build the whole JSON payload in python (json.dumps) so tile field
    # values never get bash-string-spliced into a JSON literal — they come
    # straight out of the committed manifest, read by python, not interpolated.
    #
    # sso is registered FALSE. ExternalWebApp.tsx treats a truthy sso as: fetch
    # an app-token, then load <base>sso?t=... That handoff signs into the app-s
    # OWN Supabase with a service-role client. A consolidated app has no
    # Supabase of its own and is handed no service-role key, so the handoff
    # cannot succeed and the tile shows an open-failure message. Its failure is
    # invisible to a health check: every failure path in the app-s /sso handler
    # returns HTTP 200 with an expired-link page. Falsy sso loads /apps/<name>/
    # directly on the first-party session cookie the same-origin proxy exists
    # to preserve.
    #
    # NOTE: the python below runs inside python3 -c with a DOUBLE-quoted shell
    # string, so double quotes, backticks and $ are consumed by bash before
    # python sees them. Keep prose out of that block — a comment with an
    # apostrophe or backtick in it silently corrupts the whole script.
    PAYLOAD="$(python3 -c "
import json
d = json.load(open('${MANIFEST}'))
app = d['apps'][${i}]
tile = app['tile']
payload = {
    'id': app['name'],
    'label': tile['label'],
    'icon': tile['icon'],
    'description': tile['description'],
    'order': tile['order'],
    'componentType': 'ExternalWebApp',
    'config': {'url': '/apps/' + app['name'] + '/', 'sso': False},
}
print(json.dumps(payload))
")"
    curl -fsS -X POST "http://127.0.0.1:${ORCH_PORT}/v1/agents/${PROFILE}/apps" \
      -H "Authorization: Bearer ${ORCH_KEY}" \
      -H 'Content-Type: application/json' \
      -d "${PAYLOAD}" >/dev/null \
      || { echo "error: dashboard tile registration failed for ${NAME}" >&2; exit 1; }
    echo "    tile registered (id=${NAME})"
    # The dashboard reaches a loopback-only app server through the docker0
    # gateway (host.docker.internal). generate-nginx.sh only adds the
    # /apps/<name>/ proxy when <NAME>_BASE_URL is set — without this the tile
    # registers fine and then renders blank.
    BASE_KEY="$(printf '%s' "${NAME}" | tr '[:lower:]-' '[:upper:]_')_BASE_URL"
    BASE_VAL="http://host.docker.internal:${APP_PORT}"
    STACK_DIR="$(dirname "${STACK_ENV_FILE}")"
    STACK_COMPOSE="${STACK_DIR}/docker-compose.yml"
    if [[ ! -f "${STACK_COMPOSE}" ]]; then
      # A missing docker-compose.yml here means the Hermes stack itself was
      # never installed at STACK_DIR (06-install-stack.sh creates it) — not a
      # transient gap to paper over. Fabricating the directory/.env would
      # write an orphan key nothing reads, then fail two steps later with a
      # generic compose error. Warn with the specific cause and skip instead.
      echo "    WARNING: no docker-compose.yml at ${STACK_DIR} — is the Hermes stack installed there? (run 06-install-stack.sh). Skipping ${BASE_KEY} update." >&2
      WARNINGS=$((WARNINGS+1))
    elif ! grep -qF "${BASE_KEY}" "${STACK_COMPOSE}" 2>/dev/null; then
      # The dashboard only receives <NAME>_BASE_URL if docker-compose.yml
      # references it under the dashboard service's `environment:` block. That
      # passthrough was added 2026-07-23 — boxes installed before that (and
      # this branch deliberately does not backfill them) have a compose file
      # that never reads this var, so writing it to .env would be a silent
      # no-op: the tile renders blank with no error anywhere.
      echo "    WARNING: ${STACK_COMPOSE} does not pass ${BASE_KEY} to the dashboard — the tile will render blank. Re-run 06-install-stack.sh to refresh the stack compose file." >&2
      WARNINGS=$((WARNINGS+1))
    elif [[ ! -f "${STACK_ENV_FILE}" ]]; then
      # docker-compose.yml can exist without .env (partial/broken install) —
      # writing an orphan one-line .env here would then fail the recreate
      # below with a generic compose error. Warn with the specific cause.
      echo "    WARNING: no ${STACK_ENV_FILE} — is the Hermes stack installed there? (run 06-install-stack.sh). Skipping ${BASE_KEY} update." >&2
      WARNINGS=$((WARNINGS+1))
    else
      if grep -q "^${BASE_KEY}=" "${STACK_ENV_FILE}" 2>/dev/null; then
        sed -i "s|^${BASE_KEY}=.*|${BASE_KEY}=${BASE_VAL}|" "${STACK_ENV_FILE}"
      else
        echo "${BASE_KEY}=${BASE_VAL}" >> "${STACK_ENV_FILE}"
      fi
      echo "    ${BASE_KEY}=${BASE_VAL} (recreate the dashboard to apply)"
      docker compose -f "${STACK_COMPOSE}" \
        --env-file "${STACK_ENV_FILE}" up -d dashboard >/dev/null 2>&1 \
        || { echo "    WARNING: could not recreate the dashboard — run it yourself to apply ${BASE_KEY}" >&2; WARNINGS=$((WARNINGS+1)); }
    fi
  else
    echo "    (no tile in manifest — skipping)"
  fi

  # Script 23 binds the app to 127.0.0.1 only, while the dashboard container
  # reaches tile apps over the docker0 gateway (host.docker.internal =
  # 172.17.0.1). A missing bridge means the tile 502s while every loopback
  # health check passes — which is exactly how HIA failed on 2026-07-29.
  echo "==> agent-apps [${NAME}] 6/6: app bridge verification"
  if ! curl -fsS --max-time 10 "http://172.17.0.1:${APP_PORT}${HEALTH_PATH}" >/dev/null 2>&1; then
    echo "    WARNING: http://172.17.0.1:${APP_PORT}${HEALTH_PATH} is unreachable — the tile will 502 while the loopback health check passes. Install the bridge: sudo bash ${SCRIPT_DIR}/25-install-app-bridge.sh ${NAME}:${APP_PORT}" >&2
    WARNINGS=$((WARNINGS+1))
  else
    echo "    app bridge reachable"
  fi
  # No caddy step: consolidated apps are served same-origin under
  # /apps/<name>/ through the dashboard's nginx, so no app has a vhost or a
  # hostname of its own.
  echo "    sudo bash ${SCRIPT_DIR}/25-install-app-bridge.sh ${NAME}:${APP_PORT}"
done

echo "==> bridges (root step — run yourself; core-sb is once per BOX):"
echo "    sudo bash ${SCRIPT_DIR}/25-install-app-bridge.sh core-sb:${CORE_KONG_PORT}"

if [[ "${WARNINGS}" -eq 0 ]]; then
  echo "✓ agent-apps for profile '${PROFILE}' installed (bridge steps printed above)"
else
  echo "⚠ agent-apps for profile '${PROFILE}' installed with ${WARNINGS} warning(s) — see above; the app is not fully functional until they are resolved"
fi
