#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/assert.sh"
. "$HERE/../scripts/lib/supabase-env.sh"

test_validate_rejects_partial_and_malformed() {
  local rc
  (supabase_validate_inputs "" "key") >/dev/null 2>&1; rc=$?
  assert_eq "empty url rejected" "$rc" "1"
  (supabase_validate_inputs "https://abc.supabase.co" "") >/dev/null 2>&1; rc=$?
  assert_eq "empty key rejected" "$rc" "1"
  (supabase_validate_inputs "http://abc.supabase.co" "k") >/dev/null 2>&1; rc=$?
  assert_eq "non-https rejected" "$rc" "1"
  (supabase_validate_inputs "https://supabase.internal.lan:8443" "k") >/dev/null 2>&1; rc=$?
  assert_eq "self-hosted https origin accepted" "$rc" "0"
  (supabase_validate_inputs "https://abc.supabase.co/extra/path" "k") >/dev/null 2>&1; rc=$?
  assert_eq "url with path rejected" "$rc" "1"
  (supabase_validate_inputs "https://abc.supabase.co" "$(printf 'a\nb')") >/dev/null 2>&1; rc=$?
  assert_eq "multiline key rejected" "$rc" "1"
  (supabase_validate_inputs "https://abc.supabase.co" "sk-ok") >/dev/null 2>&1; rc=$?
  assert_eq "valid pair accepted" "$rc" "0"
}

test_write_orch_env_idempotent_and_600() {
  local d; d="$(mktemp -d)"
  export ORCH_ENV="$d/orch.env"
  printf 'ORCHESTRATOR_KEY=x\n' > "$ORCH_ENV"
  supabase_write_orch_env "https://abc.supabase.co" "svc-key-1"
  assert_count "one URL line" "$ORCH_ENV" SUPABASE_URL 1
  assert_count "one key line" "$ORCH_ENV" SUPABASE_SERVICE_ROLE_KEY 1
  # chmod is a no-op on NTFS — only assert mode where the filesystem enforces it
  _mode_probe="$(mktemp)"; chmod 600 "$_mode_probe"
  if [[ "$(stat -c %a "$_mode_probe")" == "600" ]]; then
    assert_eq "mode 600" "$(stat -c %a "$ORCH_ENV")" "600"
  else
    echo "SKIP: mode-600 assertion (filesystem does not enforce POSIX modes)"
  fi
  rm -f "$_mode_probe"
  local a; a="$(cat "$ORCH_ENV")"
  supabase_write_orch_env "https://abc.supabase.co" "svc-key-1"
  assert_eq "re-run zero drift" "$(cat "$ORCH_ENV")" "$a"
  supabase_write_orch_env "https://abc.supabase.co" "svc-key-2"
  assert_eq "replace on new creds" "$(grep '^SUPABASE_SERVICE_ROLE_KEY=' "$ORCH_ENV" | cut -d= -f2-)" "svc-key-2"
  assert_count "still one key line" "$ORCH_ENV" SUPABASE_SERVICE_ROLE_KEY 1
  unset ORCH_ENV
}

test_probe_url() {
  assert_eq "probe url" "$(supabase_schema_probe_url "https://abc.supabase.co")" \
    "https://abc.supabase.co/rest/v1/user_roles?select=user_id&limit=1"
}

test_metacharacter_values_survive() {
  local d; d="$(mktemp -d)"
  export ORCH_ENV="$d/orch.env"
  supabase_write_orch_env "https://abc.supabase.co" 'k3y&with|meta\chars'
  local stored; stored="$(grep '^SUPABASE_SERVICE_ROLE_KEY=' "$ORCH_ENV" | cut -d= -f2-)"
  assert_eq "metacharacter value stored literally" "$stored" 'k3y&with|meta\chars'
  local before; before="$(cat "$ORCH_ENV")"
  supabase_write_orch_env "https://abc.supabase.co" 'k3y&with|meta\chars'
  assert_eq "re-run with same metachar value zero drift" "$(cat "$ORCH_ENV")" "$before"
  supabase_write_orch_env "https://abc.supabase.co" 'a&b'
  assert_count "still one key line after replace" "$ORCH_ENV" SUPABASE_SERVICE_ROLE_KEY 1
  local final; final="$(grep '^SUPABASE_SERVICE_ROLE_KEY=' "$ORCH_ENV" | cut -d= -f2-)"
  assert_eq "replaced with second metachar value" "$final" 'a&b'
  unset ORCH_ENV
}

test_render_kong_substitutes_keys() {
  local d; d="$(mktemp -d)"
  printf 'key: __ANON_KEY__\nother: __SERVICE_ROLE_KEY__\n' > "$d/kong.tpl"
  supabase_render_kong "$d/kong.tpl" "$d/kong.yml" "anon-123" "svc-456"
  grep -q 'key: anon-123' "$d/kong.yml"; assert_eq "anon substituted" "$?" "0"
  grep -q 'other: svc-456' "$d/kong.yml"; assert_eq "service substituted" "$?" "0"
  ! grep -q '__' "$d/kong.yml"; assert_eq "no placeholders remain" "$?" "0"
  # 644, not 600: the container's non-root kong user must read this bind
  # mount via the "other" bit. chmod is a no-op on NTFS — only assert mode
  # where the filesystem enforces it (mirrors the ORCH_ENV 600 probe above).
  _mode_probe="$(mktemp)"; chmod 600 "$_mode_probe"
  if [[ "$(stat -c %a "$_mode_probe")" == "600" ]]; then
    assert_eq "kong.yml mode 644" "$(stat -c %a "$d/kong.yml")" "644"
  else
    echo "SKIP: kong.yml mode-644 assertion (filesystem does not enforce POSIX modes)"
  fi
  rm -f "$_mode_probe"
}

test_write_stack_dashboard_env_idempotent() {
  local d; d="$(mktemp -d)"
  printf 'FRONTEND_IMAGE=x\nSUPABASE_URL=old\n' > "$d/stack.env"
  supabase_write_stack_dashboard_env "$d/stack.env" "https://sb.new.jnow.io" "anon-key"
  assert_count "one SUPABASE_URL line" "$d/stack.env" SUPABASE_URL 1
  grep -q '^SUPABASE_URL=https://sb.new.jnow.io$' "$d/stack.env"
  assert_eq "url updated" "$?" "0"
  grep -q '^SUPABASE_ANON_KEY=anon-key$' "$d/stack.env"
  assert_eq "anon key written" "$?" "0"
  grep -q '^FRONTEND_IMAGE=x$' "$d/stack.env"
  assert_eq "unrelated keys untouched" "$?" "0"
}

test_validate_rejects_partial_and_malformed
test_write_orch_env_idempotent_and_600
test_probe_url
test_metacharacter_values_survive
test_render_kong_substitutes_keys
test_write_stack_dashboard_env_idempotent
finish
