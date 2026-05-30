#!/usr/bin/env bash
# 02-install-hermes.sh — install Hermes Agent natively for the default profile.
#
# Run as: ubuntu (NOT root) — Hermes installs to $HOME/.hermes
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
# After this script: run `hermes login --provider <provider>` to set up your LLM auth.
# For Codex/ChatGPT: hermes login --provider openai-codex

set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  echo "error: run as the ubuntu user, not root (Hermes installs to \$HOME/.hermes)" >&2
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

sleep 3
echo
echo "==> verification"
systemctl --user is-active hermes-gateway && echo "    hermes-gateway: active"
systemctl --user is-active hermes-dashboard && echo "    hermes-dashboard: active"
curl -s -o /dev/null -w "    dashboard http :${DASHBOARD_PORT} → %{http_code} (200 = good)\n" "http://localhost:${DASHBOARD_PORT}/"
curl -s -o /dev/null -w "    gateway   http :${GATEWAY_PORT} → %{http_code} (405 = good, GET wrong method)\n" "http://localhost:${GATEWAY_PORT}/v1/runs"

echo
echo "✓ Hermes installed and running."
echo
echo "NEXT — authenticate to your LLM provider:"
echo "    hermes login --provider openai-codex   # for Codex/ChatGPT OAuth"
echo "  OR set an API key in ~/.hermes/.env (e.g. OPENROUTER_API_KEY=...)"
echo
echo "Then restart the gateway so it picks up the new auth:"
echo "    systemctl --user restart hermes-gateway"
