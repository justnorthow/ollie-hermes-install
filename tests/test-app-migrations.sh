#!/usr/bin/env bash
# tests/test-app-migrations.sh — direct checks for the migration runner.
set -uo pipefail
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

declare -F app_migrations_apply >/dev/null \
  && ok "app_migrations_apply is defined" || bad "app_migrations_apply is NOT defined"

# ---- 1. applies in filename order, one call per file, INSERT in the same call
CALLS="$T/calls"; APPLIES="$T/applies"; mkdir -p "$APPLIES"; : > "$CALLS"
APPLIED_LIST="$T/applied"; : > "$APPLIED_LIST"
# Counter lives in a file, not a shell variable: rec_psql runs as the
# right-hand side of `| psql_fn` inside the lib, and every stage of a
# pipeline (including the last) executes in its own forked subshell unless
# `shopt -s lastpipe` is on AND job control is off — neither of which this
# suite can assume for every caller (sourced execution, `set -m`, CI
# wrappers). A shell-variable counter's increments would die with that
# subshell; a file survives across forks unconditionally, mirroring the
# APPLY_COUNT_FILE idiom in tests/test-24-install-agent-apps.sh.
APPLY_COUNT_FILE="$T/apply-count"; rm -f "${APPLY_COUNT_FILE}"
rec_psql() {
  local args="$*"
  echo "${args}" >> "$CALLS"
  if [[ "${args}" == *"-1 -f -"* ]]; then
    local idx=0
    [[ -f "${APPLY_COUNT_FILE}" ]] && idx="$(cat "${APPLY_COUNT_FILE}")"
    idx=$((idx+1)); echo "${idx}" > "${APPLY_COUNT_FILE}"
    cat > "${APPLIES}/${idx}.sql"
    sed -nE "s/.*values \('([^']+)'\).*/\1/p" "${APPLIES}/${idx}.sql" | tail -1 >> "${APPLIED_LIST}"
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
rm -f "${APPLY_COUNT_FILE}"
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

# ---- 4. RLS gate: FAILING direction first
#
# The existence check below is NOT redundant. Without it, this block passes
# before the feature is written: an undefined function makes the subshell exit
# non-zero, and the `||` branch reads that as "the gate correctly refused".
# That is the same class of lying probe this gate exists to prevent, so the
# absence of the function has to be its own assertion.
declare -F app_migrations_rls_gate >/dev/null \
  && ok "app_migrations_rls_gate is defined" || bad "app_migrations_rls_gate is NOT defined"

gate_psql_bad() {  # one table without RLS
  [[ "$*" == *"relrowsecurity"* ]] && { echo "reports"; return 0; }
  return 0
}
( set -e; app_migrations_rls_gate gate_psql_bad hia >"$T/gate.log" 2>&1 ) \
  && bad "RLS gate passed a schema with an unprotected table" \
  || ok "RLS gate FAILS on a table without RLS"
grep -q 'reports' "$T/gate.log" \
  && ok "gate names the offending table" || bad "gate does not name the table"
grep -qi 'anon' "$T/gate.log" \
  && ok "gate explains the shared-anon-key consequence" || bad "gate message lacks the reason"

# ---- 5. RLS gate: passing direction
gate_psql_ok() { return 0; }   # empty result = every table protected
( set -e; app_migrations_rls_gate gate_psql_ok hia >/dev/null 2>&1 ) \
  && ok "RLS gate passes when every table has RLS" || bad "RLS gate false-failed"

# ---- 6. the gate runs as part of an apply, after the migrations
: > "$CALLS"; : > "${APPLIED_LIST}"; rm -f "${APPLY_COUNT_FILE}"
app_migrations_apply img rec_psql hia._migrations hia >/dev/null 2>&1
grep -q 'relrowsecurity' "$CALLS" \
  && ok "apply runs the RLS gate" || bad "apply did not run the RLS gate"
tail -1 "$CALLS" | grep -q 'relrowsecurity' \
  && ok "the gate runs AFTER the migrations, not before" || bad "gate ran before the migrations finished"

echo; echo "${pass} passed, ${fail} failed"; [ "$fail" -eq 0 ]
