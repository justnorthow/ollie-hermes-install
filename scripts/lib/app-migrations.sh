#!/usr/bin/env bash
# app-migrations.sh — apply the migrations bundled inside an app image.
#
# The caller supplies a psql-invoking function by NAME; this lib never builds a
# connection itself, so the same runner serves a per-app stack (legacy) and the
# core stack with a schema-scoped role.
#
# app_migrations_apply IMG PSQL_FN TRACKER [SCHEMA]
#   IMG      image ref or ID holding /app/supabase/migrations
#   PSQL_FN  name of a function: reads SQL on stdin, forwards "$@" to psql
#   TRACKER  fully-qualified tracker table, e.g. public._app_migrations
#   SCHEMA   optional; when supplied, the RLS gate runs after all migrations

app_migrations_apply() { # IMG PSQL_FN TRACKER [SCHEMA]
  local img="$1" psql_fn="$2" tracker="$3" schema="${4:-}"
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
    if ! { cat "$f"; printf "\ninsert into %s (name) values ('%s');\n" "${tracker}" "${base}"; } \
         | "${psql_fn}" -1 -f -; then
      echo "error: migration ${base} failed — nothing was recorded as applied (single-transaction)" >&2
      rm -rf "${mig_dir}"
      return 1
    fi
  done
  rm -rf "${mig_dir}"
  # The gate runs AFTER every migration, because a migration is exactly what
  # creates the table that would fail it.
  if [[ -n "${schema}" ]]; then
    app_migrations_rls_gate "${psql_fn}" "${schema}" || return 1
  fi
}

# app_migrations_rls_gate PSQL_FN SCHEMA
#
# Every app on the box is handed the SAME core ANON_KEY, and anon/authenticated
# hold USAGE on every app schema plus DML on its tables — they must, because
# those are the roles that serve user-context requests. Under per-app stacks,
# cross-app reach was structurally impossible. After consolidation it is
# policy-dependent, and the policy is RLS. So RLS is mandatory, not advisory.
app_migrations_rls_gate() { # PSQL_FN SCHEMA
  local psql_fn="$1" schema="$2" unprotected
  unprotected="$("${psql_fn}" -c "select relname from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = '${schema}' and c.relkind = 'r' and not c.relrowsecurity order by relname;")"
  unprotected="$(printf '%s' "${unprotected}" | tr -d '\r' | grep -v '^$' || true)"
  if [[ -n "${unprotected}" ]]; then
    echo "error: RLS is not enabled on these tables in schema '${schema}':" >&2
    printf '  %s\n' ${unprotected} >&2
    echo "Every app on this box shares the same core ANON_KEY, and anon/authenticated hold DML on every app schema — so each table above is readable AND writable by every other app's browser bundle. Add 'alter table <t> enable row level security' plus policies to the migration, then re-run." >&2
    return 1
  fi
  echo "    RLS gate: every table in '${schema}' is protected"
  return 0
}
