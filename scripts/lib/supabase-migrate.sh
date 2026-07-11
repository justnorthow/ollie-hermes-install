#!/usr/bin/env bash
# supabase-migrate.sh — testable core for 12-migrate-supabase.sh. Source, don't exec.
#
# Callers MUST define, before calling:
#   migrate_src_psql  — psql-alike against the HOSTED db (SELECT/COPY TO STDOUT only)
#   migrate_dst_psql  — psql-alike against the LOCAL db (may read stdin)
#   migrate_curl      — curl-alike for Storage REST (default provided below)
set -uo pipefail

command -v migrate_curl >/dev/null 2>&1 || migrate_curl() { curl "$@"; }

# Comma-separated quoted column list present in BOTH sides, excluding generated
# columns (auth.users.confirmed_at is GENERATED ALWAYS — COPY may not target it).
_sb_cols_sql() { # SCHEMA TABLE
  printf "select string_agg(quote_ident(column_name), ',' order by ordinal_position) from information_schema.columns where table_schema='%s' and table_name='%s' and is_generated='NEVER'" "$1" "$2"
}

sb_common_columns() { # SCHEMA TABLE
  local schema="$1" table="$2" src dst out c
  src="$(migrate_src_psql -tAc "$(_sb_cols_sql "$schema" "$table")")" || return 1
  dst="$(migrate_dst_psql -tAc "$(_sb_cols_sql "$schema" "$table")")" || return 1
  # Preserve the SOURCE's ordinal order (comm/sort would alphabetize).
  out="$(while IFS= read -r c; do
    grep -qxF "$c" <(tr ',' '\n' <<<"$dst") && printf '%s\n' "$c"
  done < <(tr ',' '\n' <<<"$src") | paste -sd, -)"
  if [[ -z "$out" ]]; then
    echo "error: no common columns for ${schema}.${table}" >&2; return 1
  fi
  printf '%s\n' "$out"
}

sb_copy_table() { # SCHEMA TABLE
  local schema="$1" table="$2" cols cascade="" src_n dst_n
  cols="$(sb_common_columns "$schema" "$table")" || return 1
  # auth.users owns FK'd auth children (identities, sessions, refresh_tokens…)
  # — CASCADE clears them; they are re-filled (identities) or session state we
  # deliberately drop (users re-login once after cutover).
  [[ "${schema}.${table}" == "auth.users" ]] && cascade=" cascade"
  migrate_dst_psql -c "truncate table ${schema}.${table}${cascade};" || return 1
  migrate_src_psql -c "copy (select ${cols} from ${schema}.${table}) to stdout" \
    | migrate_dst_psql -c "copy ${schema}.${table} (${cols}) from stdin" || return 1
  src_n="$(migrate_src_psql -tAc "select count(*) from ${schema}.${table}")" || return 1
  dst_n="$(migrate_dst_psql -tAc "select count(*) from ${schema}.${table}")" || return 1
  if [[ "$src_n" != "$dst_n" ]]; then
    echo "error: ${schema}.${table} row count mismatch (src=${src_n} dst=${dst_n})" >&2; return 1
  fi
  echo "${schema}.${table}: ${dst_n} rows"
}

sb_fix_sequences() { # SCHEMA TABLE
  local schema="$1" table="$2" col
  while IFS= read -r col; do
    [[ -z "$col" ]] && continue
    migrate_dst_psql -c "select setval(pg_get_serial_sequence('${schema}.${table}','${col}'), coalesce((select max(${col}) from ${schema}.${table}), 1));" </dev/null || return 1
  done < <(migrate_dst_psql -tAc "select column_name from information_schema.columns where table_schema='${schema}' and table_name='${table}' and column_default like 'nextval%'")
}

sb_sync_bucket() { # SRC_URL SRC_KEY DST_URL DST_KEY BUCKET
  local src="${1%/}" src_key="$2" dst="${3%/}" dst_key="$4" bucket="$5"
  local line name mime tmp n=0
  # Ensure bucket on dst (idempotent: 409/400 "already exists" is fine).
  migrate_curl -s -o /dev/null -X POST "${dst}/storage/v1/bucket" \
    -H "apikey: ${dst_key}" -H "Authorization: Bearer ${dst_key}" \
    -H "Content-Type: application/json" \
    -d "{\"id\":\"${bucket}\",\"name\":\"${bucket}\",\"public\":true}"
  tmp="$(mktemp)"
  while IFS=$'\t' read -r name mime; do
    [[ -z "$name" ]] && continue
    migrate_curl -s -f -o "$tmp" \
      -H "apikey: ${src_key}" -H "Authorization: Bearer ${src_key}" \
      "${src}/storage/v1/object/${bucket}/${name}" || { echo "error: download failed: ${name}" >&2; rm -f "$tmp"; return 1; }
    migrate_curl -s -f -o /dev/null -X POST \
      -H "apikey: ${dst_key}" -H "Authorization: Bearer ${dst_key}" \
      -H "x-upsert: true" -H "Content-Type: ${mime:-application/octet-stream}" \
      --data-binary @"$tmp" \
      "${dst}/storage/v1/object/${bucket}/${name}" || { echo "error: upload failed: ${name}" >&2; rm -f "$tmp"; return 1; }
    echo "    synced ${name}"
    n=$((n+1))
  done < <(migrate_src_psql -tAc "select name || E'\t' || coalesce(metadata->>'mimetype','') from storage.objects where bucket_id='${bucket}'")
  rm -f "$tmp"
  echo "${bucket}: ${n} object(s) synced"
}
