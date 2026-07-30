#!/usr/bin/env bash
# app-migrations.sh — apply the migrations bundled inside an app image.
#
# The caller supplies a psql-invoking function by NAME; this lib never builds a
# connection itself, so the same runner serves a per-app stack (legacy) and the
# core stack with a schema-scoped role.
#
# app_migrations_apply IMG PSQL_FN TRACKER
#   IMG      image ref or ID holding /app/supabase/migrations
#   PSQL_FN  name of a function: reads SQL on stdin, forwards "$@" to psql
#   TRACKER  fully-qualified tracker table, e.g. public._app_migrations

app_migrations_apply() { # IMG PSQL_FN TRACKER
  local img="$1" psql_fn="$2" tracker="$3"
  local mig_dir ctr f base applied
  mig_dir="$(mktemp -d)"
  ctr="$(docker create "${img}")"
  docker cp "${ctr}:/app/supabase/migrations/." "${mig_dir}/"
  docker rm "${ctr}" >/dev/null
  "${psql_fn}" -c "create table if not exists ${tracker} (name text primary key, applied_at timestamptz not null default now());"
  for f in $(ls "${mig_dir}"/*.sql | sort); do
    base="$(basename "$f")"
    applied="$("${psql_fn}" -c "select 1 from ${tracker} where name='${base}';")"
    if [[ "${applied}" == "1" ]]; then echo "    skip ${base} (applied)"; continue; fi
    echo "    apply ${base}"
    # Single-transaction apply: the migration file and its tracker INSERT
    # travel in ONE psql invocation, so a mid-file failure rolls back both —
    # no partially-applied file recorded as done, no applied file unrecorded.
    { cat "$f"; printf "\ninsert into %s (name) values ('%s');\n" "${tracker}" "${base}"; } \
      | "${psql_fn}" -1 -f -
  done
  rm -rf "${mig_dir}"
}
