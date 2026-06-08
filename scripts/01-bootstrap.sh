#!/usr/bin/env bash
# 01-bootstrap.sh — prepare a fresh Linux host for the Ollie + Hermes stack.
#
# Run as: root, OR any sudo-capable user (the script self-elevates via sudo).
# Idempotent: safe to re-run.
#
# What it does:
#   1. Ensures root privileges (self-elevates via sudo if needed)
#   2. Creates a dedicated service user (default: ollie) with passwordless sudo
#   3. Seeds that user's SSH authorized_keys from whoever ran the install
#      (operator -> root -> existing, deduped) so you never lose access to it
#   4. Enables systemd linger so user services survive logout / reboot
#   5. Installs prereqs: docker, compose plugin, python3, git, jq, sqlite3, etc.
#   6. Adds the service user to the docker group
#
# The whole stack derives paths from $HOME (Hermes profile dirs, systemd %h unit
# templates, orchestrator src/config.py), so the service-user name is freely
# configurable — it does NOT have to be "ubuntu".
#
# Config (all optional env vars):
#   TARGET_USER=ollie     # service user to create/use
#   USE_CURRENT_USER=1    # use the invoking sudo user instead of a dedicated one
#   NO_SELF_ELEVATE=1     # don't auto-sudo; just instruct and exit if not root
#
# Invoke as a file (needed for self-elevation): bash scripts/01-bootstrap.sh
# After this script: ssh <service-user>@<host> (or `sudo -iu <service-user>`)
# then run 02-install-hermes.sh

set -euo pipefail

DEFAULT_USER="ollie"
TARGET_USER="${TARGET_USER:-${DEFAULT_USER}}"

# Resolve the operator (the human who launched this) BEFORE any elevation:
# explicit OLLIE_OPERATOR (preserved across our sudo re-exec) -> SUDO_USER
# (set when invoked via sudo) -> current login name.
OPERATOR="${OLLIE_OPERATOR:-${SUDO_USER:-$(id -un)}}"

# --- Privilege guard: be root, or self-elevate via sudo ---
if [[ "$(id -u)" -ne 0 ]]; then
  if [[ "${NO_SELF_ELEVATE:-0}" == "1" ]]; then
    echo "error: must run as root. Re-run with:  sudo bash $0" >&2
    exit 1
  fi
  if command -v sudo >/dev/null 2>&1 && sudo -v; then
    echo "==> not root — re-executing under sudo (operator: ${OPERATOR})"
    exec sudo OLLIE_OPERATOR="${OPERATOR}" NO_SELF_ELEVATE=1 \
         TARGET_USER="${TARGET_USER}" USE_CURRENT_USER="${USE_CURRENT_USER:-}" \
         bash "$0" "$@"
  fi
  echo "error: this script needs root, but you are '${OPERATOR}' without usable sudo." >&2
  echo "       Log in as root and re-run, or have an admin grant you sudo, then:" >&2
  echo "       sudo bash $0" >&2
  exit 1
fi

# --- uid 0 from here down; OPERATOR names the human who launched it ---

if [[ "${USE_CURRENT_USER:-0}" == "1" ]]; then
  if [[ "${OPERATOR}" == "root" || -z "${OPERATOR}" ]]; then
    echo "error: USE_CURRENT_USER=1 but operator is root — set TARGET_USER instead." >&2
    exit 1
  fi
  TARGET_USER="${OPERATOR}"
fi

USER_PREEXISTING=false
if id -u "${TARGET_USER}" >/dev/null 2>&1; then
  USER_PREEXISTING=true
fi
echo "==> service user: ${TARGET_USER} (operator: ${OPERATOR}, pre-existing: ${USER_PREEXISTING})"

echo "==> ensuring ${TARGET_USER} exists with sudo + docker group ready"
if [[ "${USER_PREEXISTING}" == "false" ]]; then
  useradd -m -s /bin/bash "${TARGET_USER}"
fi
usermod -aG sudo "${TARGET_USER}"

echo "==> granting passwordless sudo to ${TARGET_USER} (needed for unattended 02-07)"
if [[ "${USER_PREEXISTING}" == "true" && "${TARGET_USER}" != "${DEFAULT_USER}" ]]; then
  echo "    WARNING: ${TARGET_USER} is a pre-existing account; this grants it passwordless" >&2
  echo "             sudo. Review /etc/sudoers.d/${TARGET_USER} afterward if undesired." >&2
fi
echo "${TARGET_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${TARGET_USER}"
chmod 0440 "/etc/sudoers.d/${TARGET_USER}"

echo "==> seeding ${TARGET_USER} authorized_keys from operator -> root -> existing (deduped)"
USER_HOME="$(getent passwd "${TARGET_USER}" | cut -d: -f6)"
USER_AK="${USER_HOME}/.ssh/authorized_keys"
mkdir -p "${USER_HOME}/.ssh"
touch "${USER_AK}"
if [[ "${OPERATOR}" == "root" ]]; then
  OP_AK="/root/.ssh/authorized_keys"
else
  OP_AK="$(getent passwd "${OPERATOR}" | cut -d: -f6)/.ssh/authorized_keys"
fi
# Merge, never overwrite: a plain cp could clobber a key added directly to the
# service account and lock you out on re-run. Order-preserving, blank+dup safe.
{
  [[ -f "${OP_AK}" ]] && cat "${OP_AK}"
  [[ -f /root/.ssh/authorized_keys ]] && cat /root/.ssh/authorized_keys
  cat "${USER_AK}"
} 2>/dev/null | awk 'NF && !seen[$0]++' > "${USER_AK}.tmp"
mv "${USER_AK}.tmp" "${USER_AK}"
chown -R "${TARGET_USER}:$(id -gn "${TARGET_USER}")" "${USER_HOME}/.ssh"
chmod 700 "${USER_HOME}/.ssh"
chmod 600 "${USER_AK}"
if [[ ! -s "${USER_AK}" ]]; then
  echo "    WARNING: no SSH keys found for operator or root — ${TARGET_USER} has NO" >&2
  echo "             authorized_keys. Add one, or use 'sudo -iu ${TARGET_USER}'." >&2
fi

echo "==> enabling systemd --user linger for ${TARGET_USER} (services survive logout)"
loginctl enable-linger "${TARGET_USER}"

echo "==> apt update + base prereqs"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
  ca-certificates curl gnupg lsb-release \
  git python3 python3-venv python3-pip \
  jq sqlite3 sed tar rsync openssh-client \
  >/dev/null

echo "==> installing Docker CE + Compose plugin"
install -m 0755 -d /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null
  chmod a+r /etc/apt/keyrings/docker.gpg
fi
ARCH="$(dpkg --print-architecture)"
CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -qq
apt-get install -y -qq \
  docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin \
  >/dev/null

echo "==> adding ${TARGET_USER} to docker group"
usermod -aG docker "${TARGET_USER}"

echo
echo "==> verification"
sudo -u "${TARGET_USER}" id
docker --version
docker compose version
python3 --version
git --version

echo
echo "✓ bootstrap complete."
echo
echo "  service user : ${TARGET_USER}"
echo "  reach it     : ssh ${TARGET_USER}@<host>   (or: sudo -iu ${TARGET_USER})"
echo "  NOTE: docker-group membership needs a FRESH login before step 06."
echo "next: become ${TARGET_USER} and run scripts/02-install-hermes.sh"
