#!/usr/bin/env bash
# 02-install-hermes.sh — install Hermes Agent natively for the default profile.
#
# Run as: the service user (ollie by default; NOT root) — Hermes installs to $HOME/.hermes
# Idempotent: safe to re-run.
#
# What it does:
#   1. Installs Hermes via the upstream install script (skipped if already present)
#   2. Writes API_SERVER_* config to ~/.hermes/.env (so the dashboard can reach the gateway)
#   3. Generates a random API_SERVER_KEY if not already set
#   4. Sets gateway.port = 8642 in config.yaml
#   5. Installs the hermes-gateway systemd --user service via `hermes gateway install`
#   6. Installs a hardened hermes-dashboard systemd --user service (Restart=always + burst guard)
#
# After this script: set up your LLM auth (the old `hermes login` was removed).
# For Codex/ChatGPT OAuth on a headless box:
#   hermes auth add openai-codex --type oauth --no-browser --manual-paste

set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  echo "error: run as the service user, not root (Hermes installs to \$HOME/.hermes)" >&2
  exit 1
fi

GATEWAY_PORT="${GATEWAY_PORT:-8642}"
DASHBOARD_PORT="${DASHBOARD_PORT:-9119}"
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
HERMES_ENV="${HOME}/.hermes/.env"

echo "==> step 1: install Hermes Agent (if not already present)"
if [[ ! -x "${HOME}/.local/bin/hermes" ]]; then
  curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash
  # The installer adds ~/.local/bin to PATH via .bashrc; load it for this script run.
  export PATH="${HOME}/.local/bin:${PATH}"
else
  echo "    Hermes already installed at ${HOME}/.local/bin/hermes — skipping install"
  export PATH="${HOME}/.local/bin:${PATH}"
fi
hermes --version

echo "==> step 1b: symlink hermes into /usr/local/bin so it resolves in EVERY context"
# The upstream installer only puts ~/.local/bin on PATH via .bashrc/.profile, which
# load ONLY in interactive login shells. That leaves `hermes` missing under sudo,
# cron, non-interactive scripts, and even the same shell right after install (before
# re-login) — the "hermes: command not found" symptom. It also causes a confusing
# "No module named 'dotenv'" if you work around it by invoking a non-venv python.
# /usr/local/bin is already on every default PATH (incl. sudo secure_path and cron),
# and the wrapper it points to execs the venv's python — so hermes AND its bundled
# deps (python-dotenv, etc.) are always available. Idempotent.
if [[ -x "${HOME}/.local/bin/hermes" ]]; then
  sudo ln -sfn "${HOME}/.local/bin/hermes" /usr/local/bin/hermes
  echo "    linked /usr/local/bin/hermes -> ${HOME}/.local/bin/hermes"
else
  echo "    warning: ${HOME}/.local/bin/hermes not found — upstream install may have failed" >&2
fi

echo "==> step 2: ensure ~/.hermes/.env exists"
mkdir -p "${HOME}/.hermes"
touch "${HERMES_ENV}"
chmod 600 "${HERMES_ENV}"

echo "==> step 3: API_SERVER_KEY (random hex if not already set)"
if ! grep -q '^API_SERVER_KEY=' "${HERMES_ENV}"; then
  API_KEY="$(openssl rand -hex 32)"
  echo "API_SERVER_KEY=${API_KEY}" >> "${HERMES_ENV}"
  echo "    generated and saved"
else
  echo "    already present — keeping existing value"
fi

echo "==> step 4: API_SERVER_* vars (idempotent — only adds what's missing)"
ensure_env() {
  local key="$1" value="$2"
  if ! grep -q "^${key}=" "${HERMES_ENV}"; then
    echo "${key}=${value}" >> "${HERMES_ENV}"
    echo "    set ${key}"
  fi
}
ensure_env API_SERVER_ENABLED true
ensure_env API_SERVER_HOST 0.0.0.0
ensure_env API_SERVER_PORT "${GATEWAY_PORT}"
ensure_env API_SERVER_CORS_ORIGINS '*'

echo "==> step 5: hermes config set gateway.port = ${GATEWAY_PORT}"
hermes config set gateway.port "${GATEWAY_PORT}" >/dev/null

echo "==> step 6: install hermes-gateway systemd --user service"
# `gateway install` prompts to start now and at boot. Pipe 'y' answers to both.
printf 'y\ny\ny\ny\ny\n' | hermes gateway install 2>&1 | tail -5

echo "==> step 7: install hermes-dashboard systemd --user service (hardened)"
mkdir -p "${SYSTEMD_USER_DIR}"
cat > "${SYSTEMD_USER_DIR}/hermes-dashboard.service" <<EOF
[Unit]
Description=Hermes Agent Dashboard (default profile)
After=network.target

[Service]
Type=simple
Environment=PATH=%h/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=%h/.local/bin/hermes dashboard --host 0.0.0.0 --port ${DASHBOARD_PORT} --insecure --no-open
# Restart=always (not on-failure) so the dashboard comes back even when
# 'hermes update' SIGTERMs it (a clean exit, status 0).
Restart=always
RestartSec=5
# Bound the restart loop so a genuinely broken dashboard surfaces the failure.
StartLimitBurst=10
StartLimitIntervalSec=60

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now hermes-dashboard

echo
echo "==> verification (waiting for ports to bind — dashboard's first start needs ~5-10s)"
# Don't let set -e abort the script if a curl probe fails — the probes are informational.
set +e
echo "    hermes-gateway:   $(systemctl --user is-active hermes-gateway)"
echo "    hermes-dashboard: $(systemctl --user is-active hermes-dashboard)"
# Poll the dashboard until it answers (max 30s — first-start asset build can be slow)
for i in $(seq 1 15); do
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 3 "http://localhost:${DASHBOARD_PORT}/" || true)
  if [[ "${code}" == "200" ]]; then
    echo "    dashboard http :${DASHBOARD_PORT} → 200 ✓"
    break
  fi
  [[ "${i}" == "15" ]] && echo "    dashboard http :${DASHBOARD_PORT} → ${code:-none} (not 200 after 30s — check 'journalctl --user -u hermes-dashboard')"
  sleep 2
done
# Gateway listens for POST; any HTTP response (including 404/405) means it's alive.
code=$(curl -s -o /dev/null -w '%{http_code}' -m 5 "http://localhost:${GATEWAY_PORT}/v1/runs" || true)
case "${code}" in
  ''|000) echo "    gateway   http :${GATEWAY_PORT} → no response (check 'systemctl --user status hermes-gateway')" ;;
  *) echo "    gateway   http :${GATEWAY_PORT} → ${code} ✓ (any HTTP response = listening)" ;;
esac
set -e

echo
echo "✓ Hermes installed and running."
echo
echo "NEXT — authenticate to your LLM provider (the old 'hermes login' was removed):"
echo "    # Codex/ChatGPT OAuth on a headless box (this VPS): prints a URL to open"
echo "    # on your laptop, then paste the failed localhost callback URL back."
echo "    hermes auth add openai-codex --type oauth --no-browser --manual-paste"
echo "  OR set an API key in ~/.hermes/.env (e.g. OPENROUTER_API_KEY=...)"
echo
echo "Then restart the gateway so it picks up the new auth:"
echo "    systemctl --user restart hermes-gateway"
echo "Check it with:  hermes auth status openai-codex"
