# Ollie Hosted→Local Supabase Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate the two existing Ollie boxes (sandbox `olliesandbox.jnow.io`, prod `ollie.jnow.io`) off their hosted Supabase projects onto the local per-box stacks Plan 1 built, preserving user UUIDs and storage objects, then pause the hosted projects for the soak.

**Architecture:** A new `scripts/12-migrate-supabase.sh` (with a testable lib `scripts/lib/supabase-migrate.sh`) copies data from the hosted project into the already-deployed local stack: dynamic column-intersection `COPY` for `auth.users`/`auth.identities` + the six ollie-core tables (hosted GoTrue is newer than our pinned v2.177.0, so blind pg_dump would fail on unknown columns), REST-based sync for the `profile-images` bucket, then repoint (dashboard env + orchestrator env) reusing the existing `supabase-env.sh` helpers. A one-line compose-template fix wires `JWT_JWKS` into storage-api so browser (ES256) uploads work — closing the known storage gate. Sandbox first as the proving ground; prod repeats the identical procedure after its cloudflared/Google prep.

**Tech Stack:** bash, psql via docker (`postgres:17-alpine` client for the hosted side — client must be ≥ hosted server version; `docker compose exec db` for the local side), curl for Storage REST, existing `supabase-env.sh`/`supabase-stack-env.sh` helpers, bash test harness (`tests/lib/assert.sh` + shims).

## Global Constraints

- **Hosted projects are read-only to the migration** — the script may only `SELECT` from the hosted DB and `GET`/list via hosted REST. Never write, never delete. Decommission is a manual dashboard action after the 2-week soak (spec: "pause hosted projects for a 2-week soak, then delete and cancel the Pro org").
- **User UUIDs must be preserved** (spec: "preserving user UUIDs — `user_roles`/`run_owners` reference them").
- **Orchestrator SUPABASE_URL stays loopback** `http://127.0.0.1:8000` — never the public `sb-` hostname (Cloudflare bot protection 403-challenges non-browser clients).
- **Public hostnames use the single-level dash form** on jnow.io: `sb-olliesandbox.jnow.io`, `sb-ollie.jnow.io` (Universal SSL covers one subdomain level).
- **No new dependencies**: bash + docker + curl + python3 stdlib only (matches repo policy).
- **Idempotent + rollback-able**: re-running the migrate script must be safe (truncate-first copy, upsert storage sync, env writes idempotent); every env file it touches gets a timestamped `.bak` first.
- Source hosted projects: sandbox ref `mctnughllhcndngjqakt`, prod ref `kpdqhntsvjzhqjeupzsj`.
- Migrated tables, exact list — auth schema: `users`, `identities`; public schema: `agent_sessions`, `run_owners`, `user_roles`, `role_labels`, `user_tags`, `governance_events`. Storage: bucket `profile-images` (the only bucket Ollie uses; frontend `Profile.tsx` user-token upload + public read).
- **Sandbox before prod.** Prod cutover only proceeds after sandbox acceptance (John + Mike Google logins, whoami tiers, profile-image upload round-trip, gate 17/17).

---

## File Structure

```
scripts/lib/supabase-migrate.sh        # NEW — testable core: column intersection, COPY streaming,
                                       #   sequence fixup, bucket sync (callers inject psql/curl runners)
scripts/12-migrate-supabase.sh         # NEW — orchestration: stdin creds, preflight, backup, copy,
                                       #   storage sync, repoint, restart, verify, next-steps summary
templates/supabase/docker-compose.yml  # MODIFY — storage service gains JWT_JWKS env (ES256 verification)
docs/runbooks/self-hosted-supabase.md  # MODIFY — new §7 Migration (procedure, rollback, soak/decommission)
tests/test-supabase-migrate.sh         # NEW — shim-based tests for the lib + script preflight/stdin
```

---

### Task 1: Migration lib — column intersection, COPY, sequences, bucket sync

**Files:**
- Create: `scripts/lib/supabase-migrate.sh`
- Test: `tests/test-supabase-migrate.sh`

**Interfaces:**
- Consumes: nothing from other tasks. Callers must define two shell functions before calling: `migrate_src_psql` (runs psql against the HOSTED db; args appended to psql; reads stdin for `\copy ... from stdin`? no — src only ever SELECTs/COPY TO STDOUT) and `migrate_dst_psql` (runs psql against the LOCAL db, may read stdin). Both must behave like `psql` w.r.t. `-tAc` and exit codes.
- Produces (used verbatim by Task 2):
  - `sb_common_columns SCHEMA TABLE` → echoes a comma-separated list of quoted column names present in BOTH src and dst, excluding generated columns (e.g. `auth.users.confirmed_at` is `GENERATED ALWAYS`); returns 1 if empty.
  - `sb_copy_table SCHEMA TABLE` → truncates dst table (users uses CASCADE), streams `COPY (SELECT cols) TO STDOUT` from src into `COPY tbl (cols) FROM STDIN` on dst, then compares row counts; echoes `SCHEMA.TABLE: N rows`; returns 1 on count mismatch.
  - `sb_fix_sequences SCHEMA TABLE` → for every column with a serial/identity default, `setval(pg_get_serial_sequence(...), max(col))` on dst. No-op when none.
  - `sb_sync_bucket SRC_URL SRC_KEY DST_URL DST_KEY BUCKET` → ensures bucket exists on dst (public), lists object names+mimetypes from the src **DB** (`storage.objects`), downloads each via src REST, uploads to dst REST with `x-upsert: true`; echoes per-object lines and a final count; returns 1 if any transfer fails. Uses a `migrate_curl` function (default `curl`) so tests can shim it.

- [ ] **Step 1: Write the failing tests**

Create `tests/test-supabase-migrate.sh`:

```bash
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
    *information_schema.columns*) printf '%s\n' "$DST_COLS" ;;
    *"count(*)"*)                 printf '%s\n' "$DST_COUNT" ;;
    *TRUNCATE*|*truncate*)        echo "$sql" >> "$DST_SQL_LOG"; return 0 ;;
    *"from stdin"*|*"FROM STDIN"*) cat > "$DST_INPUT_FILE" ;;
    *nextval*)                    printf '%s\n' "${DST_SERIAL_COLS:-}" ;;
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/test-supabase-migrate.sh`
Expected: FAIL — `scripts/lib/supabase-migrate.sh: No such file or directory`

- [ ] **Step 3: Implement the lib**

Create `scripts/lib/supabase-migrate.sh`:

```bash
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
    migrate_dst_psql -c "select setval(pg_get_serial_sequence('${schema}.${table}','${col}'), coalesce((select max(${col}) from ${schema}.${table}), 1));" || return 1
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/test-supabase-migrate.sh`
Expected: all assertions `ok`, `N/N passed`

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/supabase-migrate.sh tests/test-supabase-migrate.sh
git commit -m "feat(migrate): column-intersection copy + bucket sync lib"
```

---

### Task 2: 12-migrate-supabase.sh — orchestration

**Files:**
- Create: `scripts/12-migrate-supabase.sh`
- Test: `tests/test-supabase-migrate.sh` (append script-level tests)

**Interfaces:**
- Consumes: Task 1's `sb_copy_table`, `sb_fix_sequences`, `sb_sync_bucket`; existing `scripts/lib/supabase-env.sh` (`supabase_write_stack_dashboard_env STACK_ENV URL ANON`, `supabase_write_orch_env URL KEY`, `supabase_schema_probe_url URL`) and `scripts/lib/supabase-stack-env.sh` (`supabase_stack_env_val FILE KEY`).
- Produces: the operator-facing migration command used verbatim by Tasks 4–6. stdin contract (KEY=VALUE lines, stdin so secrets never hit argv):
  - `HOSTED_DB_URL=postgresql://…` (required — Session-pooler connection string from the hosted dashboard)
  - `HOSTED_SUPABASE_URL=https://<ref>.supabase.co` (required)
  - `HOSTED_SERVICE_ROLE_KEY=…` (required)
- Env overrides for tests: `SB_DIR`, `STACK_ENV`, `ORCH_ENV`, `MIGRATE_PG_IMAGE` (default `postgres:17-alpine`), `MIGRATE_PREFLIGHT_ONLY=1` (stop after preflight — lets tests exercise stdin/preflight without docker).

- [ ] **Step 1: Append the failing script-level tests**

Append to `tests/test-supabase-migrate.sh` (before the test-invocation list at the bottom; add the new test names to that list):

```bash
MIGRATE="$HERE/../scripts/12-migrate-supabase.sh"

test_migrate_requires_all_stdin_keys() {
  local d; d="$(mktemp -d)"
  out="$(printf 'HOSTED_DB_URL=postgresql://x\n' | SB_DIR="$d" STACK_ENV="$d/stack.env" ORCH_ENV="$d/orch.env" MIGRATE_PREFLIGHT_ONLY=1 bash "$MIGRATE" 2>&1)"; rc=$?
  assert_eq "missing keys exit 1" "$rc" "1"
  assert_eq "names the missing key" "$(echo "$out" | grep -c 'HOSTED_SUPABASE_URL')" "1"
}

test_migrate_requires_deployed_stack() {
  local d; d="$(mktemp -d)"   # no .env in SB_DIR -> stack not deployed
  out="$(printf 'HOSTED_DB_URL=postgresql://x\nHOSTED_SUPABASE_URL=https://abc.supabase.co\nHOSTED_SERVICE_ROLE_KEY=k\n' \
    | SB_DIR="$d" STACK_ENV="$d/stack.env" ORCH_ENV="$d/orch.env" MIGRATE_PREFLIGHT_ONLY=1 bash "$MIGRATE" 2>&1)"; rc=$?
  assert_eq "undeployed stack exit 1" "$rc" "1"
  assert_eq "points at --deploy" "$(echo "$out" | grep -c '11-install-supabase.sh --deploy')" "1"
}

test_migrate_preflight_ok_with_deployed_stack() {
  local d; d="$(mktemp -d)"
  printf 'SUPABASE_PUBLIC_URL=https://sb-x.jnow.io\nANON_KEY=a\nSERVICE_ROLE_KEY=s\nPOSTGRES_PASSWORD=p\n' > "$d/.env"
  printf 'SUPABASE_URL=old\n' > "$d/stack.env"
  out="$(printf 'HOSTED_DB_URL=postgresql://x\nHOSTED_SUPABASE_URL=https://abc.supabase.co\nHOSTED_SERVICE_ROLE_KEY=k\n' \
    | SB_DIR="$d" STACK_ENV="$d/stack.env" ORCH_ENV="$d/orch.env" MIGRATE_PREFLIGHT_ONLY=1 bash "$MIGRATE" 2>&1)"; rc=$?
  assert_eq "preflight-only exit 0" "$rc" "0"
  assert_eq "announces plan" "$(echo "$out" | grep -c 'preflight OK')" "1"
}
```

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `bash tests/test-supabase-migrate.sh`
Expected: Task-1 tests pass; new tests FAIL (`12-migrate-supabase.sh: No such file or directory`)

- [ ] **Step 3: Implement the script**

Create `scripts/12-migrate-supabase.sh`:

```bash
#!/usr/bin/env bash
# 12-migrate-supabase.sh — migrate a hosted Supabase project's Ollie data into
# this box's LOCAL supabase stack, then repoint the dashboard + orchestrator.
#
# Run as: the service user. The local stack must already be deployed
# (11-install-supabase.sh --deploy). Idempotent: truncate-first copy, upsert
# storage sync, env writes overwrite the same keys. The HOSTED side is only
# ever read (SELECT / COPY TO STDOUT / REST GET).
#
# Input (stdin, KEY=VALUE lines — secrets never in argv):
#   HOSTED_DB_URL=postgresql://postgres.<ref>:<pass>@…pooler.supabase.com:5432/postgres
#   HOSTED_SUPABASE_URL=https://<ref>.supabase.co
#   HOSTED_SERVICE_ROLE_KEY=<service role key>
#
# Copies (UUID-preserving): auth.users, auth.identities, then public
# agent_sessions, run_owners, user_roles, role_labels, user_tags,
# governance_events; then syncs the profile-images storage bucket.
set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  echo "error: run as the service user, not root" >&2; exit 1
fi
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/lib/supabase-env.sh"
. "${SCRIPT_DIR}/lib/supabase-stack-env.sh"
. "${SCRIPT_DIR}/lib/supabase-migrate.sh"

SB_DIR="${SB_DIR:-$HOME/supabase-stack}"
STACK_ENV="${STACK_ENV:-$HOME/hermes-stack/.env}"
ORCH_ENV="${ORCH_ENV:-$HOME/.config/ollie-orchestrator/.env}"
MIGRATE_PG_IMAGE="${MIGRATE_PG_IMAGE:-postgres:17-alpine}"

AUTH_TABLES=(users identities)
PUBLIC_TABLES=(agent_sessions run_owners user_roles role_labels user_tags governance_events)
BUCKET="profile-images"

# ---- stdin ------------------------------------------------------------------
HOSTED_DB_URL="" ; HOSTED_SUPABASE_URL="" ; HOSTED_SERVICE_ROLE_KEY=""
while IFS='=' read -r k v || [[ -n "${k:-}" ]]; do
  case "${k}" in
    HOSTED_DB_URL) HOSTED_DB_URL="${v}" ;;
    HOSTED_SUPABASE_URL) HOSTED_SUPABASE_URL="${v}" ;;
    HOSTED_SERVICE_ROLE_KEY) HOSTED_SERVICE_ROLE_KEY="${v}" ;;
  esac
done
MISSING=""
[[ -z "${HOSTED_DB_URL}" ]] && MISSING="${MISSING} HOSTED_DB_URL"
[[ -z "${HOSTED_SUPABASE_URL}" ]] && MISSING="${MISSING} HOSTED_SUPABASE_URL"
[[ -z "${HOSTED_SERVICE_ROLE_KEY}" ]] && MISSING="${MISSING} HOSTED_SERVICE_ROLE_KEY"
if [[ -n "${MISSING}" ]]; then
  echo "error: missing required stdin key(s):${MISSING}" >&2; exit 1
fi

# ---- preflight ---------------------------------------------------------------
echo "==> migrate 1: preflight"
if [[ ! -f "${SB_DIR}/.env" ]]; then
  echo "error: ${SB_DIR}/.env not found — deploy the local stack first: bash ~/ollie-hermes-install/scripts/11-install-supabase.sh --deploy" >&2
  exit 1
fi
LOCAL_PUBLIC_URL="$(supabase_stack_env_val "${SB_DIR}/.env" SUPABASE_PUBLIC_URL)"
LOCAL_ANON_KEY="$(supabase_stack_env_val "${SB_DIR}/.env" ANON_KEY)"
LOCAL_SERVICE_KEY="$(supabase_stack_env_val "${SB_DIR}/.env" SERVICE_ROLE_KEY)"
LOCAL_PGPASS="$(supabase_stack_env_val "${SB_DIR}/.env" POSTGRES_PASSWORD)"
for v in LOCAL_PUBLIC_URL LOCAL_ANON_KEY LOCAL_SERVICE_KEY LOCAL_PGPASS; do
  if [[ -z "${!v}" ]]; then echo "error: ${v} empty in ${SB_DIR}/.env — stack env incomplete" >&2; exit 1; fi
done
echo "    preflight OK — local stack env present (${LOCAL_PUBLIC_URL})"
if [[ "${MIGRATE_PREFLIGHT_ONLY:-0}" == "1" ]]; then exit 0; fi

# psql runners for the lib. Hosted client must be >= hosted server version —
# use a modern client container. --network host: plain egress, no bridge DNS quirks.
migrate_src_psql() {
  docker run --rm -i --network host "${MIGRATE_PG_IMAGE}" \
    psql "${HOSTED_DB_URL}" -v ON_ERROR_STOP=1 "$@"
}
migrate_dst_psql() {
  docker compose -f "${SB_DIR}/docker-compose.yml" --env-file "${SB_DIR}/.env" \
    exec -T -e PGPASSWORD="${LOCAL_PGPASS}" db \
    psql -h 127.0.0.1 -U supabase_admin -d postgres -v ON_ERROR_STOP=1 "$@" </dev/stdin
}

echo "==> migrate 2: connectivity checks"
SRC_VER="$(migrate_src_psql -tAc 'show server_version' </dev/null)" \
  || { echo "error: cannot reach hosted DB — check HOSTED_DB_URL (use the Session pooler string)" >&2; exit 1; }
echo "    hosted postgres ${SRC_VER} ✓"
migrate_dst_psql -tAc 'select 1' </dev/null >/dev/null \
  || { echo "error: local supabase db container not reachable" >&2; exit 1; }
LEDGER="$(migrate_dst_psql -tAc "select count(*) from public._ollie_core_migrations" </dev/null || echo 0)"
if [[ "${LEDGER}" -lt 6 ]]; then
  echo "error: ollie-core migrations not fully applied locally (ledger=${LEDGER}) — re-run 11-install-supabase.sh --deploy" >&2
  exit 1
fi
echo "    local stack ledger ${LEDGER} migrations ✓"

echo "==> migrate 3: backups"
TS="$(date +%Y%m%d-%H%M%S)"
for f in "${STACK_ENV}" "${ORCH_ENV}"; do
  if [[ -f "$f" ]]; then cp "$f" "${f}.bak-migrate-${TS}"; echo "    ${f}.bak-migrate-${TS}"; fi
done

echo "==> migrate 4: copy tables (truncate-first, UUID-preserving)"
for t in "${AUTH_TABLES[@]}"; do sb_copy_table auth "$t"; sb_fix_sequences auth "$t"; done
for t in "${PUBLIC_TABLES[@]}"; do sb_copy_table public "$t"; sb_fix_sequences public "$t"; done

echo "==> migrate 5: sync storage bucket ${BUCKET}"
sb_sync_bucket "${HOSTED_SUPABASE_URL}" "${HOSTED_SERVICE_ROLE_KEY}" \
  "http://127.0.0.1:8000" "${LOCAL_SERVICE_KEY}" "${BUCKET}"

echo "==> migrate 6: repoint dashboard + orchestrator at the local stack"
if supabase_write_stack_dashboard_env "${STACK_ENV}" "${LOCAL_PUBLIC_URL}" "${LOCAL_ANON_KEY}"; then
  docker compose -f "$(dirname "${STACK_ENV}")/docker-compose.yml" up -d dashboard
else
  echo "error: ${STACK_ENV} missing — is the hermes stack installed?" >&2; exit 1
fi
supabase_write_orch_env "http://127.0.0.1:8000" "${LOCAL_SERVICE_KEY}"
systemctl --user restart ollie-orchestrator
set +e
for i in $(seq 1 10); do
  HEALTH=$(curl -s -m 5 http://localhost:9123/healthz || echo "")
  [[ "${HEALTH}" == *'"status":"ok"'* ]] && break
  sleep 2
done
set -e
if [[ "${HEALTH:-}" != *'"status":"ok"'* ]]; then
  echo "error: orchestrator did not come back healthy — rollback: restore ${ORCH_ENV}.bak-migrate-${TS} and restart" >&2
  exit 1
fi

echo "==> migrate 7: verify local schema serves migrated data"
PROBE="$(supabase_schema_probe_url "http://127.0.0.1:8000")"
CODE="$(curl -s -o /dev/null -w '%{http_code}' -m 15 \
  -H "apikey: ${LOCAL_SERVICE_KEY}" -H "Authorization: Bearer ${LOCAL_SERVICE_KEY}" "${PROBE}" || echo 000)"
[[ "${CODE}" == "200" ]] || { echo "error: local schema probe HTTP ${CODE}" >&2; exit 1; }
ROLES_N="$(migrate_dst_psql -tAc 'select count(*) from public.user_roles' </dev/null)"
echo "    local user_roles rows: ${ROLES_N}"

echo
echo "✓ migration complete — box now runs on the local stack."
echo "  Next (operator):"
echo "   1. Browser Google login at the dashboard (existing users keep their UUIDs; everyone re-logs-in once)."
echo "   2. OPERATOR_EMAIL=<you> bash ~/ollie-hermes-install/scripts/check-box-config.sh"
echo "   3. If this box is enrolled in Fleet: update the instance's Access tab to"
echo "      ${LOCAL_PUBLIC_URL} + the local anon/service keys, then Apply."
echo "   4. PAUSE (do not delete) the hosted project — 2-week soak per the runbook."
echo "  Rollback: restore ${STACK_ENV}.bak-migrate-${TS} and ${ORCH_ENV}.bak-migrate-${TS},"
echo "  then: docker compose -f $(dirname "${STACK_ENV}")/docker-compose.yml up -d dashboard && systemctl --user restart ollie-orchestrator"
```

Note on `migrate_dst_psql` and stdin: `docker compose exec -T … </dev/stdin` inherits the caller's stdin for `COPY … FROM STDIN` while remaining safe when callers pass `</dev/null`. **Do not call it bare inside loops that read from a `while read` file descriptor** — the lib only feeds it stdin in `sb_copy_table`'s pipeline, and every other invocation in this script passes `</dev/null` explicitly (the `docker exec -T eats the surrounding script's stdin` lesson from the deploy work).

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/test-supabase-migrate.sh`
Expected: all pass (lib + script-level)

- [ ] **Step 5: Run the full repo test suite**

Run: `for t in tests/test-*.sh; do echo "== $t"; bash "$t" || exit 1; done`
Expected: all suites pass

- [ ] **Step 6: Commit**

```bash
git add scripts/12-migrate-supabase.sh tests/test-supabase-migrate.sh
git commit -m "feat(migrate): 12-migrate-supabase.sh hosted->local cutover script"
```

---

### Task 3: Storage ES256 fix — wire JWT_JWKS into storage-api

**Files:**
- Modify: `templates/supabase/docker-compose.yml` (storage service `environment:` block)
- Test: `tests/test-supabase-migrate.sh` (append one grep test)

**Interfaces:**
- Consumes: the stack `.env` already renders `JWT_JWKS` (from `gen-supabase-keys.py` → `supabase-stack-env.sh`); PostgREST already consumes it.
- Produces: storage-api verifies browser ES256 user tokens → the frontend `profile-images` upload works on the local stack. Boxes pick this up by re-running `11-install-supabase.sh --deploy` (compose file is re-copied; env carries forward).

- [ ] **Step 1: Append the failing test**

Append to `tests/test-supabase-migrate.sh` (and add the name to the invocation list):

```bash
test_storage_gets_jwt_jwks() {
  local compose="$HERE/../templates/supabase/docker-compose.yml"
  # The JWT_JWKS line must appear inside the storage service block (between
  # 'storage:' and the next top-level service key).
  block="$(awk '/^  storage:/{f=1} f&&/^  [a-z]/&&!/^  storage:/{f=0} f' "$compose")"
  assert_eq "storage has JWT_JWKS" "$(echo "$block" | grep -c 'JWT_JWKS=\${JWT_JWKS}')" "1"
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test-supabase-migrate.sh`
Expected: `storage has JWT_JWKS` assertion fails (count 0)

- [ ] **Step 3: Add the env line**

In `templates/supabase/docker-compose.yml`, inside the `storage:` service's `environment:` list, directly below the existing `PGRST_JWT_SECRET` line, add:

```yaml
      # JWKS (EC public + legacy symmetric) so storage verifies browser ES256
      # user tokens — PGRST_JWT_SECRET alone only verifies HS256 (anon/service),
      # which 403'd user-token uploads (profile-images). Supabase self-hosted
      # signing-keys doc: storage consumes JWT_JWKS.
      - JWT_JWKS=${JWT_JWKS}
```

(Keep the existing `PGRST_JWT_SECRET` line — HS256 anon/service verification unchanged.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/test-supabase-migrate.sh`
Expected: all pass

- [ ] **Step 5: Commit**

```bash
git add templates/supabase/docker-compose.yml tests/test-supabase-migrate.sh
git commit -m "fix(supabase): storage verifies ES256 user tokens via JWT_JWKS"
```

---

### Task 4: Runbook §7 — migration procedure, rollback, soak/decommission

**Files:**
- Modify: `docs/runbooks/self-hosted-supabase.md` (append new section `## 7. Migrating a hosted project onto the box (cutover)`)

**Interfaces:**
- Consumes: Task 2's stdin contract and next-steps output; Task 3's re-deploy note.
- Produces: the operator procedure Tasks 5 and 6 execute verbatim.

- [ ] **Step 1: Append §7 to the runbook**

Add to `docs/runbooks/self-hosted-supabase.md`:

```markdown
## 7. Migrating a hosted project onto the box (cutover)

Order matters: sandbox first (proving ground), prod only after sandbox
acceptance. The hosted project is never written to — pause it (don't delete)
after cutover for the 2-week soak.

### 7.1 Gather hosted credentials (operator, per project)

From the hosted dashboard (sandbox `mctnughllhcndngjqakt`, prod
`kpdqhntsvjzhqjeupzsj`):
- **Connect → Session pooler** connection string → `HOSTED_DB_URL`
  (IPv4-safe; the direct `db.<ref>.supabase.co` host is IPv6-only).
- **Settings → API** → `HOSTED_SUPABASE_URL` (`https://<ref>.supabase.co`)
  and the `service_role` key → `HOSTED_SERVICE_ROLE_KEY`.

### 7.2 Prep (prod box only — sandbox already has these from Plan 1)

1. cloudflared public hostname `sb-ollie` → `HTTP` → `localhost:8000`
   (dash form — see §2).
2. Google console: add redirect URI
   `https://sb-ollie.jnow.io/auth/v1/callback` to the instance's OAuth client.
3. Deploy the local stack (as the service user, repo at the current pin):

       cd ~/ollie-hermes-install && git fetch origin && git checkout --detach origin/master
       printf 'SUPABASE_PUBLIC_URL=https://sb-ollie.jnow.io\nSITE_URL=https://ollie.jnow.io\nGOOGLE_CLIENT_ID=<id>\nGOOGLE_CLIENT_SECRET=<secret>\n' \
         | bash scripts/11-install-supabase.sh --deploy

   NOTE: --deploy repoints the dashboard at the (empty) local stack. Run 7.3
   immediately after — until then, logins would mint new UUIDs (they get
   truncated by the migrate anyway, but treat deploy→migrate as one
   maintenance window).

   On a box whose stack pre-dates the storage JWT_JWKS fix (sandbox), re-run
   --deploy with empty stdin to refresh the compose file (env carries
   forward): `printf '' | bash scripts/11-install-supabase.sh --deploy`

### 7.3 Migrate

    printf 'HOSTED_DB_URL=<pooler-conn-string>\nHOSTED_SUPABASE_URL=https://<ref>.supabase.co\nHOSTED_SERVICE_ROLE_KEY=<key>\n' \
      | bash ~/ollie-hermes-install/scripts/12-migrate-supabase.sh

Copies auth.users + auth.identities (UUIDs preserved; sessions dropped —
everyone re-logs-in once) + the six ollie-core tables + the profile-images
bucket, then repoints dashboard + orchestrator (loopback) and restarts.
Idempotent — re-run freely; the hosted side is read-only to it.

### 7.4 Acceptance (per box)

1. Browser Google login at the dashboard (John; on sandbox also Mike) —
   whoami tier correct, agents visible, session list/transcripts load.
2. Profile page: upload a profile image, confirm it renders (this exercises
   the ES256 storage path — the JWT_JWKS fix).
3. `OPERATOR_EMAIL=<you> bash ~/ollie-hermes-install/scripts/check-box-config.sh`
   → `OK: box config is done-done`.
4. Fleet (enrolled boxes): instance → Access tab → set the sb- URL + local
   anon/service keys (printed by --deploy; also in ~/supabase-stack/.env) →
   Save → Apply. This prevents a later Fleet apply from repointing the box
   back at the paused hosted project.
5. Exposure: `nmap`-style check unchanged — only :22 open; sb- host serves
   only via cloudflared.

### 7.5 Soak + decommission

1. Hosted dashboard → pause the project (sandbox first, prod after its own
   acceptance). Do NOT delete yet.
2. Soak 2 weeks. Anything breaks → unpause + rollback (7.6) and investigate.
3. After both projects have soaked clean: delete both projects, then cancel
   the Pro org. (jnow-site/airesume/GetBilled-app move in the apps-VPS plan —
   don't cancel the org until THEY are off hosted too.)

### 7.6 Rollback (per box)

The migrate script backs up both env files with a `.bak-migrate-<ts>` suffix
and prints the exact restore commands. Manual form:

    cp ~/hermes-stack/.env.bak-migrate-<ts> ~/hermes-stack/.env
    cp ~/.config/ollie-orchestrator/.env.bak-migrate-<ts> ~/.config/ollie-orchestrator/.env
    docker compose -f ~/hermes-stack/docker-compose.yml up -d dashboard
    systemctl --user restart ollie-orchestrator

(If the hosted project was already paused, unpause it first.)
```

- [ ] **Step 2: Cross-link from §1 prereqs**

In the runbook's §1 Prereqs, add one line: `- Migrating an existing hosted project onto this box? See §7.`

- [ ] **Step 3: Commit**

```bash
git add docs/runbooks/self-hosted-supabase.md
git commit -m "docs(supabase): runbook §7 hosted->local migration + soak/decommission"
```

---

### Task 5: LIVE — sandbox cutover + acceptance (JOHN GATE)

No repo files — live execution of §7 on `olliesandbox.jnow.io`, driven from this session with John doing dashboard/browser steps.

**Needs John:** hosted sandbox credentials (7.1: pooler string, url, service key — Obsidian or pasted at run time), and the login checks (John + Mike).

- [ ] **Step 1: Push Tasks 1–4; update the sandbox box checkout** to the new master SHA (`git fetch && git checkout --detach <sha>` as the service user). Also bump ollie-fleet `INSTALL_REPO_REF` to the same SHA and redeploy fleet-prod (same procedure as the Plan-2 pin bump) so newly provisioned boxes get the storage fix.
- [ ] **Step 2: Refresh the stack** for the storage fix: `printf '' | bash scripts/11-install-supabase.sh --deploy` (carries env forward, re-copies compose, recreates storage with JWT_JWKS).
- [ ] **Step 3: Run 7.3** with the sandbox hosted creds. Expected: per-table `N rows` lines with matching counts, `profile-images: N object(s) synced`, `✓ migration complete`.
- [ ] **Step 4: Acceptance 7.4** — John + Mike Google logins (John's hosted UUID must survive: `whoami` returns `platform_operator` for the SAME uid as hosted), profile-image upload round-trip, gate 17/17, Fleet Access tab update if sandbox is enrolled.
- [ ] **Step 5: Pause the hosted sandbox project** (John, dashboard). Soak clock starts.
- [ ] **Step 6: Record in the SDD ledger** (commits, row counts, acceptance results).

---

### Task 6: LIVE — prod cutover + pause (JOHN GATE, after sandbox soak-start)

Live execution of §7 on `ollie.jnow.io`. Prod has NO local stack yet — full §7.2 prep applies.

**Needs John:** cloudflared `sb-ollie` route + Google redirect URI (7.2 steps 1–2), prod Google client id/secret, hosted prod credentials (7.1), and the login checks.

- [ ] **Step 1: John does 7.2 prep steps 1–2** (tunnel route `sb-ollie` → `localhost:8000`, Google redirect URI).
- [ ] **Step 2: Update prod box checkout** to the same pinned SHA; run 7.2 step 3 (`--deploy` with prod URLs + Google creds via stdin). Expected: `✓ Supabase deployed locally`, keys printed.
- [ ] **Step 3: Immediately run 7.3** with prod hosted creds (deploy→migrate = one maintenance window).
- [ ] **Step 4: Acceptance 7.4** — logins, profile image, gate, **Fleet Access tab update (prod IS enrolled — this step is mandatory here)**.
- [ ] **Step 5: Pause the hosted prod project** (John). Soak clock starts.
- [ ] **Step 6: Ledger + OB1 capture**; schedule the soak-end checklist (7.5 step 3) ~2 weeks out — decommission blocks on the apps-VPS plan finishing too.
