#!/usr/bin/env bash
# tests/test-supabase-app-migrate.sh
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${DIR}/scripts/lib/supabase-migrate.sh"
. "${DIR}/scripts/lib/supabase-app-migrate.sh" || { echo "FAIL: lib sources"; exit 1; }
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
LOG="$(mktemp)"; trap 'rm -f "$LOG"' EXIT

# ---- sb_app_list_tables: reads source base tables ----
migrate_src_psql() { echo "src_psql $*" >> "$LOG"; printf 'businesses\nsms_logs\n'; }
migrate_dst_psql() { echo "dst_psql $*" >> "$LOG"; cat >/dev/null 2>&1 || true; }
OUT="$(sb_app_list_tables)"
[ "$OUT" = "businesses
sms_logs" ] && ok "list_tables returns source tables" || bad "list_tables returns source tables"

# ---- sb_app_dump_schema: pipes pg_dump into dst ----
migrate_src_pgdump() { echo "pgdump $*" >> "$LOG"; echo "CREATE TABLE public.x();"; }
migrate_dst_psql() { echo "dst_psql $*" >> "$LOG"; cat > /dev/null; }
sb_app_dump_schema && ok "dump_schema exits 0" || bad "dump_schema exits 0"
grep -q 'pgdump --clean --if-exists --schema-only --schema=public --no-owner' "$LOG" \
  && ok "pg_dump flags" || bad "pg_dump flags"

# ---- sb_app_copy_data: truncate-all + replica-mode copy + count verify ----
: > "$LOG"
migrate_src_psql() {
  echo "src_psql $*" >> "$LOG"
  case "$*" in
    *"copy ("*) echo "row1" ;;
    *count*) echo "1" ;;
    *) echo "" ;;
  esac
}
migrate_dst_psql() {
  echo "dst_psql $*" >> "$LOG"
  case "$*" in
    *count*) cat >/dev/null 2>&1 || true; echo "1" ;;
    *) cat > /dev/null 2>&1 || true ;;
  esac
}
sb_common_columns() { echo "id,name"; }   # isolate from column probing
sb_app_copy_data "businesses sms_logs" && ok "copy_data exits 0" || bad "copy_data exits 0"
grep -q 'truncate table public.businesses, public.sms_logs cascade' "$LOG" \
  && ok "single truncate-all cascade" || bad "single truncate-all cascade"
grep -q "session_replication_role" "$LOG" && ok "replica mode set" || bad "replica mode set"

# ---- count mismatch fails ----
migrate_dst_psql() { echo "dst_psql $*" >> "$LOG"; case "$*" in *count*) cat >/dev/null 2>&1||true; echo "0";; *) cat >/dev/null 2>&1||true;; esac; }
sb_app_copy_data "businesses" 2>/dev/null && bad "count mismatch fails" || ok "count mismatch fails"

# ---- sb_app_port_storage: buckets discovered with public flag; policies ported ----
: > "$LOG"
migrate_src_psql() {
  echo "src_psql $*" >> "$LOG"
  case "$*" in
    *from\ storage.buckets*) printf 'inspection_pdfs\tfalse\nreport_pdfs\ttrue\n' ;;
    *pg_policies*) printf '%s\n' \
      "create policy \"p1\" on storage.objects as permissive for select to authenticated using (true);" \
      "create policy \"p2\" on storage.objects as restrictive for select to authenticated using (true);" ;;
    *storage.objects*) printf '' ;;   # no objects to sync in this test
    *) echo "" ;;
  esac
}
# dst shim logs its stdin too, so DDL piped into it is assertable
migrate_dst_psql() { echo "dst_psql $*" >> "$LOG"; cat >> "$LOG" 2>/dev/null || true; }
migrate_curl() { echo "curl $*" >> "$LOG"; echo -n "200"; }
sb_app_port_storage "https://src.example" "srckey" "http://127.0.0.1:8010" "dstkey" \
  && ok "port_storage exits 0" || bad "port_storage exits 0"
grep -q '"public":false' "$LOG" && ok "bucket public flag honored" || bad "bucket public flag honored"
grep -q 'create policy' "$LOG" && ok "policies ported" || bad "policies ported"
grep -q 'lower(permissive)' "$LOG" && ok "generator emits AS clause" || bad "generator emits AS clause"
grep -q 'as restrictive' "$LOG" && ok "restrictive policy preserved" || bad "restrictive policy preserved"

# ---- sb_app_port_realtime_publication ----
: > "$LOG"
migrate_src_psql() {
  echo "src_psql $*" >> "$LOG"
  case "$*" in
    *pg_publication_tables*) printf 'public\tsms_logs\n' ;;
    *relreplident*) echo "f" ;;
    *) echo "" ;;
  esac
}
migrate_dst_psql() { echo "dst_psql $*" >> "$LOG"; cat >/dev/null 2>&1 || true; }
sb_app_port_realtime_publication && ok "port_publication exits 0" || bad "port_publication exits 0"
grep -q 'create publication supabase_realtime' "$LOG" && ok "publication ensured" || bad "publication ensured"
grep -q 'add table public.sms_logs' "$LOG" && ok "table added to publication" || bad "table added to publication"
grep -q 'replica identity full' "$LOG" && ok "replica identity ported" || bad "replica identity ported"

# ---- 21-migrate-app.sh preflight-only smoke (no docker needed) ----
T="$(mktemp -d)"; ORIG_HOME="${HOME:-}"
export HOME="$T/home"
mkdir -p "${HOME}/stacks/hia"
cat > "${HOME}/stacks/hia/.env" <<'EOF'
KONG_PORT=8010
SUPABASE_PUBLIC_URL=https://sb-hia.example.com
ANON_KEY=anonkey
SERVICE_ROLE_KEY=srkkey
POSTGRES_PASSWORD=pgpass
EOF
PREFLIGHT_OUT="$(printf '%s\n' "STACK_NAME=hia" "HOSTED_DB_URL=postgresql://x" \
  "HOSTED_SUPABASE_URL=https://src.example" "HOSTED_SERVICE_ROLE_KEY=srckey" \
  | MIGRATE_PREFLIGHT_ONLY=1 bash "${DIR}/scripts/21-migrate-app.sh" 2>&1)"
PREFLIGHT_RC=$?
export HOME="${ORIG_HOME}"
rm -rf "$T"
[ "$PREFLIGHT_RC" -eq 0 ] && ok "21-migrate-app.sh preflight exits 0" || bad "21-migrate-app.sh preflight exits 0"
grep -q "preflight OK" <<<"$PREFLIGHT_OUT" && ok "21-migrate-app.sh preflight OK message" || bad "21-migrate-app.sh preflight OK message"

echo; echo "${pass} passed, ${fail} failed"; [ "$fail" -eq 0 ]
