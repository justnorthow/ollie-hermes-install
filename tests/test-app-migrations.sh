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

# ---- 7. the app's SQL is relocated into the target schema at apply time
# App migrations are written the ordinary Supabase way (`public.`) so they stay
# compatible with `supabase start`, the supabase CLI's migration runner, and
# the app's own RLS suite. Consolidation is THIS installer's concern: rewrite
# them into the target schema on the way into psql. Doing it app-side instead
# broke every one of those tools — the CLI applies SQL over a connection, not
# through the psql client, so a psql :"variable" is never substituted and each
# migration died on `syntax error at or near ":"`.
rm -f "$FIXTURE_MIG_DIR"/*.sql
cat > "$FIXTURE_MIG_DIR/0001_first.sql" <<'SQL'
create table public.widgets (id uuid primary key);
create or replace function public.is_owner(w uuid) returns boolean
language sql security definer set search_path = public as $$
  select exists (select 1 from members where id = w)
$$;
revoke execute on function public.is_owner(uuid) from anon, public;
SQL
: > "$CALLS"; : > "${APPLIED_LIST}"; rm -f "${APPLIES}"/*.sql; rm -f "${APPLY_COUNT_FILE}"
app_migrations_apply img rec_psql hia._migrations hia >/dev/null 2>&1
RENDERED="${APPLIES}/1.sql"
grep -q 'create table hia\.widgets' "${RENDERED}" \
  && ok "qualified objects are relocated to the target schema" || bad "objects were not relocated"
# The pin is the security-critical half: a security definer function whose
# search_path still said `public` would resolve names outside its own schema
# at RUNTIME — migrations succeed, then every definer function misbehaves.
grep -q 'set search_path = hia' "${RENDERED}" \
  && ok "security definer search_path pins follow the tables" || bad "search_path pin still points at public"
# `public` with no dot is the PUBLIC ROLE. Rewriting it would silently change
# WHO the revoke applies to — a privilege change disguised as a relocation.
grep -q 'from anon, public;' "${RENDERED}" \
  && ok "the bare PUBLIC role is left alone" || bad "the PUBLIC role was rewritten"
grep -q 'public\.' "${RENDERED}" \
  && bad "a public.-qualified reference survived the rewrite" || ok "no public.-qualified reference remains"

# No schema argument => byte-identical passthrough (the stack-per-app path
# genuinely lives in public and must not be rewritten).
: > "$CALLS"; : > "${APPLIED_LIST}"; rm -f "${APPLIES}"/*.sql; rm -f "${APPLY_COUNT_FILE}"
app_migrations_apply img rec_psql hia._migrations >/dev/null 2>&1
grep -q 'create table public\.widgets' "${APPLIES}/1.sql" \
  && ok "no schema argument leaves the SQL untouched" || bad "SQL was rewritten with no schema argument"

# ---- 8. relocation tolerates real-world SQL style, and FAILS CLOSED otherwise
# Pop Bys is written entirely in lowercase with a bare `set search_path =
# public`. HIA is not: its pins are `SET search_path = public, pg_temp` —
# uppercase, and a LIST. The first implementation matched the lowercase bare
# form only, so on HIA it would have relocated every table reference while
# leaving both security definer pins on `public`, with a zero exit. That is
# the fail-late shape: migrations succeed, then the definer functions resolve
# outside their own schema at runtime.
rm -f "$FIXTURE_MIG_DIR"/*.sql
cat > "$FIXTURE_MIG_DIR/0001_first.sql" <<'SQL'
CREATE OR REPLACE FUNCTION public.handle_new_user() RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  INSERT INTO public.users (id, email) VALUES (new.id, new.email);
  RETURN new;
END;
$$;
SQL
: > "$CALLS"; : > "${APPLIED_LIST}"; rm -f "${APPLIES}"/*.sql; rm -f "${APPLY_COUNT_FILE}"
app_migrations_apply img rec_psql hia._migrations hia >/dev/null 2>&1
RENDERED="${APPLIES}/1.sql"
grep -q 'SET search_path = hia, pg_temp' "${RENDERED}" \
  && ok "uppercase SET and a search_path LIST are relocated (pg_temp preserved)" \
  || bad "uppercase/list search_path pin was left on public"
grep -q 'INSERT INTO hia\.users' "${RENDERED}" \
  && ok "qualified references relocate regardless of surrounding case" || bad "qualified reference not relocated"

# Fail closed on a form the rewrite cannot handle, rather than shipping a
# half-relocated migration. `public` not immediately after the `=` is exactly
# the case the targeted rewrite cannot safely reorder.
rm -f "$FIXTURE_MIG_DIR"/*.sql
cat > "$FIXTURE_MIG_DIR/0001_first.sql" <<'SQL'
create function public.f() returns void language sql
set search_path = pg_temp, public as $$ select 1 $$;
SQL
: > "$CALLS"; : > "${APPLIED_LIST}"; rm -f "${APPLIES}"/*.sql; rm -f "${APPLY_COUNT_FILE}"
( set -e; app_migrations_apply img rec_psql hia._migrations hia >/dev/null 2>&1 ) \
  && bad "a search_path the rewrite could not relocate was applied anyway" \
  || ok "refuses to apply when a public reference survives the rewrite"

# ---- 9. the apply session can reach extension functions
# Relocated migrations run as <name>_owner, whose search_path does not include
# `extensions`. Supabase installs uuid-ossp etc. THERE, so an unqualified
# uuid_generate_v4() — which cannot be relocated, it is not `public.`-qualified
# — fails with "function does not exist". Pop Bys never hit this because
# gen_random_uuid() also exists in pg_catalog, which is always implicitly on
# the path; HIA's first migration died on it.
# `public` is deliberately NOT added back: that would restore the very reach
# the schema separation exists to remove.
rm -f "$FIXTURE_MIG_DIR"/*.sql
printf 'create table public.t (id uuid primary key default uuid_generate_v4());\n' > "$FIXTURE_MIG_DIR/0001_first.sql"
: > "$CALLS"; : > "${APPLIED_LIST}"; rm -f "${APPLIES}"/*.sql; rm -f "${APPLY_COUNT_FILE}"
app_migrations_apply img rec_psql hia._migrations hia >/dev/null 2>&1
head -1 "${APPLIES}/1.sql" | grep -q 'set search_path = hia, extensions;' \
  && ok "apply session puts the target schema and extensions on the search_path" \
  || bad "no search_path set for the apply session"
grep -q 'set search_path = hia, extensions;.*public' "${APPLIES}/1.sql" \
  && bad "public was added back to the apply search_path" || ok "public is not on the apply search_path"

# No schema => no injected search_path (the stack-per-app path is unchanged).
: > "$CALLS"; : > "${APPLIED_LIST}"; rm -f "${APPLIES}"/*.sql; rm -f "${APPLY_COUNT_FILE}"
app_migrations_apply img rec_psql hia._migrations >/dev/null 2>&1
grep -q 'set search_path' "${APPLIES}/1.sql" \
  && bad "injected a search_path with no schema argument" || ok "no search_path injected without a schema"

echo; echo "${pass} passed, ${fail} failed"; [ "$fail" -eq 0 ]
