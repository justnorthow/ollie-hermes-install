#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/assert.sh"

setup_fixture() {
  local d; d="$(mktemp -d)"
  printf 'API_SERVER_PORT=8642\nAPI_SERVER_KEY=k\n' > "$d/hermes.env"
  mkdir -p "$d/profiles/marketing-agent" "$d/units"
  printf 'API_SERVER_PORT=8643\n' > "$d/profiles/marketing-agent/.env"
  printf '[Service]\nExecStart=%%h/.local/bin/hermes -p marketing-agent dashboard --host 127.0.0.1 --port 9121 --no-open\n' \
    > "$d/units/hermes-dashboard-marketing-agent.service"
  # profile with missing unit → must be skipped
  mkdir -p "$d/profiles/broken"
  printf 'API_SERVER_PORT=8650\n' > "$d/profiles/broken/.env"
  echo "$d"
}

test_detects_default_and_profile() {
  local d out; d="$(setup_fixture)"
  out="$(HERMES_ENV_FILE="$d/hermes.env" PROFILES_DIR="$d/profiles" SYSTEMD_USER_DIR="$d/units" \
    bash -c ". '$HERE/../scripts/lib/detect-agents.sh' && detect_agents" 2>/dev/null)"
  assert_eq "detected JSON" "$out" '[{"id":"default","gw":8642,"dash":9119},{"id":"marketing-agent","gw":8643,"dash":9121}]'
}

test_idempotent() {
  local d a b; d="$(setup_fixture)"
  a="$(HERMES_ENV_FILE="$d/hermes.env" PROFILES_DIR="$d/profiles" SYSTEMD_USER_DIR="$d/units" \
    bash -c ". '$HERE/../scripts/lib/detect-agents.sh' && detect_agents" 2>/dev/null)"
  b="$(HERMES_ENV_FILE="$d/hermes.env" PROFILES_DIR="$d/profiles" SYSTEMD_USER_DIR="$d/units" \
    bash -c ". '$HERE/../scripts/lib/detect-agents.sh' && detect_agents" 2>/dev/null)"
  assert_eq "two runs identical" "$a" "$b"
}

test_empty_profiles() {
  local d out; d="$(mktemp -d)"
  printf 'API_SERVER_PORT=8642\nAPI_SERVER_KEY=k\n' > "$d/hermes.env"
  mkdir -p "$d/profiles" "$d/units"
  out="$(HERMES_ENV_FILE="$d/hermes.env" PROFILES_DIR="$d/profiles" SYSTEMD_USER_DIR="$d/units" \
    bash -c ". '$HERE/../scripts/lib/detect-agents.sh' && detect_agents" 2>/dev/null)"
  assert_eq "empty profiles returns default only" "$out" '[{"id":"default","gw":8642,"dash":9119}]'
}

test_detects_default_and_profile
test_idempotent
test_empty_profiles
finish
