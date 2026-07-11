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
migrate_curl() { echo "$*" >> "$CURL_LOG"; if [[ "$*" == *"/object/profile-images/user-1/a.jpg"* && "$*" != *x-upsert* ]]; then printf 'JPEGDATA'; fi; return 0; }

test_sync_bucket_lists_downloads_uploads() {
  local d; d="$(mktemp -d)"; CURL_LOG="$d/curl"
  out="$(sb_sync_bucket https://src.supabase.co SRCKEY http://127.0.0.1:8000 DSTKEY profile-images)"; rc=$?
  assert_eq "sync exit 0" "$rc" "0"
  assert_eq "bucket ensured on dst" "$(grep -c '/storage/v1/bucket' "$d/curl")" "1"
  assert_eq "object downloaded from src" "$(grep -c 'src.supabase.co/storage/v1/object/profile-images/user-1/a.jpg' "$d/curl")" "1"
  assert_eq "object uploaded to dst with upsert" "$(grep -c 'x-upsert' "$d/curl")" "1"
  assert_eq "count reported" "$(echo "$out" | grep -c '1 object')" "1"
}

test_common_columns_intersects_and_orders
test_common_columns_empty_fails
test_copy_table_streams_and_counts
test_copy_table_count_mismatch_fails
test_fix_sequences_noop_without_serials
test_sync_bucket_lists_downloads_uploads
finish
