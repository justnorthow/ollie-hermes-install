#!/usr/bin/env bash
# tests/test-app-migrations.sh — direct checks for the migration runner.
set -uo pipefail
# lastpipe: without it, the right side of every `| psql_fn` pipe below runs in
# a forked subshell, so rec_psql's `n` counter resets each call and every
# apply overwrites APPLIES/1.sql instead of advancing to 2.sql, 3.sql, ... —
# a bash pipe-subshell artifact in this test's own bookkeeping, unrelated to
# app-migrations.sh's behavior (confirmed by inspecting CALLS/APPLIED_LIST,
# which are appended via `>>` and are therefore unaffected either way).
shopt -s lastpipe
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

FIXTURE_MIG_DIR="$T/migs"; mkdir -p "$FIXTURE_MIG_DIR"
printf 'select 1;\n' > "$FIXTURE_MIG_DIR/0002_second.sql"
printf 'select 0;\n' > "$FIXTURE_MIG_DIR/0001_first.sql"
export FIXTURE_MIG_DIR

# fake docker: create/cp/rm only — the runner's psql goes through PSQL_FN
cat > "$T/bin/docker" <<'SH'
#!/usr/bin/env bash
case "$1" in
  create) echo "ctr-1" ;;
  cp)     cp "${FIXTURE_MIG_DIR}"/*.sql "$3" 2>/dev/null || true ;;
  rm)     : ;;
esac
exit 0
SH
chmod +x "$T/bin/docker"
export PATH="$T/bin:$PATH"

. "${DIR}/scripts/lib/app-migrations.sh"

# ---- 1. applies in filename order, one call per file, INSERT in the same call
CALLS="$T/calls"; APPLIES="$T/applies"; mkdir -p "$APPLIES"; : > "$CALLS"
APPLIED_LIST="$T/applied"; : > "$APPLIED_LIST"
n=0
rec_psql() {
  local args="$*"
  echo "${args}" >> "$CALLS"
  if [[ "${args}" == *"-1 -f -"* ]]; then
    n=$((n+1)); cat > "${APPLIES}/${n}.sql"
    sed -nE "s/.*values \('([^']+)'\).*/\1/p" "${APPLIES}/${n}.sql" | tail -1 >> "${APPLIED_LIST}"
    return 0
  fi
  if [[ "${args}" == *"select 1 from "* ]]; then
    local want; want="$(printf '%s' "${args}" | sed -nE "s/.*name='([^']+)'.*/\1/p")"
    grep -qxF "${want}" "${APPLIED_LIST}" 2>/dev/null && echo 1
  fi
  return 0
}
app_migrations_apply img rec_psql hia._migrations >/dev/null

[[ "$(sed -n '1p' "${APPLIED_LIST}")" == "0001_first.sql" ]] \
  && ok "applies in filename order, not directory order" || bad "wrong apply order"
grep -q 'create table if not exists hia._migrations' "$CALLS" \
  && ok "tracker created in the app schema, not public" || bad "tracker not created in the app schema"
grep -q 'public._app_migrations' "$CALLS" \
  && bad "still references public._app_migrations" || ok "no reference to public._app_migrations"
grep -q "insert into hia._migrations" "${APPLIES}/1.sql" \
  && ok "tracker INSERT travels in the same call as the file" || bad "tracker INSERT is a separate call"
grep -q 'select 0;' "${APPLIES}/1.sql" \
  && ok "the migration file content is in that same call" || bad "file content missing from the apply call"

# ---- 2. skips an already-applied migration
: > "$CALLS"; rm -f "${APPLIES}"/*.sql
printf '0001_first.sql\n' > "${APPLIED_LIST}"
n=0
OUT="$(app_migrations_apply img rec_psql hia._migrations)"
grep -q 'skip 0001_first.sql (applied)' <<<"$OUT" \
  && ok "skips an already-applied migration" || bad "did not skip an applied migration"
grep -q 'apply 0002_second.sql' <<<"$OUT" \
  && ok "still applies the unapplied one" || bad "skipped an unapplied migration"

# ---- 3. a failing apply propagates (caller must not continue)
: > "${APPLIED_LIST}"
fail_psql() {
  [[ "$*" == *"-1 -f -"* ]] && { cat >/dev/null; return 1; }
  return 0
}
( set -e; app_migrations_apply img fail_psql hia._migrations >/dev/null ) \
  && bad "a failing apply was swallowed" || ok "a failing apply propagates to the caller"

echo; echo "${pass} passed, ${fail} failed"; [ "$fail" -eq 0 ]
