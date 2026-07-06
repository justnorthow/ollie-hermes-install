#!/usr/bin/env bash
# Heal stale per-profile Hermes dashboard systemd units. An OLD installer wrote
# ExecStart '--host 0.0.0.0', which current Hermes REFUSES to bind without an auth
# provider ("Refusing to bind dashboard to 0.0.0.0") -> crash-loop. Rewrite any such
# unit to '--host 127.0.0.1' (the canonical value current install code writes),
# reload, and restart any dashboard unit that isn't running. Idempotent: a unit
# already on 127.0.0.1 is left byte-identical. Run as the service user.
set -uo pipefail
UNIT_DIR="${SYSTEMD_USER_DIR:-$HOME/.config/systemd/user}"
changed=0
shopt -s nullglob
for unit in "$UNIT_DIR"/hermes-dashboard*.service; do
  if grep -qE '^ExecStart=.*--host 0\.0\.0\.0' "$unit"; then
    sed -i 's/--host 0\.0\.0\.0/--host 127.0.0.1/g' "$unit"
    echo "healed $(basename "$unit"): --host 0.0.0.0 -> 127.0.0.1"
    changed=1
  fi
done
# Tests set HEAL_DASHBOARD_NO_RESTART=1 (no systemd --user in CI). Real runs reload
# + restart any dashboard unit that isn't active (covers a just-healed crash-looper).
if [ "${HEAL_DASHBOARD_NO_RESTART:-}" = 1 ]; then
  echo "heal-dashboard-units: rewrite-only (changed=$changed)"
  exit 0
fi
[ "$changed" = 1 ] && systemctl --user daemon-reload
for unit in "$UNIT_DIR"/hermes-dashboard*.service; do
  name="$(basename "$unit")"
  systemctl --user is-active --quiet "$name" && continue
  systemctl --user reset-failed "$name" 2>/dev/null || true
  systemctl --user restart "$name" 2>/dev/null || true
  echo "restarted $name"
done
echo "heal-dashboard-units: done (changed=$changed)"
