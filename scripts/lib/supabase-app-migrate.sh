#!/usr/bin/env bash
# supabase-app-migrate.sh — testable core for 21-migrate-app.sh. Source AFTER
# supabase-migrate.sh (reuses sb_common_columns, sb_fix_sequences,
# sb_sync_bucket, migrate_curl default).
#
# Callers MUST define: migrate_src_psql, migrate_dst_psql (see
# supabase-migrate.sh contract) and migrate_src_pgdump (pg_dump-alike against
# the hosted DB; receives pg_dump args, writes SQL to stdout).
set -uo pipefail

# Whole public schema, structure only. --no-owner: local restore runs as
# supabase_admin and hosted role owners (postgres, supabase_admin variants)
# don't map 1:1. ACLs are KEPT (no --no-privileges) — anon/authenticated/
# service_role grants and RLS enable flags must survive; those roles exist in
# both hosted and self-hosted images. --clean --if-exists: re-runs drop and
# recreate public schema objects (first-run DROPs are no-ops under
# --if-exists); safe because data is truncate-first re-copied afterward.
sb_app_dump_schema() {
  migrate_src_pgdump --clean --if-exists --schema-only --schema=public --no-owner \
    | migrate_dst_psql -v ON_ERROR_STOP=1 || return 1
  echo "    public schema restored"
}

sb_app_list_tables() {
  migrate_src_psql -tAc "select table_name from information_schema.tables where table_schema='public' and table_type='BASE TABLE' order by table_name"
}

# Copy every listed table with FK triggers disabled on the destination so
# topological order doesn't matter. One truncate-all first (cascade), then a
# per-table COPY inside a session that sets session_replication_role=replica
# (psql executes multiple -c in ONE session/connection).
sb_app_copy_data() { # "table1 table2 ..."
  local tables="$1" t cols src_n dst_n qualified=""
  for t in $tables; do qualified="${qualified}${qualified:+, }public.${t}"; done
  migrate_dst_psql -c "truncate table ${qualified} cascade;" </dev/null || return 1
  for t in $tables; do
    cols="$(sb_common_columns public "$t")" || return 1
    migrate_src_psql -c "copy (select ${cols} from public.${t}) to stdout" \
      | migrate_dst_psql -c "set session_replication_role = replica;" \
                         -c "copy public.${t} (${cols}) from stdin" || return 1
    src_n="$(migrate_src_psql -tAc "select count(*) from public.${t}")" || return 1
    dst_n="$(migrate_dst_psql -tAc "select count(*) from public.${t}" </dev/null)" || return 1
    if [[ "$src_n" != "$dst_n" ]]; then
      echo "error: public.${t} row count mismatch (src=${src_n} dst=${dst_n})" >&2; return 1
    fi
    echo "    public.${t}: ${dst_n} rows"
    sb_fix_sequences public "$t" || return 1
  done
}

# Buckets (with their public flag) + objects + storage.objects RLS policies.
sb_app_port_storage() { # SRC_URL SRC_KEY DST_URL DST_KEY
  local src="$1" src_key="$2" dst="$3" dst_key="$4" line bucket is_public code ddl
  while IFS=$'\t' read -r bucket is_public; do
    [[ -z "$bucket" ]] && continue
    code="$(migrate_curl -s -o /dev/null -w '%{http_code}' -X POST "${dst%/}/storage/v1/bucket" \
      -H "apikey: ${dst_key}" -H "Authorization: Bearer ${dst_key}" \
      -H "Content-Type: application/json" \
      -d "{\"id\":\"${bucket}\",\"name\":\"${bucket}\",\"public\":${is_public}}")"
    case "${code}" in
      200|201|400|409) ;;
      *) echo "error: bucket ensure failed for ${bucket} (HTTP ${code})" >&2; return 1 ;;
    esac
    sb_sync_bucket "$src" "$src_key" "$dst" "$dst_key" "$bucket" || return 1
  done < <(migrate_src_psql -tAc "select id || E'\t' || public::text from storage.buckets order by id")
  # Port storage.objects policies: generate CREATE POLICY DDL from the source's
  # pg_policies (qual is null for INSERT-only policies; with_check null for
  # SELECT/DELETE; permissive is the text PERMISSIVE/RESTRICTIVE — the AS
  # clause must be emitted or RESTRICTIVE policies silently downgrade to the
  # PERMISSIVE default). Drop-first for idempotent re-runs.
  ddl="$(migrate_src_psql -tAc "
    select 'drop policy if exists ' || quote_ident(policyname) || ' on storage.objects; '
        || 'create policy ' || quote_ident(policyname) || ' on storage.objects'
        || ' as ' || lower(permissive)
        || ' for ' || lower(cmd)
        || ' to ' || array_to_string(roles, ', ')
        || coalesce(' using (' || qual || ')', '')
        || coalesce(' with check (' || with_check || ')', '')
        || ';'
    from pg_policies where schemaname='storage' and tablename='objects'")" || return 1
  if [[ -n "${ddl//[[:space:]]/}" ]]; then
    printf '%s\n' "$ddl" | migrate_dst_psql -v ON_ERROR_STOP=1 || return 1
    echo "    storage.objects policies ported"
  else
    echo "    no storage.objects policies on source"
  fi
}

# supabase_realtime publication membership + replica identity, mirrored from
# the source (postgres_changes needs the table in the publication; UPDATE
# events with old-record payloads need replica identity full).
sb_app_port_realtime_publication() {
  local schema table ident
  migrate_dst_psql -c "do \$\$ begin if not exists (select 1 from pg_publication where pubname='supabase_realtime') then execute 'create publication supabase_realtime'; end if; end \$\$;" </dev/null || return 1
  while IFS=$'\t' read -r schema table; do
    [[ -z "$table" ]] && continue
    migrate_dst_psql -c "do \$\$ begin if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='${schema}' and tablename='${table}') then execute 'alter publication supabase_realtime add table ${schema}.${table}'; end if; end \$\$;" </dev/null || return 1
    echo "    publication += ${schema}.${table}"
    ident="$(migrate_src_psql -tAc "select relreplident from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='${schema}' and c.relname='${table}'")" || return 1
    if [[ "$ident" == "f" ]]; then
      migrate_dst_psql -c "alter table ${schema}.${table} replica identity full;" </dev/null || return 1
      echo "    replica identity full → ${schema}.${table}"
    fi
  done < <(migrate_src_psql -tAc "select schemaname || E'\t' || tablename from pg_publication_tables where pubname='supabase_realtime'")
}
