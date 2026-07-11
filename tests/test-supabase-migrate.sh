#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/assert.sh"
. "$HERE/../scripts/lib/supabase-migrate.sh"

# ---- shims -----------------------------------------------------------------
# migrate_src_psql / migrate_dst_psql emulate `psql -tAc "<sql>"`.
# They dispatch on SQL substring; tests set SRC_COLS / DST_COLS / SRC_COUNT /
# DST_COUNT / DST_INPUT_FILE to control behavior.

migrate_src_psql() {
  local sql=""
  while [[ $# -gt 0 ]]; do case "$1" in -tAc|-c) sql="$2"; shift 2 ;; *) shift ;; esac; done
  case "$sql" in
    *information_schema.columns*) printf '%s\n' "$SRC_COLS" ;;
    *"count(*)"*)                 printf '%s\n' "$SRC_COUNT" ;;
    *"copy ("*|*"COPY ("*)        printf 'row1\nrow2\n' ;;
    *storage.objects*)            printf 'user-1/a.jpg\timage/jpeg\n' ;;
    *) return 1 ;;
  esac
}

migrate_dst_psql() {
  local sql=""
  while [[ $# -gt 0 ]]; do case "$1" in -tAc|-c) sql="$2"; shift 2 ;; *) shift ;; esac; done
  case "$sql" in
    *nextval*)                    printf '%s\n' "${DST_SERIAL_COLS:-}" ;;
    *information_schema.columns*) printf '%s\n' "$DST_COLS" ;;
    *"count(*)"*)                 printf '%s\n' "$DST_COUNT" ;;
    *TRUNCATE*|*truncate*)        echo "$sql" >> "$DST_SQL_LOG"; return 0 ;;
    *"from stdin"*|*"FROM STDIN"*) cat > "$DST_INPUT_FILE" ;;
    *setval*)                     echo "$sql" >> "$DST_SQL_LOG"; return 0 ;;
    *) return 1 ;;
  esac
}

test_common_columns_intersects_and_orders() {
  SRC_COLS='id,email,newer_hosted_col' DST_COLS='id,email,local_only_col'
  out="$(sb_common_columns auth users)"
  assert_eq "intersection" "$out" 'id,email'
}

test_common_columns_empty_fails() {
  SRC_COLS='a' DST_COLS='b'
  sb_common_columns auth users >/dev/null 2>&1
  assert_eq "empty intersection exit 1" "$?" "1"
}

test_copy_table_streams_and_counts() {
  local d; d="$(mktemp -d)"
  SRC_COLS='id,email' DST_COLS='id,email' SRC_COUNT=2 DST_COUNT=2
  DST_INPUT_FILE="$d/in" DST_SQL_LOG="$d/log"
  out="$(sb_copy_table auth users)"; rc=$?
  assert_eq "copy exit 0" "$rc" "0"
  assert_eq "rows streamed to dst" "$(cat "$d/in")" 'row1
row2'
  assert_eq "truncate cascade for users" "$(grep -ci 'truncate.*cascade' "$d/log")" "1"
  assert_eq "row count reported" "$(echo "$out" | grep -c 'auth.users: 2 rows')" "1"
}

test_copy_table_count_mismatch_fails() {
  local d; d="$(mktemp -d)"
  SRC_COLS='id' DST_COLS='id' SRC_COUNT=5 DST_COUNT=3
  DST_INPUT_FILE="$d/in" DST_SQL_LOG="$d/log"
  sb_copy_table public user_roles >/dev/null 2>&1
  assert_eq "count mismatch exit 1" "$?" "1"
}

test_fix_sequences_noop_without_serials() {
  local d; d="$(mktemp -d)"; DST_SQL_LOG="$d/log"; DST_SERIAL_COLS=''
  sb_fix_sequences public user_roles
  assert_eq "no setval emitted" "$(grep -c setval "$d/log" 2>/dev/null || echo 0)" "0"
}

# ---- bucket sync (curl shim) ----------------------------------------------
CURL_LOG=""
migrate_curl() { echo "$*" >> "$CURL_LOG"; if [[ "$*" == *"/storage/v1/bucket"* ]]; then printf '200'; elif [[ "$*" == *"/object/profile-images/user-1/a.jpg"* && "$*" != *x-upsert* ]]; then printf 'JPEGDATA'; fi; return 0; }

test_sync_bucket_lists_downloads_uploads() {
  local d; d="$(mktemp -d)"; CURL_LOG="$d/curl"
  out="$(sb_sync_bucket https://src.supabase.co SRCKEY http://127.0.0.1:8000 DSTKEY profile-images)"; rc=$?
  assert_eq "sync exit 0" "$rc" "0"
  assert_eq "bucket ensured on dst" "$(grep -c '/storage/v1/bucket' "$d/curl")" "1"
  assert_eq "object downloaded from src" "$(grep -c 'src.supabase.co/storage/v1/object/profile-images/user-1/a.jpg' "$d/curl")" "1"
  assert_eq "object uploaded to dst with upsert" "$(grep -c 'x-upsert' "$d/curl")" "1"
  assert_eq "count reported" "$(echo "$out" | grep -c '1 object')" "1"
}

test_sync_bucket_fails_on_bucket_ensure_error() {
  local d; d="$(mktemp -d)"; CURL_LOG="$d/curl"
  migrate_curl() { echo "$*" >> "$CURL_LOG"; if [[ "$*" == *"/storage/v1/bucket"* ]]; then printf '500'; fi; return 0; }
  sb_sync_bucket https://src.supabase.co SRCKEY http://127.0.0.1:8000 DSTKEY profile-images >/dev/null 2>&1
  assert_eq "bucket ensure 500 exit 1" "$?" "1"
  # restore the standard shim for any later tests
  migrate_curl() { echo "$*" >> "$CURL_LOG"; if [[ "$*" == *"/storage/v1/bucket"* ]]; then printf '200'; elif [[ "$*" == *"/object/profile-images/user-1/a.jpg"* && "$*" != *x-upsert* ]]; then printf 'JPEGDATA'; fi; return 0; }
}

MIGRATE="$HERE/../scripts/12-migrate-supabase.sh"

test_migrate_requires_all_stdin_keys() {
  local d; d="$(mktemp -d)"
  out="$(printf 'HOSTED_DB_URL=postgresql://x\n' | SB_DIR="$d" STACK_ENV="$d/stack.env" ORCH_ENV="$d/orch.env" MIGRATE_PREFLIGHT_ONLY=1 bash "$MIGRATE" 2>&1)"; rc=$?
  assert_eq "missing keys exit 1" "$rc" "1"
  assert_eq "names the missing key" "$(echo "$out" | grep -c 'HOSTED_SUPABASE_URL')" "1"
}

test_migrate_requires_deployed_stack() {
  local d; d="$(mktemp -d)"   # no .env in SB_DIR -> stack not deployed
  out="$(printf 'HOSTED_DB_URL=postgresql://x\nHOSTED_SUPABASE_URL=https://abc.supabase.co\nHOSTED_SERVICE_ROLE_KEY=k\n' \
    | SB_DIR="$d" STACK_ENV="$d/stack.env" ORCH_ENV="$d/orch.env" MIGRATE_PREFLIGHT_ONLY=1 bash "$MIGRATE" 2>&1)"; rc=$?
  assert_eq "undeployed stack exit 1" "$rc" "1"
  assert_eq "points at --deploy" "$(echo "$out" | grep -c '11-install-supabase.sh --deploy')" "1"
}

test_migrate_preflight_ok_with_deployed_stack() {
  local d; d="$(mktemp -d)"
  printf 'SUPABASE_PUBLIC_URL=https://sb-x.jnow.io\nANON_KEY=a\nSERVICE_ROLE_KEY=s\nPOSTGRES_PASSWORD=p\n' > "$d/.env"
  printf 'SUPABASE_URL=old\n' > "$d/stack.env"
  out="$(printf 'HOSTED_DB_URL=postgresql://x\nHOSTED_SUPABASE_URL=https://abc.supabase.co\nHOSTED_SERVICE_ROLE_KEY=k\n' \
    | SB_DIR="$d" STACK_ENV="$d/stack.env" ORCH_ENV="$d/orch.env" MIGRATE_PREFLIGHT_ONLY=1 bash "$MIGRATE" 2>&1)"; rc=$?
  assert_eq "preflight-only exit 0" "$rc" "0"
  assert_eq "announces plan" "$(echo "$out" | grep -c 'preflight OK')" "1"
}

test_storage_gets_jwt_jwks() {
  local compose="$HERE/../templates/supabase/docker-compose.yml"
  # The JWT_JWKS line must appear inside the storage service block (between
  # 'storage:' and the next top-level service key).
  block="$(awk '/^  storage:/{f=1} f&&/^  [a-z]/&&!/^  storage:/{f=0} f' "$compose")"
  assert_eq "storage has JWT_JWKS" "$(echo "$block" | grep -c 'JWT_JWKS=\${JWT_JWKS}')" "1"
}

test_common_columns_intersects_and_orders
test_common_columns_empty_fails
test_copy_table_streams_and_counts
test_copy_table_count_mismatch_fails
test_fix_sequences_noop_without_serials
test_sync_bucket_lists_downloads_uploads
test_sync_bucket_fails_on_bucket_ensure_error
test_migrate_requires_all_stdin_keys
test_migrate_requires_deployed_stack
test_migrate_preflight_ok_with_deployed_stack
test_storage_gets_jwt_jwks
finish
