#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/assert.sh"
MERGE="$HERE/../scripts/lib/merge-agents-json.py"
PY="$(command -v python3 || command -v python)"
DETECTED='[{"id":"default","gw":8642,"dash":9119},{"id":"marketing-agent","gw":8643,"dash":9121}]'
field() { "$PY" -c 'import sys,json; a={x["id"]:x for x in json.load(sys.stdin)}; print(a[sys.argv[1]].get(sys.argv[2]))' "$1" "$2"; }

test_preserves_scope_and_manager_visible() {
  local existing='[{"id":"default","name":"Ollie","scope":"user","color":"#888"},{"id":"marketing-agent","name":"Olivia","manager_visible":true,"model":"gpt-5.5"}]'
  local out; out="$(EXISTING_AGENTS="$existing" DETECTED="$DETECTED" "$PY" "$MERGE")"
  assert_eq "default keeps scope:user"        "$(printf '%s' "$out" | field default scope)" "user"
  assert_eq "marketing keeps manager_visible" "$(printf '%s' "$out" | field marketing-agent manager_visible)" "True"
  assert_eq "color still preserved"           "$(printf '%s' "$out" | field default color)" "#888"
  assert_eq "model still preserved"           "$(printf '%s' "$out" | field marketing-agent model)" "gpt-5.5"
}
test_absent_scope_stays_absent() {
  local existing='[{"id":"default","name":"Ollie"}]'
  local out; out="$(EXISTING_AGENTS="$existing" DETECTED="$DETECTED" "$PY" "$MERGE")"
  assert_eq "no spurious scope key" "$(printf '%s' "$out" | "$PY" -c 'import sys,json; a={x["id"]:x for x in json.load(sys.stdin)}; print("scope" in a["default"])')" "False"
}
test_urls_refreshed_from_detected() {
  local existing='[{"id":"default","name":"Ollie","gatewayUrl":"http://old:1"}]'
  local out; out="$(EXISTING_AGENTS="$existing" DETECTED="$DETECTED" "$PY" "$MERGE")"
  assert_eq "gatewayUrl refreshed" "$(printf '%s' "$out" | field default gatewayUrl)" "http://host.docker.internal:8642"
}
test_preserves_subtitle() {
  local existing='[{"id":"default","name":"Ollie","subtitle":"Chief of Staff"},{"id":"marketing-agent","name":"Olivia","subtitle":"Lead Gen"}]'
  local out; out="$(EXISTING_AGENTS="$existing" DETECTED="$DETECTED" "$PY" "$MERGE")"
  assert_eq "default keeps subtitle"        "$(printf '%s' "$out" | field default subtitle)" "Chief of Staff"
  assert_eq "marketing keeps subtitle"      "$(printf '%s' "$out" | field marketing-agent subtitle)" "Lead Gen"
}
test_preserves_scope_and_manager_visible
test_absent_scope_stays_absent
test_urls_refreshed_from_detected
test_preserves_subtitle
finish
