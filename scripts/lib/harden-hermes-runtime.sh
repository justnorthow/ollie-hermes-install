#!/usr/bin/env bash
# Install the whole-process sandbox used by autonomous Hermes services.
#
# The host control account deliberately manages Docker and a small amount of
# host configuration. Hermes must therefore never execute model-selected code
# with that account's ambient privileges. This drop-in contains the gateway
# process tree (terminal, execute_code, MCP subprocesses, plugins, and hooks)
# while leaving trusted operator/Fleet maintenance outside the sandbox.
#
# Usage: harden-hermes-runtime.sh UNIT [UNIT...]
# Env: SYSTEMD_USER_DIR (default ~/.config/systemd/user)
#      HARDEN_RUNTIME_NO_RELOAD=1 (tests/staging only; also skips restart)
set -euo pipefail

UNIT_DIR="${SYSTEMD_USER_DIR:-$HOME/.config/systemd/user}"

if [[ "$#" -eq 0 ]]; then
  echo "harden-hermes-runtime: at least one gateway unit is required" >&2
  exit 2
fi

UNITS=("$@")
BACKUPS=()
HAD_ORIGINAL=()

restore_dropins() {
  local i unit conf
  for i in "${!UNITS[@]}"; do
    unit="${UNITS[$i]}"
    conf="${UNIT_DIR}/${unit}.d/20-ollie-runtime-sandbox.conf"
    if [[ "${HAD_ORIGINAL[$i]:-0}" == "1" ]]; then
      mv -f "${BACKUPS[$i]}" "${conf}"
    else
      rm -f "${conf}" "${BACKUPS[$i]:-}"
    fi
  done
}

cleanup_backups() {
  local backup
  for backup in "${BACKUPS[@]}"; do rm -f "${backup}"; done
}

for unit in "${UNITS[@]}"; do
  if [[ ! "${unit}" =~ ^hermes-(gateway|dashboard)(-[A-Za-z0-9_-]+)?\.service$ ]]; then
    echo "harden-hermes-runtime: refusing non-Hermes-runtime unit '${unit}'" >&2
    exit 2
  fi

  if [[ ! -f "${UNIT_DIR}/${unit}" ]]; then
    echo "harden-hermes-runtime: Hermes unit not found: ${UNIT_DIR}/${unit}" >&2
    exit 1
  fi

  dropdir="${UNIT_DIR}/${unit}.d"
  mkdir -p "${dropdir}"
  conf="${dropdir}/20-ollie-runtime-sandbox.conf"
  backup="${conf}.pre-hardening.$$"
  BACKUPS+=("${backup}")
  if [[ -f "${conf}" ]]; then
    cp -p "${conf}" "${backup}"
    HAD_ORIGINAL+=("1")
  else
    HAD_ORIGINAL+=("0")
  fi

  cat > "${conf}" <<'EOF'
[Service]
# Whole-process containment: applies to the gateway and every child it spawns.
NoNewPrivileges=yes
PrivateUsers=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=tmpfs

# Expose only Hermes state, its user-local launcher, and optional model caches.
BindPaths=%h/.hermes
BindPaths=-%h/.cache
BindReadOnlyPaths=-%h/.local/bin

# The control account may be in docker/sudo for trusted maintenance, but the
# autonomous process tree cannot reach either the Docker API or user-manager
# bus to launch a fresh unsandboxed process.
InaccessiblePaths=-/var/run/docker.sock
InaccessiblePaths=-/run/docker.sock
InaccessiblePaths=-/run/user/%U/bus
InaccessiblePaths=-/run/user/%U/systemd

ProtectKernelTunables=yes
ProtectControlGroups=yes
ProtectProc=invisible
ProcSubset=pid
RestrictNamespaces=yes
RestrictSUIDSGID=yes
RestrictRealtime=yes
LockPersonality=yes
RemoveIPC=yes
AmbientCapabilities=
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
SystemCallArchitectures=native
UMask=0077

# Deliberately omitted for user services: PrivateDevices, ProtectKernelModules,
# ProtectKernelLogs, ProtectClock, ProtectHostname, and CapabilityBoundingSet.
# Unprivileged systemd user managers on supported VPS hosts cannot apply these
# directives (status=218/CAPABILITIES). NoNewPrivileges plus the filesystem,
# socket, namespace, and user-manager boundaries above enforce the relevant
# privilege boundary without making the runtime fail closed at startup.
EOF
  chmod 0600 "${conf}"
  echo "harden-hermes-runtime: sandboxed ${unit}"
done

if [[ "${HARDEN_RUNTIME_NO_RELOAD:-0}" != "1" ]]; then
  if ! systemctl --user daemon-reload; then
    restore_dropins
    systemctl --user daemon-reload || true
    cleanup_backups
    echo "harden-hermes-runtime: daemon-reload failed; restored previous drop-ins" >&2
    exit 1
  fi

  failed_unit=""
  for unit in "${UNITS[@]}"; do
    # `gateway install` normally starts immediately. Reloading does not alter an
    # already-running process, so restart it now or the new boundary would not
    # exist until the next reboot.
    if ! systemctl --user try-restart "${unit}"; then
      failed_unit="${unit}"
      break
    fi
  done

  if [[ -n "${failed_unit}" ]]; then
    restore_dropins
    systemctl --user daemon-reload || true
    systemctl --user reset-failed "${UNITS[@]}" || true
    for unit in "${UNITS[@]}"; do systemctl --user try-restart "${unit}" || true; done
    cleanup_backups
    echo "harden-hermes-runtime: ${failed_unit} failed after hardening; restored previous drop-ins" >&2
    exit 1
  fi
fi

cleanup_backups
