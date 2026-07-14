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
  # Filter version-skew lines out of the dump before they hit psql 15.8:
  #  - `\restrict`/`\unrestrict` are psql meta-commands modern pg_dump (18+
  #    line, and some 17.x builds) emits around the dump body per
  #    CVE-2025-8714's mitigation; psql 15.8 doesn't understand them and
  #    aborts under ON_ERROR_STOP.
  #  - `SET transaction_timeout = 0;` is a GUC pg_dump 17 emits that doesn't
  #    exist on PG15 — unknown-GUC is an ERROR, not a warning, under
  #    ON_ERROR_STOP.
  # Source stays postgres:17-alpine (MIGRATE_PG_IMAGE) because the hosted
  # side may be PG17; only the psql 15.8 destination needs the filter.
  # (bracket-expression `[\]` rather than an escaped `\\` — this sed's ERE
  # backslash-escaping is unreliable across platforms/builds; `[\]` is an
  # unambiguous one-char class matching a literal backslash everywhere.)
  migrate_src_pgdump --clean --if-exists --schema-only --schema=public --no-owner \
    | sed -E '/^[\](un)?restrict/d; /^SET transaction_timeout/d' \
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

# Drop all existing storage.objects policies on the DESTINATION before the
# schema restore. Re-runs previously ported policies referencing public
# tables (fieldkit's do) create a dependency that makes the schema dump's
# unqualified `DROP TABLE IF EXISTS public.<t>` (no CASCADE) fail under
# ON_ERROR_STOP. Policies are recreated later by sb_app_port_storage, so
# dropping them first is safe and idempotent (no-op on first run).
sb_app_drop_dst_storage_policies() {
  local ddl
  ddl="$(migrate_dst_psql -tAc "select 'drop policy if exists ' || quote_ident(policyname) || ' on storage.objects;' from pg_policies where schemaname='storage' and tablename='objects'" </dev/null)" || return 1
  if [[ -n "${ddl//[[:space:]]/}" ]]; then
    printf '%s\n' "$ddl" | migrate_dst_psql -v ON_ERROR_STOP=1 || return 1
  fi
}

# Buckets (with their public flag + size/mime constraints) + objects +
# storage.objects RLS policies.
sb_app_port_storage() { # SRC_URL SRC_KEY DST_URL DST_KEY
  local src="$1" src_key="$2" dst="$3" dst_key="$4"
  local bucket is_public size mimes code ddl payload size_sql mime_sql
  while IFS=$'\t' read -r bucket is_public size mimes; do
    [[ -z "$bucket" ]] && continue
    # Build the create payload with size/mime constraints only when the
    # source has them set (file_size_limit may be null; allowed_mime_types
    # arrives pre-JSON-encoded via array_to_json so it's already a bare
    # JSON array literal, or empty when null).
    payload="{\"id\":\"${bucket}\",\"name\":\"${bucket}\",\"public\":${is_public}"
    [[ -n "${size}" ]] && payload="${payload},\"file_size_limit\":${size}"
    [[ -n "${mimes}" ]] && payload="${payload},\"allowed_mime_types\":${mimes}"
    payload="${payload}}"
    code="$(migrate_curl -s -o /dev/null -w '%{http_code}' -X POST "${dst%/}/storage/v1/bucket" \
      -H "apikey: ${dst_key}" -H "Authorization: Bearer ${dst_key}" \
      -H "Content-Type: application/json" \
      -d "${payload}")"
    case "${code}" in
      200|201|400|409) ;;
      *) echo "error: bucket ensure failed for ${bucket} (HTTP ${code})" >&2; return 1 ;;
    esac
    # Converge metadata via SQL regardless of which REST path the ensure call
    # took (created vs already-exists 400/409 never applies size/mime), so
    # re-runs pick up constraint changes on the source too.
    size_sql="null"; [[ -n "${size}" ]] && size_sql="${size}"
    mime_sql="null"; [[ -n "${mimes}" ]] && mime_sql="(select array_agg(x) from jsonb_array_elements_text('${mimes}'::jsonb) x)"
    migrate_dst_psql -c "update storage.buckets set public=${is_public}, file_size_limit=${size_sql}, allowed_mime_types=${mime_sql} where id='${bucket}';" </dev/null || return 1
    sb_sync_bucket "$src" "$src_key" "$dst" "$dst_key" "$bucket" || return 1
  done < <(migrate_src_psql -tAc "select id || E'\t' || public::text || E'\t' || coalesce(file_size_limit::text,'') || E'\t' || coalesce(array_to_json(allowed_mime_types)::text,'') from storage.buckets order by id")
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
