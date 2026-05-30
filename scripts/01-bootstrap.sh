#!/usr/bin/env bash
# 01-bootstrap.sh — prepare a fresh Linux host for the Ollie + Hermes stack.
#
# Run as: root (on a fresh VM)
# Idempotent: safe to re-run.
#
# What it does:
#   1. Creates an `ubuntu` user with passwordless sudo
#   2. Copies root's SSH authorized_keys to the ubuntu user
#   3. Enables systemd linger so user services survive logout / reboot
#   4. Installs prereqs: docker, docker-compose-plugin, python3, git, jq, sqlite3, etc.
#   5. Adds the ubuntu user to the docker group
#
# Why an `ubuntu` user even on non-AWS boxes:
#   The rest of the stack (Hermes profile dirs, systemd unit %h templates,
#   orchestrator paths) assumes /home/ubuntu/ as HOME. Standardizing the
#   user across cloud providers keeps every script reusable.
#
# After this script: ssh ubuntu@<host> and proceed with 02-install-hermes.sh

set -euo pipefail

TARGET_USER="${TARGET_USER:-ubuntu}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "error: must run as root (try: sudo $0)" >&2
  exit 1
fi

echo "==> ensuring ${TARGET_USER} user exists with sudo + docker group ready"
if ! id -u "${TARGET_USER}" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "${TARGET_USER}"
fi
usermod -aG sudo "${TARGET_USER}"
echo "${TARGET_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${TARGET_USER}"
chmod 0440 "/etc/sudoers.d/${TARGET_USER}"

echo "==> copying root SSH authorized_keys to ${TARGET_USER}"
USER_HOME="/home/${TARGET_USER}"
mkdir -p "${USER_HOME}/.ssh"
if [[ -f /root/.ssh/authorized_keys ]]; then
  cp /root/.ssh/authorized_keys "${USER_HOME}/.ssh/"
fi
chown -R "${TARGET_USER}:${TARGET_USER}" "${USER_HOME}/.ssh"
chmod 700 "${USER_HOME}/.ssh"
chmod 600 "${USER_HOME}/.ssh/authorized_keys" 2>/dev/null || true

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
echo "next: ssh ${TARGET_USER}@<host> and run scripts/02-install-hermes.sh"
