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

# app_migrations_render FILE [SCHEMA]
# Emit FILE's SQL relocated into SCHEMA. With no SCHEMA the file passes through
# byte-identical (the stack-per-app path really does live in public).
#
# App migrations are written the ordinary Supabase way — `public.` qualified —
# so they stay compatible with `supabase start`, the CLI's migration runner and
# the app's own RLS integration suite. Relocating them is the INSTALLER's job,
# done here at the moment of apply. (Parameterising the app's SQL with psql
# `:"variables"` was tried and reverted: the CLI applies migrations over a
# Postgres connection rather than through the psql client, so nothing
# substituted them and every migration died on `syntax error at or near ":"`,
# taking local dev and the RLS suite with it.)
#
# Two dot-anchored rewrites, both unambiguous:
#   public.<obj>             -> <schema>.<obj>
#   set search_path = public -> set search_path = <schema>
#
# The BARE word `public` is deliberately untouched: in `revoke ... from anon,
# public` it names the PUBLIC ROLE, and rewriting it would silently change who
# the revoke applies to — a privilege change wearing a relocation's clothes.
# The search_path rewrite is security-critical in the other direction: a
# security definer function left pinned to `public` resolves names outside its
# own schema at runtime, so the migrations succeed and the failure surfaces
# later, in the functions that enforce authorization.
#
# Caveat, deliberately accepted: a migration containing the literal text
# `public.` inside a string literal or comment would also be rewritten.
app_migrations_render() { # FILE [SCHEMA]
  local file="$1" schema="${2:-}"
  if [[ -z "${schema}" ]]; then cat "${file}"; return; fi
  sed -e "s/public\./${schema}./g" \
      -e "s/set search_path = public/set search_path = ${schema}/g" "${file}"
}

app_migrations_apply() { # IMG PSQL_FN TRACKER [SCHEMA]
  local img="$1" psql_fn="$2" tracker="$3" schema="${4:-}"
  local mig_dir ctr f base applied
  # Interpolated into a sed replacement below, so constrain it to the same
  # Postgres-identifier charset 26 enforces before it can carry sed metachars.
  if [[ -n "${schema}" && ! "${schema}" =~ ^[a-z][a-z0-9_]*$ ]]; then
    echo "error: app_migrations_apply: schema '${schema}' is not a bare Postgres identifier" >&2
    return 1
  fi
  mig_dir="$(mktemp -d)"
  ctr="$(docker create "${img}")"
  docker cp "${ctr}:/app/supabase/migrations/." "${mig_dir}/"
  docker rm "${ctr}" >/dev/null
  "${psql_fn}" -c "create table if not exists ${tracker} (name text primary key, applied_at timestamptz not null default now());"
  # anon/authenticated hold DML on every app schema, including this tracker,
  # so it must not itself be an unprotected table — otherwise a schema whose
  # migrations are all correctly gated would still fail the RLS gate on its
  # own tracker. No policies: this denies anon/authenticated outright, while
  # the table owner (this runner) still bypasses RLS as owners normally do.
  # Idempotent — safe to re-run on every install.
  "${psql_fn}" -c "alter table ${tracker} enable row level security;"
  for f in $(ls "${mig_dir}"/*.sql | sort); do
    base="$(basename "$f")"
    applied="$("${psql_fn}" -c "select 1 from ${tracker} where name='${base}';")"
    if [[ "${applied}" == "1" ]]; then echo "    skip ${base} (applied)"; continue; fi
    echo "    apply ${base}"
    # Single-transaction apply: the migration file and its tracker INSERT
    # travel in ONE psql invocation, so a mid-file failure rolls back both —
    # no partially-applied file recorded as done, no applied file unrecorded.
    if ! { app_migrations_render "$f" "${schema}"; printf "\ninsert into %s (name) values ('%s');\n" "${tracker}" "${base}"; } \
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
  local psql_fn="$1" schema="$2" exists unprotected line

  # Confirm the schema exists BEFORE trusting an empty result from the real
  # check below. Zero rows and "the query never ran" are both empty stdout,
  # and both are otherwise indistinguishable from "every table protected" —
  # the gate must demand positive confirmation, not infer safety from
  # absence. This also fails closed if the probe itself errors (wrong
  # password, container not ready, a permission error): the exit status is
  # checked, not just the output.
  if ! exists="$("${psql_fn}" -c "select 1 from pg_namespace where nspname = '${schema}';")"; then
    echo "error: RLS gate could not confirm schema '${schema}' exists (the query itself failed) — refusing to certify an unverified schema." >&2
    return 1
  fi
  exists="$(printf '%s' "${exists}" | tr -d '\r' | grep -v '^$' || true)"
  if [[ -z "${exists}" ]]; then
    echo "error: schema '${schema}' does not exist (or is unreachable) — refusing to certify a schema the gate cannot find." >&2
    return 1
  fi

  # relkind covers ordinary (r), partitioned (p), and foreign (f) tables — a
  # partitioned parent with RLS off exposes every row of its leaves through
  # the parent, under the shared anon key, exactly like an ordinary table.
  # Deliberately excludes materialized views (m): relrowsecurity can never
  # be true for a matview, so including it would make the gate permanently
  # unsatisfiable.
  if ! unprotected="$("${psql_fn}" -c "select relname from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = '${schema}' and c.relkind in ('r','p','f') and not c.relrowsecurity order by relname;")"; then
    echo "error: RLS gate could not query schema '${schema}' — refusing to certify it. The gate must never pass on an unverified schema." >&2
    return 1
  fi
  unprotected="$(printf '%s' "${unprotected}" | tr -d '\r' | grep -v '^$' || true)"
  if [[ -n "${unprotected}" ]]; then
    echo "error: RLS is not enabled on these tables in schema '${schema}':" >&2
    printf '%s\n' "${unprotected}" | while IFS= read -r line; do echo "  ${line}" >&2; done
    echo "Every app on this box shares the same core ANON_KEY, and anon/authenticated hold DML on every app schema — so each table above is readable AND writable by every other app's browser bundle. Add 'alter table <t> enable row level security' plus policies to the migration, then re-run." >&2
    return 1
  fi
  echo "    RLS gate: every table in '${schema}' is protected"
  return 0
}
