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
# rec_psql discriminates FOUR distinct queries by text unique to each one —
# NOT by a broad substring like bare "pg_namespace", which appears in BOTH
# the gate's existence probe (its own query) AND the gate's main
# unprotected-tables query (via that query's "join pg_namespace n on ..."
# clause). Matching the broad substring first would answer the main query
# with "1" too, and the gate would read that as an offending table
# literally named "1" — failing a gated apply on a schema where nothing is
# wrong. (This exact mistake shipped once already; see the review note in
# the git history for this file.)
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
  elif [[ "${args}" == *"relrowsecurity"* || "${args}" == *"pg_class"* ]]; then
    # The gate's main unprotected-tables query. "relrowsecurity"/"pg_class"
    # appear in NO other query this double sees. Empty result = no
    # unprotected tables, i.e. a clean fixture.
    return 0
  elif [[ "${args}" == *"from pg_namespace where nspname"* ]]; then
    # The gate's schema-existence probe — matched on the full phrase, not
    # the bare "pg_namespace" table name the main query above also contains.
    echo 1
    return 0
  elif [[ "${args}" == *"where name='"* ]]; then
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

gate_psql_bad() {  # schema exists (pg_namespace probe); one table without RLS
  # NOTE: the unprotected-tables query itself also contains the substring
  # "pg_namespace" (it joins against it), so the relrowsecurity branch MUST
  # be checked first — a case statement takes the first match, and if
  # pg_namespace were checked first it would swallow that call too.
  case "$*" in
    *relrowsecurity*) echo "reports" ;;
    *pg_namespace*)   echo "1" ;;
  esac
  return 0
}
( set -e; app_migrations_rls_gate gate_psql_bad hia >"$T/gate.log" 2>&1 ) \
  && bad "RLS gate passed a schema with an unprotected table" \
  || ok "RLS gate FAILS on a table without RLS"
grep -q 'reports' "$T/gate.log" \
  && ok "gate names the offending table" || bad "gate does not name the table"
grep -qi 'anon' "$T/gate.log" \
  && ok "gate explains the shared-anon-key consequence" || bad "gate message lacks the reason"

# ---- 4b. RLS gate: fails closed when the query itself cannot be trusted
#
# These three do NOT use the `(set -e; ...) && bad || ok` idiom above. That
# idiom depends on the FUNCTION returning non-zero on its own. If the gate
# under test never inspects a failing psql_fn's exit status, a failing
# command-substitution assignment ("x=$(cmd)") wrapped in `set -e` can abort
# the *subshell* right there via bash's own errexit — which also reads as
# non-zero, but for the wrong reason (bash's option, not code in the gate
# that checked anything). That is the same class of lying probe again, one
# level deeper, so it gets the same treatment: no `set -e` wrapper, call the
# gate bare, and read $? directly. (Verified empirically: a function whose
# body does `x="$(false_cmd)"` and then falls through, run under
# `(set -e; fn)`, aborts the subshell at the assignment and never reaches
# the fall-through code — so `set -e` would have quietly "fixed" the missing
# check in the test, not in the gate.)

# Critical 1: psql_fn itself fails (wrong password, container not ready,
# ON_ERROR_STOP, a SQL typo). The query never ran; its empty stdout must
# never be read as "no unprotected tables found".
gate_psql_query_fails() { return 1; }
app_migrations_rls_gate gate_psql_query_fails hia >"$T/gate-qf.log" 2>&1
rc=$?
[[ "${rc}" -ne 0 ]] \
  && ok "gate fails closed when the psql query itself errors" \
  || bad "gate passed when it could not run the query at all (rc=${rc})"

# Critical 2: the query runs fine (exit 0) but every probe comes back
# empty, because the schema does not exist / is misspelled — otherwise
# indistinguishable from "every table protected" unless the gate demands
# positive confirmation that the schema exists.
gate_psql_no_such_schema() { return 0; }   # empty stdout for every call, incl. the existence probe
app_migrations_rls_gate gate_psql_no_such_schema ghost_schema >"$T/gate-ns.log" 2>&1
rc=$?
[[ "${rc}" -ne 0 ]] \
  && ok "gate fails closed on a schema it never confirmed exists" \
  || bad "gate passed for a schema it could not find (rc=${rc})"

# Critical 3: relkind coverage. A partitioned table (relkind 'p') without
# RLS is exactly as exposed as an ordinary table, but invisible to a query
# filtered to relkind = 'r'. The double only reports the offending relation
# when the query's relkind filter actually includes 'p', so a pass here
# proves the SQL was widened, not just that the double was generous.
gate_psql_partitioned() {
  # Same ordering note as gate_psql_bad above: relrowsecurity must be
  # checked before pg_namespace, since the unprotected-tables query
  # contains both substrings.
  case "$*" in
    *relrowsecurity*) [[ "$*" == *"'p'"* ]] && echo "events_2026" ;;
    *pg_namespace*)   echo "1" ;;
  esac
  return 0
}
app_migrations_rls_gate gate_psql_partitioned hia >"$T/gate-part.log" 2>&1
rc=$?
[[ "${rc}" -ne 0 ]] \
  && ok "gate catches an unprotected partitioned table (relkind 'p')" \
  || bad "gate passed a schema with an unprotected partitioned table (rc=${rc})"

# ---- 5. RLS gate: passing direction
gate_psql_ok() {   # schema exists (pg_namespace probe); every table has RLS
  # Same ordering note again: the unprotected-tables query also contains
  # "pg_namespace", so it must match the relrowsecurity branch (and echo
  # nothing, i.e. no offending rows) rather than fall into the
  # existence-probe branch below.
  case "$*" in
    *relrowsecurity*) : ;;
    *pg_namespace*)   echo "1" ;;
  esac
  return 0
}
( set -e; app_migrations_rls_gate gate_psql_ok hia >/dev/null 2>&1 ) \
  && ok "RLS gate passes when every table has RLS" || bad "RLS gate false-failed"

# ---- 6. the gate runs as part of an apply, after the migrations
: > "$CALLS"; : > "${APPLIED_LIST}"; rm -f "${APPLY_COUNT_FILE}"
app_migrations_apply img rec_psql hia._migrations hia >/dev/null 2>&1
rc=$?
grep -q 'relrowsecurity' "$CALLS" \
  && ok "apply runs the RLS gate" || bad "apply did not run the RLS gate"
tail -1 "$CALLS" | grep -q 'relrowsecurity' \
  && ok "the gate runs AFTER the migrations, not before" || bad "gate ran before the migrations finished"
# The two checks above only look at $CALLS for presence/ordering — neither
# looks at whether the apply actually SUCCEEDED. A double that misidentifies
# the gate's main query (see the rec_psql comment above) can log calls in
# exactly the right order while still failing a clean fixture. $? is
# captured immediately after the call, not inside a `(set -e; ...) && bad
# || ok` wrapper, for the same reason the Critical-1/2/3 assertions above do
# the same: that idiom lets a failing internal assignment's own set -e abort
# masquerade as "the gate correctly refused."
[[ "${rc}" -eq 0 ]] \
  && ok "a gated apply on a clean schema succeeds" || bad "a gated apply on a clean schema failed (rc=${rc})"

echo; echo "${pass} passed, ${fail} failed"; [ "$fail" -eq 0 ]
