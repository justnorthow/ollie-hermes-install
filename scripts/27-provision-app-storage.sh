#!/usr/bin/env bash
# Provision manifest-declared private Supabase Storage buckets and policies for
# one consolidated app. Runs as supabase_admin because app owner roles must not
# receive cross-app policy-administration authority.
set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  echo "error: run as the service user, not root" >&2; exit 1
fi

APP_NAME=""; CORE_STACK_DIR=""; STORAGE_CONFIG_JSON=""
while IFS='=' read -r key value || [[ -n "${key:-}" ]]; do
  case "${key}" in
    APP_NAME) APP_NAME="${value}" ;;
    CORE_STACK_DIR) CORE_STACK_DIR="${value}" ;;
    STORAGE_CONFIG_JSON) STORAGE_CONFIG_JSON="${value}" ;;
  esac
done

if [[ ! "${APP_NAME}" =~ ^[a-z][a-z0-9_]*$ ]]; then
  echo "error: APP_NAME required, ^[a-z][a-z0-9_]*$" >&2; exit 1
fi
CORE_DIR="${CORE_STACK_DIR:-${HOME}/supabase-stack}"
[[ -f "${CORE_DIR}/.env" && -f "${CORE_DIR}/docker-compose.yml" ]] \
  || { echo "error: core Supabase stack missing at ${CORE_DIR}" >&2; exit 1; }

ROWS="$(python3 - "${APP_NAME}" "${STORAGE_CONFIG_JSON}" <<'PY'
import json, re, sys
app, raw = sys.argv[1:]
try:
    config = json.loads(raw)
except Exception as exc:
    raise SystemExit(f"error: invalid storage manifest JSON: {exc}")
if not isinstance(config, dict) or set(config) != {"buckets"}:
    raise SystemExit("error: storage config must contain only a buckets array")
buckets = config["buckets"]
if not isinstance(buckets, list) or not buckets or len(buckets) > 10:
    raise SystemExit("error: storage.buckets must contain 1-10 entries")
seen = set()
for bucket in buckets:
    if not isinstance(bucket, dict) or set(bucket) != {"id", "max_bytes", "mime_types"}:
        raise SystemExit("error: each storage bucket requires id, max_bytes, and mime_types")
    bucket_id = bucket["id"]
    max_bytes = bucket["max_bytes"]
    mime_types = bucket["mime_types"]
    if not isinstance(bucket_id, str) or not re.fullmatch(r"[a-z][a-z0-9_]{0,39}", bucket_id):
        raise SystemExit(f"error: invalid storage bucket id {bucket_id!r}")
    if bucket_id in seen:
        raise SystemExit(f"error: duplicate storage bucket id {bucket_id!r}")
    seen.add(bucket_id)
    if not isinstance(max_bytes, int) or not 1 <= max_bytes <= 104857600:
        raise SystemExit(f"error: invalid max_bytes for {bucket_id}")
    if not isinstance(mime_types, list) or not mime_types or len(mime_types) > 10:
        raise SystemExit(f"error: mime_types for {bucket_id} must be a non-empty array")
    for mime in mime_types:
        if not isinstance(mime, str) or not re.fullmatch(r"[a-z0-9.+-]+/[a-z0-9.*+-]+", mime):
            raise SystemExit(f"error: invalid MIME type {mime!r}")
    if len(f"{app}_{bucket_id}_app_all") > 63:
        raise SystemExit("error: app and bucket names are too long for policy identifiers")
    print(f"{bucket_id}\t{max_bytes}\t{','.join(mime_types)}")
PY
)"

DB_PASSWORD="$(grep -E '^POSTGRES_PASSWORD=' "${CORE_DIR}/.env" | tail -1 | cut -d= -f2-)"
[[ -n "${DB_PASSWORD}" ]] || { echo "error: POSTGRES_PASSWORD missing from ${CORE_DIR}/.env" >&2; exit 1; }
APP_ROLE="${APP_NAME}_owner"

admin_psql() {
  docker compose -f "${CORE_DIR}/docker-compose.yml" --env-file "${CORE_DIR}/.env" \
    exec -T -e PGPASSWORD="${DB_PASSWORD}" db \
    psql -v ON_ERROR_STOP=1 -U supabase_admin -h 127.0.0.1 -d postgres
}

admin_psql <<SQL
GRANT USAGE ON SCHEMA storage TO ${APP_ROLE};
GRANT SELECT ON TABLE storage.buckets TO ${APP_ROLE};
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE storage.objects TO ${APP_ROLE};
SQL

while IFS=$'\t' read -r bucket max_bytes mime_csv; do
  [[ -n "${bucket}" ]] || continue
  mime_sql=""
  IFS=',' read -r -a mimes <<< "${mime_csv}"
  for mime in "${mimes[@]}"; do
    [[ -n "${mime_sql}" ]] && mime_sql+=","
    mime_sql+="'${mime}'"
  done
  prefix="${APP_NAME}_${bucket}"
  admin_psql <<SQL
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('${bucket}', '${bucket}', false, ${max_bytes}, ARRAY[${mime_sql}])
ON CONFLICT (id) DO UPDATE SET
  public = false,
  file_size_limit = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

DROP POLICY IF EXISTS ${prefix}_own_select ON storage.objects;
CREATE POLICY ${prefix}_own_select ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = '${bucket}' AND (storage.foldername(name))[1] = auth.uid()::text);
DROP POLICY IF EXISTS ${prefix}_own_insert ON storage.objects;
CREATE POLICY ${prefix}_own_insert ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = '${bucket}' AND (storage.foldername(name))[1] = auth.uid()::text);
DROP POLICY IF EXISTS ${prefix}_own_update ON storage.objects;
CREATE POLICY ${prefix}_own_update ON storage.objects FOR UPDATE TO authenticated
  USING (bucket_id = '${bucket}' AND (storage.foldername(name))[1] = auth.uid()::text)
  WITH CHECK (bucket_id = '${bucket}' AND (storage.foldername(name))[1] = auth.uid()::text);
DROP POLICY IF EXISTS ${prefix}_own_delete ON storage.objects;
CREATE POLICY ${prefix}_own_delete ON storage.objects FOR DELETE TO authenticated
  USING (bucket_id = '${bucket}' AND (storage.foldername(name))[1] = auth.uid()::text);

-- The scoped app server processes and cleans up files for its own product. RLS
-- still confines its owner JWT to this bucket, never another app's objects.
DROP POLICY IF EXISTS ${prefix}_app_all ON storage.objects;
CREATE POLICY ${prefix}_app_all ON storage.objects FOR ALL TO ${APP_ROLE}
  USING (bucket_id = '${bucket}') WITH CHECK (bucket_id = '${bucket}');

DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM storage.buckets WHERE id = '${bucket}') THEN
    RAISE EXCEPTION 'storage bucket ${bucket} was not created';
  END IF;
  IF (SELECT count(*) FROM pg_policies
      WHERE schemaname = 'storage' AND tablename = 'objects'
        AND policyname IN (
          '${prefix}_own_select',
          '${prefix}_own_insert',
          '${prefix}_own_update',
          '${prefix}_own_delete',
          '${prefix}_app_all'
        )) <> 5 THEN
    RAISE EXCEPTION 'storage policy contract incomplete for ${bucket}';
  END IF;
END
\$\$;
SQL
  echo "    storage bucket ${bucket} provisioned"
done <<< "${ROWS}"

echo "✓ storage contract for '${APP_NAME}' ready"
