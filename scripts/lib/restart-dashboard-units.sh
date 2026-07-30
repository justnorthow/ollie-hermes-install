#!/usr/bin/env bash
# restart-dashboard-units.sh — restart EVERY Hermes dashboard unit.
#
# `hermes update` replaces the Hermes source tree in place but leaves the already
# running dashboard processes alone. Hermes imports parts of hermes_cli LAZILY, at
# request time, so a long-running dashboard then imports a fresh module which
# resolves a name against a STALE sibling still cached in that process's
# sys.modules, and dies with e.g.
#
#   ImportError: cannot import name 'read_session_provider'
#                from 'hermes_cli.dashboard_auth.cookies'
#
# on EVERY route — /, /api/files, /api/status, /api/sessions all return 500.
#
# Measured on the sandbox 2026-07-30: after an update, three of four agents served
# 500s from processes started five days earlier. The symbol WAS present in the new
# source (cookies.py:284), so grepping the tree to "verify" the fix is misleading —
# the mismatch lives in the running process, not on disk.
#
# heal-dashboard-units.sh does NOT cover this: it deliberately skips units that are
# already active, and these are active — just wrong.
#
# Restarts are sequential and unconditional. Each dashboard rebuilds its SPA on
# start (tens of seconds), and restarting them all at once starves the box.
set -uo pipefail
UNIT_DIR="${SYSTEMD_USER_DIR:-$HOME/.config/systemd/user}"

count=0
failed=0
shopt -s nullglob
for unit in "${UNIT_DIR}"/hermes-dashboard*.service; do
  name="$(basename "${unit}")"
  count=$((count + 1))
  # Clear any prior failure state first, or a unit sitting in `failed` after
  # hitting its start-limit refuses to restart at all.
  systemctl --user reset-failed "${name}" 2>/dev/null || true
  if systemctl --user restart "${name}"; then
    echo "restart-dashboard-units: restarted ${name}"
  else
    failed=$((failed + 1))
    echo "restart-dashboard-units: WARNING restart failed for ${name} — it may still be serving stale code; check: systemctl --user status ${name}" >&2
  fi
done

# Exit 0 even when a unit failed: one wedged dashboard must not abort the rest of
# the update run, and check-box-config.sh reports the dead listener fail-closed.
echo "restart-dashboard-units: done (units=${count}, failed=${failed})"
