#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/assert.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; CORE="$T/core"; mkdir -p "$CORE" "$T/bin"
printf 'POSTGRES_PASSWORD=test-password\n' > "$CORE/.env"
: > "$CORE/docker-compose.yml"
export SQL_LOG="$T/sql.log"
cat > "$T/bin/docker" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SQL_LOG"
cat >> "$SQL_LOG"
SH
chmod +x "$T/bin/docker"; export PATH="$T/bin:$PATH"

run_storage() {
  printf '%s\n' \
    'APP_NAME=hia' \
    "CORE_STACK_DIR=$CORE" \
    'STORAGE_CONFIG_JSON={"buckets":[{"id":"inspection_pdfs","max_bytes":52428800,"mime_types":["application/pdf"]},{"id":"report_pdfs","max_bytes":52428800,"mime_types":["application/pdf"]}]}' \
    | bash "$HERE/../scripts/27-provision-app-storage.sh"
}

run_storage >/dev/null
assert_eq "bucket upserted" "$(grep -c "VALUES ('inspection_pdfs'" "$SQL_LOG")" "1"
assert_eq "private bucket forced" "$(grep -c 'public = false' "$SQL_LOG")" "2"
assert_eq "authenticated ownership policy" "$(grep -c 'storage.foldername(name).*auth.uid' "$SQL_LOG")" "10"
assert_eq "scoped app policy" "$(grep -c 'TO hia_owner' "$SQL_LOG")" "5"
assert_eq "policy completeness verified" "$(grep -c 'storage policy contract incomplete' "$SQL_LOG")" "2"

printf '%s\n' 'APP_NAME=hia' "CORE_STACK_DIR=$CORE" \
  'STORAGE_CONFIG_JSON={"buckets":[{"id":"bad'"'"';drop","max_bytes":1,"mime_types":["application/pdf"]}]}' \
  | bash "$HERE/../scripts/27-provision-app-storage.sh" >/dev/null 2>&1
assert_eq "SQL injection bucket rejected" "$?" "1"

finish
