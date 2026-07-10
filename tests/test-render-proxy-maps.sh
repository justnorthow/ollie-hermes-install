#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/assert.sh"
RENDER="$HERE/../scripts/lib/render-proxy-maps.py"
DETECTED='[{"id":"default","gw":8642,"dash":9119},{"id":"marketing-agent","gw":8643,"dash":9121}]'

test_fresh_render() {
  local env; env="$(mktemp)"
  printf 'ORCHESTRATOR_KEY=x\n' > "$env"
  printf '%s' "$DETECTED" | ORCH_ENV="$env" python3 "$RENDER" >/dev/null
  assert_eq "gateway map" \
    "$(grep '^HERMES_GATEWAY_URLS=' "$env" | cut -d= -f2-)" \
    '{"default": "http://127.0.0.1:8642", "marketing-agent": "http://127.0.0.1:8643"}'
  assert_eq "dashboard map" \
    "$(grep '^HERMES_DASHBOARD_URLS=' "$env" | cut -d= -f2-)" \
    '{"default": "http://127.0.0.1:9119", "marketing-agent": "http://127.0.0.1:9121"}'
  assert_count "no duplicate gateway key" "$env" HERMES_GATEWAY_URLS 1
  assert_eq "other keys intact" "$(grep -c '^ORCHESTRATOR_KEY=x$' "$env")" "1"
}

test_covering_custom_value_kept() {
  local env; env="$(mktemp)"
  printf 'HERMES_GATEWAY_URLS={"default": "http://127.0.0.1:8642", "marketing-agent": "http://127.0.0.1:8643", "extra": "http://127.0.0.1:9999"}\n' > "$env"
  local before; before="$(grep '^HERMES_GATEWAY_URLS=' "$env")"
  printf '%s' "$DETECTED" | ORCH_ENV="$env" python3 "$RENDER" >/dev/null
  assert_eq "superset value kept byte-identical" "$(grep '^HERMES_GATEWAY_URLS=' "$env")" "$before"
}

test_stale_partial_map_regenerated() {
  local env; env="$(mktemp)"
  printf 'HERMES_GATEWAY_URLS={"default": "http://127.0.0.1:8642"}\n' > "$env"
  printf '%s' "$DETECTED" | ORCH_ENV="$env" python3 "$RENDER" >/dev/null
  assert_eq "stale map regenerated" \
    "$(grep '^HERMES_GATEWAY_URLS=' "$env" | cut -d= -f2-)" \
    '{"default": "http://127.0.0.1:8642", "marketing-agent": "http://127.0.0.1:8643"}'
}

test_idempotent() {
  local env; env="$(mktemp)"
  printf '%s' "$DETECTED" | ORCH_ENV="$env" python3 "$RENDER" >/dev/null
  local a; a="$(cat "$env")"
  printf '%s' "$DETECTED" | ORCH_ENV="$env" python3 "$RENDER" >/dev/null
  assert_eq "second run zero drift" "$(cat "$env")" "$a"
}

test_fresh_render
test_covering_custom_value_kept
test_stale_partial_map_regenerated
test_idempotent
finish
