#!/usr/bin/env bash
# 08-install-souls.sh — provision agent personas (SOUL.md).
#
# Run as: the service user (ollie by default; NOT root)
# Idempotent: safe to re-run. Marker-gated so it NEVER clobbers a SOUL.md you
# (or the default agent's onboarding) have already customized.
#
# What it does:
#   1. Default agent: installs the first-run onboarding bootstrap to
#      ~/.hermes/SOUL.md, so the default agent interviews you about its identity
#      on first contact, then rewrites the file itself.
#   2. Preset agents: for each ~/.hermes/profiles/<name>/ that has a matching
#      templates/souls/<name>.md, installs that preset persona.
#
# A SOUL.md is REPLACEABLE only if it is missing, still the stock Hermes template
# (effectively empty), or still carries one of our markers
# (OLLIE-SOUL-BOOTSTRAP / OLLIE-PRESET-SOUL). A customized persona (real content,
# no marker) is left untouched.

set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  echo "error: run as the service user, not root" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOULS_SRC="${SCRIPT_DIR}/../templates/souls"
HERMES_HOME="${HOME}/.hermes"
PROFILES_DIR="${HERMES_HOME}/profiles"

if [[ ! -f "${SOULS_SRC}/default-onboarding.md" ]]; then
  echo "error: vendored souls not found at ${SOULS_SRC}" >&2
  exit 1
fi

# Return 0 (replaceable) if the target SOUL.md is missing, effectively empty
# (stock template — only comments/headers/blanks), or still carries a marker.
# Return 1 (keep) if it holds a real, customized persona.
soul_is_replaceable() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  if grep -qE 'OLLIE-SOUL-BOOTSTRAP|OLLIE-PRESET-SOUL' "$f"; then
    return 0
  fi
  # The stock Hermes default persona that `hermes profile create` writes verbatim
  # into a new profile's SOUL.md — treat as unconfigured (replaceable by a preset).
  if grep -q 'an intelligent AI assistant created by Nous Research' "$f"; then
    return 0
  fi
  local meaningful
  meaningful="$(awk '
    {
      s = $0; out = ""
      while (1) {
        if (in_block) {
          p = index(s, "-->")
          if (p == 0) { s = ""; break }
          s = substr(s, p + 3); in_block = 0
        } else {
          p = index(s, "<!--")
          if (p == 0) { out = out s; break }
          out = out substr(s, 1, p - 1)
          s = substr(s, p + 4); in_block = 1
        }
      }
      print out
    }
  ' "$f" | sed -E 's/^[[:space:]]*#.*$//' | grep -vE '^[[:space:]]*$' || true)"
  [[ -z "${meaningful}" ]] && return 0
  return 1
}

install_soul() {  # $1=src  $2=dest  $3=label
  local src="$1" dest="$2" label="$3"
  [[ -f "$src" ]] || return 0
  mkdir -p "$(dirname "$dest")"
  if soul_is_replaceable "$dest"; then
    cp "$src" "$dest"
    chmod 644 "$dest"
    printf '  %-24s installed\n' "$label"
  else
    printf '  %-24s skipped (customized persona present)\n' "$label"
  fi
}

echo "==> default agent: ~/.hermes/SOUL.md"
install_soul "${SOULS_SRC}/default-onboarding.md" "${HERMES_HOME}/SOUL.md" "default (onboarding)"

echo "==> preset agents: per-profile SOUL.md"
shopt -s nullglob
found_profile=0
for prof_dir in "${PROFILES_DIR}"/*/; do
  found_profile=1
  name="$(basename "${prof_dir}")"
  preset="${SOULS_SRC}/${name}.md"
  if [[ -f "${preset}" ]]; then
    install_soul "${preset}" "${prof_dir}SOUL.md" "${name} (preset)"
  else
    printf '  %-24s no preset in templates/souls — left as-is\n' "${name}"
  fi
done
[[ "${found_profile}" -eq 0 ]] && echo "  (no profiles installed)"

echo
echo "✓ SOUL provisioning complete."
echo "  The default agent runs its first-run identity setup on the next NEW chat,"
echo "  then rewrites its own SOUL.md. Re-run after adding a profile (03) or after"
echo "  editing a preset in templates/souls/."
