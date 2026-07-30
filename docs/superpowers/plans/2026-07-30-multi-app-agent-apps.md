# Multi-App Agent Apps on One Supabase — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite `scripts/24-install-agent-apps.sh` so one agent profile can install N apps as Postgres schemas in the core Supabase stack, replacing the per-app-stack install path.

**Architecture:** Step 1 of 24 calls `26-provision-app-schema.sh` instead of `20-install-app-stack.sh`. The inline migration runner moves to `scripts/lib/app-migrations.sh`, retargets to the core database as `<name>_owner`, tracks in `<name>._migrations`, and gains a fail-closed RLS gate. Per-app hosts cease to exist; the only per-app operator input is `IMAGE_TARBALL_<NAME>`, resolved into per-iteration locals. An app-name filter allows one app to be installed at a time.

**Tech Stack:** Bash (`set -euo pipefail`), Python 3 for manifest reads, shim-based shell tests (fake `docker`/`curl` on `PATH`, `SUB*` script injection).

**Spec:** `docs/superpowers/specs/2026-07-30-multi-app-agent-apps-design.md`

## Global Constraints

- **Never reassign the bare `IMAGE_TARBALL` stdin variable inside the per-app loop.** Resolve into a per-iteration local. A leaked tarball installs app 0's image under app 1's name and port, where it passes app 1's health check. This is the single most important rule in this plan.
- The bare `IMAGE_TARBALL` key is legal **only when exactly one app is being installed** — a single-app manifest, or a multi-app manifest narrowed by the filter. With two or more targets, a value with no per-app key and no `~/apps/<name>/.env` carry-forward is a fatal error naming the app and the key it wants.
- **Manifest app names must match `^[a-z][a-z0-9]*$`** — the intersection of script 26's Postgres-identifier rule (`^[a-z][a-z0-9_]*$`, no hyphens) and scripts 23/25's unit-name rule (`^[a-z][a-z0-9-]*$`, no underscores). Validate every name before any install work.
- **No app receives core's `service_role` key.** The app's runtime key is `SUPABASE_APP_KEY`, read from `~/supabase-stack/app-keys/<name>.jwt`.
- Scripts are mode 644 in this repo — any command printed for the operator must say `sudo bash <path>`, never `./<path>`.
- Script 24 refuses to run as root; scripts 22 and 25 require root. 24 therefore **prints** root steps, never runs them.
- `WARNINGS` counts non-fatal warnings; a non-zero count must suppress the final `✓` and print `⚠ … with N warning(s)`. Never let a warning path exit non-zero.
- **`tests/test-24-install-agent-apps.sh` takes roughly 2m37s on Windows** for its existing 93 cases. Use a timeout of at least 5 minutes. A previous session read this runtime as a hang and left work uncommitted.

---

## File Structure

| File | Responsibility |
|---|---|
| `scripts/lib/app-migrations.sh` | **Create.** Apply image-bundled migrations to a schema in the core DB as `<name>_owner`, track in `<name>._migrations`, then run the RLS gate. |
| `scripts/24-install-agent-apps.sh` | **Modify.** Manifest parse + name validation, app filter, per-app loop with per-iteration locals, step 1 → 26, step 3 env rewrite, tile `sso:false`, bridge checks, no caddy step, guard removal. |
| `scripts/23-install-app-server.sh` | **Modify.** `NODE_OPTIONS` install default. |
| `apps/real-estate.json` | **Modify.** Drop `stack` blocks, re-land the HIA entry. |
| `tests/test-app-migrations.sh` | **Create.** Direct unit tests for the extracted runner and the RLS gate. |
| `tests/test-24-install-agent-apps.sh` | **Modify.** New fixtures (core stack, `SUB26`, two-app manifest), `run_app()` helper, updated and new assertions. |
| `tests/test-23-install-app-server.sh` | **Modify.** `NODE_OPTIONS` default cases. |

---

## Task 1: `NODE_OPTIONS` install default in script 23

Independent of everything else. Do it first to get a green commit before touching 24.

**Files:**
- Modify: `scripts/23-install-app-server.sh:44-46` (insert after `APP_PORT` validation)
- Test: `tests/test-23-install-app-server.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: every app installed via 23 has `NODE_OPTIONS=--max-http-header-size=65536` in `~/apps/<name>/.env` unless overridden.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test-23-install-app-server.sh`, before the final tally line:

```bash
# NODE_OPTIONS install default: present when nothing supplies one
rm -rf "$APPS_DIR/nodedef"
printf 'APP_NAME=nodedef\nAPP_PORT=8199\nIMAGE_TARBALL=%s\nAPP_ENV_SUPABASE_URL=https://x.test\nAPP_ENV_SUPABASE_ANON_KEY=k\n' "$T/img.tar" \
  | bash "${DIR}/scripts/23-install-app-server.sh" > "$T/out.log" 2>&1
grep -qx 'NODE_OPTIONS=--max-http-header-size=65536' "$APPS_DIR/nodedef/.env" \
  && ok "NODE_OPTIONS default present" || bad "NODE_OPTIONS default missing"

# operator APP_ENV_NODE_OPTIONS wins over the default
rm -rf "$APPS_DIR/nodeover"
printf 'APP_NAME=nodeover\nAPP_PORT=8198\nIMAGE_TARBALL=%s\nAPP_ENV_SUPABASE_URL=https://x.test\nAPP_ENV_SUPABASE_ANON_KEY=k\nAPP_ENV_NODE_OPTIONS=--max-old-space-size=512\n' "$T/img.tar" \
  | bash "${DIR}/scripts/23-install-app-server.sh" > "$T/out.log" 2>&1
grep -qx 'NODE_OPTIONS=--max-old-space-size=512' "$APPS_DIR/nodeover/.env" \
  && ok "operator NODE_OPTIONS wins" || bad "operator NODE_OPTIONS was overridden by the default"

# an existing .env value survives a re-run (the default must not clobber it)
printf 'APP_NAME=nodeover\nAPP_PORT=8198\n' \
  | bash "${DIR}/scripts/23-install-app-server.sh" > "$T/out.log" 2>&1
grep -qx 'NODE_OPTIONS=--max-old-space-size=512' "$APPS_DIR/nodeover/.env" \
  && ok "existing NODE_OPTIONS survives a re-run" || bad "re-run clobbered NODE_OPTIONS with the default"
```

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/test-23-install-app-server.sh`
Expected: three new `FAIL:` lines — `NODE_OPTIONS default missing` first.

- [ ] **Step 3: Implement the default**

In `scripts/23-install-app-server.sh`, immediately after the `APP_PORT` numeric validation block (currently ending at line 46):

```bash
# Node's default 16KB header limit is smaller than what a browser sends these
# boxes: SUPABASE_COOKIE_DOMAIN=.jnow.io sends every box's chunked Supabase
# cookie to every *.jnow.io host. Pop Bys' and HIA's SSO handoffs both broke at
# exactly that threshold on 2026-07-29 — HTTP 431, blank tile, no client-side
# error. A default is correct-by-construction; a per-app manifest field would
# be folklore every future author has to remember. Harmless on a non-Node
# container, which simply ignores the variable.
# Only default when neither the operator nor a previous run supplied a value,
# so a re-run never clobbers a deliberate override.
if [[ -z "${APP_ENV_NODE_OPTIONS:-}" \
   && -z "$(app_server_env_val "${APP_DIR}/.env" NODE_OPTIONS)" ]]; then
  export APP_ENV_NODE_OPTIONS='--max-http-header-size=65536'
fi
```

- [ ] **Step 4: Run to verify they pass**

Run: `bash tests/test-23-install-app-server.sh`
Expected: all PASS, zero FAIL.

- [ ] **Step 5: Commit**

```bash
git add scripts/23-install-app-server.sh tests/test-23-install-app-server.sh
git commit -m "feat(23): default NODE_OPTIONS to a 64KB header limit"
```

---

## Task 2: Validate manifest app names in 24

Additive. The existing fixture names (`popbys`) already satisfy the rule, so the 93 existing cases stay green.

**Files:**
- Modify: `scripts/24-install-agent-apps.sh` (after `APP_COUNT` is read, before the guard)
- Test: `tests/test-24-install-agent-apps.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `24` exits 1 naming the offending app before any install work when a manifest name is invalid.

- [ ] **Step 1: Write the failing test**

Append to `tests/test-24-install-agent-apps.sh`, before the final tally:

```bash
# manifest app names must satisfy BOTH the Postgres-identifier rule (26) and
# the systemd-unit rule (23/25). Validate before any install work.
cat > "$MANIFEST_DIR/badname.json" <<'JSON'
{
  "profile": "badname",
  "apps": [
    { "name": "foo_bar",
      "server": { "app_port": 8140, "container_port": 3000, "health_path": "/api/health" } }
  ]
}
JSON
: > "$SUB20_LOG"; : > "$CURL_LOG"
printf '{"agents":[{"id":"badname"}]}' > "$AGENTS_JSON_FILE"
run "badname" "${STDIN[@]}" && bad "invalid app name should fail" || ok "invalid app name fails"
grep -q "foo_bar" "$T/out.log" && ok "error names the offending app" || bad "error does not name the app"
grep -qE '\^\[a-z\]\[a-z0-9\]\*\$' "$T/out.log" \
  && ok "error states the required pattern" || bad "error omits the pattern"
[[ ! -s "$CURL_LOG" ]] && ok "validation precedes the orchestrator preflight (empty CURL_LOG proves it)" || bad "orchestrator preflight ran before validation"
```

> **Do not assert `[[ ! -s "$SUB20_LOG" ]]` here.** An earlier draft did, and it was
> vacuous: `badname.json` has no `stack` block, so with the validation removed the run
> dies in the per-app loop (or at the preflight) before `SUB20` is ever invoked, leaving
> `SUB20_LOG` empty either way. `CURL_LOG` discriminates because the orchestrator
> preflight is the first thing script 24 does that performs any work, and the suite's
> fake `curl` logs every invocation unconditionally. Verified by moving the validation
> after the preflight and watching this assertion fail.

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test-24-install-agent-apps.sh` (allow 5 minutes)
Expected: `FAIL: invalid app name fails` — 24 currently accepts the name.

- [ ] **Step 3: Implement validation**

In `scripts/24-install-agent-apps.sh`, immediately after `APP_COUNT="$(mf …)"`:

```bash
# Every app name is used three ways with three different character rules:
#   26-provision-app-schema.sh  ^[a-z][a-z0-9_]*$   Postgres identifier, no hyphens
#   23-install-app-server.sh    ^[a-z][a-z0-9-]*$   compose project, no underscores
#   25-install-app-bridge.sh    ^[a-z][a-z0-9-]*$   systemd unit, no underscores
# So a name with an underscore breaks the bridge and a name with a hyphen
# breaks the schema. Enforce the intersection here, before any install work,
# rather than half-installing and failing at whichever script runs first.
for i in $(seq 0 $((APP_COUNT-1))); do
  _n="$(mf "['apps'][${i}]['name']")"
  if [[ ! "${_n}" =~ ^[a-z][a-z0-9]*$ ]]; then
    echo "error: manifest app name '${_n}' is invalid — must match ^[a-z][a-z0-9]*\$ (the intersection of the Postgres identifier rule used by 26 and the systemd/compose unit rule used by 23 and 25)" >&2
    exit 1
  fi
done
unset _n
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/test-24-install-agent-apps.sh`
Expected: all PASS including the four new cases.

- [ ] **Step 5: Commit**

```bash
git add scripts/24-install-agent-apps.sh tests/test-24-install-agent-apps.sh
git commit -m "fix(24): validate manifest app names against the 26/23/25 intersection"
```

---

## Task 3: Extract the migration runner to a lib — pure refactor, no behaviour change

Do the extraction and the retarget as **two** tasks. This one must leave every existing test passing, which proves the extraction is faithful before the target changes underneath it.

**Files:**
- Create: `scripts/lib/app-migrations.sh`
- Modify: `scripts/24-install-agent-apps.sh:185-215` (replace the inline loop with a call)

**Interfaces:**
- Consumes: nothing.
- Produces: `app_migrations_apply IMG PSQL_FN_NAME TRACKER_TABLE` — extracts `/app/supabase/migrations/.` from image `IMG` into a temp dir, applies each `*.sql` in `sort` order, skipping any already recorded in `TRACKER_TABLE`, each in one `psql -1 -f -` invocation carrying the file and its tracker `INSERT`. `PSQL_FN_NAME` is the name of a shell function the caller defines that reads SQL on stdin and forwards `"$@"` to `psql`.

- [ ] **Step 1: Create the lib with the loop moved verbatim**

Create `scripts/lib/app-migrations.sh`:

```bash
#!/usr/bin/env bash
# app-migrations.sh — apply the migrations bundled inside an app image.
#
# The caller supplies a psql-invoking function by NAME; this lib never builds a
# connection itself, so the same runner serves a per-app stack (legacy) and the
# core stack with a schema-scoped role.
#
# app_migrations_apply IMG PSQL_FN TRACKER
#   IMG      image ref or ID holding /app/supabase/migrations
#   PSQL_FN  name of a function: reads SQL on stdin, forwards "$@" to psql
#   TRACKER  fully-qualified tracker table, e.g. public._app_migrations

app_migrations_apply() { # IMG PSQL_FN TRACKER
  local img="$1" psql_fn="$2" tracker="$3"
  local mig_dir ctr f base applied
  mig_dir="$(mktemp -d)"
  ctr="$(docker create "${img}")"
  docker cp "${ctr}:/app/supabase/migrations/." "${mig_dir}/"
  docker rm "${ctr}" >/dev/null
  "${psql_fn}" -c "create table if not exists ${tracker} (name text primary key, applied_at timestamptz not null default now());"
  for f in $(ls "${mig_dir}"/*.sql | sort); do
    base="$(basename "$f")"
    applied="$("${psql_fn}" -c "select 1 from ${tracker} where name='${base}';")"
    if [[ "${applied}" == "1" ]]; then echo "    skip ${base} (applied)"; continue; fi
    echo "    apply ${base}"
    # Single-transaction apply: the migration file and its tracker INSERT
    # travel in ONE psql invocation, so a mid-file failure rolls back both —
    # no partially-applied file recorded as done, no applied file unrecorded.
    { cat "$f"; printf "\ninsert into %s (name) values ('%s');\n" "${tracker}" "${base}"; } \
      | "${psql_fn}" -1 -f -
  done
  rm -rf "${mig_dir}"
}
```

- [ ] **Step 2: Replace the inline loop in 24**

Add to the `.` block at the top of `scripts/24-install-agent-apps.sh` (after `app-server-env.sh`):

```bash
. "${SCRIPT_DIR}/lib/app-migrations.sh"
```

Replace lines 195-215 (from `MIG_DIR="$(mktemp -d)"` through `rm -rf "${MIG_DIR}"`) with:

```bash
  PGPASS="$(supabase_app_env_val "${SB_ENV}" POSTGRES_PASSWORD)"
  app_psql() {
    docker compose -p "${NAME}" -f "${STACKS}/${NAME}/docker-compose.yml" --env-file "${SB_ENV}" \
      exec -T -e PGPASSWORD="${PGPASS}" db \
      psql -h 127.0.0.1 -U supabase_admin -d postgres -v ON_ERROR_STOP=1 -qtA "$@"
  }
  app_migrations_apply "${IMG}" app_psql public._app_migrations
```

- [ ] **Step 3: Run the full suite — it must be unchanged**

Run: `bash tests/test-24-install-agent-apps.sh` (allow 5 minutes)
Expected: identical pass count to before this task, zero FAIL. The fake docker's `compose` branch already handles both the `-c` form and the `-1 -f -` form, so no test change is needed. **If any migration assertion fails, the extraction is not faithful — fix the lib, do not edit the test.**

- [ ] **Step 4: Commit**

```bash
git add scripts/lib/app-migrations.sh scripts/24-install-agent-apps.sh
git commit -m "refactor(24): extract the migration runner to lib/app-migrations.sh"
```

---

## Task 4: Direct unit tests for the extracted runner

Now that it is a function, test it without a full install.

**Files:**
- Create: `tests/test-app-migrations.sh`

**Interfaces:**
- Consumes: `app_migrations_apply` from Task 3.
- Produces: nothing consumed later.

- [ ] **Step 1: Write the tests**

Create `tests/test-app-migrations.sh`:

```bash
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
```

- [ ] **Step 2: Run — expect one genuine failure**

Run: `bash tests/test-app-migrations.sh`
Expected: the order/tracker/skip cases PASS (Task 3 moved working code). `a failing apply propagates to the caller` may FAIL, because `app_migrations_apply` runs inside a `for` loop with no explicit error check and the lib does not set `-e` itself.

- [ ] **Step 3: Make the failure propagate**

In `scripts/lib/app-migrations.sh`, replace the apply line with an explicit check so the runner is safe regardless of the caller's `set -e` state:

```bash
    if ! { cat "$f"; printf "\ninsert into %s (name) values ('%s');\n" "${tracker}" "${base}"; } \
         | "${psql_fn}" -1 -f -; then
      echo "error: migration ${base} failed — nothing was recorded as applied (single-transaction)" >&2
      rm -rf "${mig_dir}"
      return 1
    fi
```

- [ ] **Step 4: Run both suites**

Run: `bash tests/test-app-migrations.sh`
Expected: all PASS.

Run: `bash tests/test-24-install-agent-apps.sh` (allow 5 minutes)
Expected: unchanged, zero FAIL.

- [ ] **Step 5: Commit**

```bash
git add tests/test-app-migrations.sh scripts/lib/app-migrations.sh
git commit -m "test(app-migrations): direct coverage + propagate a failed apply"
```

---

## Task 5: The fail-closed RLS gate

Write the **failing** direction first. A gate only ever observed passing is worthless — three probes lied in the 2026-07-29 session for exactly this reason.

**Files:**
- Modify: `scripts/lib/app-migrations.sh`
- Test: `tests/test-app-migrations.sh`

**Interfaces:**
- Consumes: `app_migrations_apply`.
- Produces: `app_migrations_rls_gate PSQL_FN SCHEMA` — returns 0 when every table in `SCHEMA` has row-level security enabled; prints the offending table names and returns 1 otherwise.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test-app-migrations.sh`, before the final tally:

```bash
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
: > "$CALLS"; : > "${APPLIED_LIST}"; n=0
app_migrations_apply img rec_psql hia._migrations hia >/dev/null 2>&1
grep -q 'relrowsecurity' "$CALLS" \
  && ok "apply runs the RLS gate" || bad "apply did not run the RLS gate"
tail -1 "$CALLS" | grep -q 'relrowsecurity' \
  && ok "the gate runs AFTER the migrations, not before" || bad "gate ran before the migrations finished"
```

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/test-app-migrations.sh`
Expected: FAIL on `app_migrations_rls_gate is NOT defined`, `gate names the offending table`, `gate explains the shared-anon-key consequence`, `RLS gate passes when every table has RLS`, `apply runs the RLS gate`, and `the gate runs AFTER the migrations`.

Note that `RLS gate FAILS on a table without RLS` will report **PASS** at this point, for the wrong reason — the function does not exist, so the subshell exits non-zero and the `||` branch fires. That is why the existence assertion above it is there. Do not read that single PASS as evidence the gate works.

- [ ] **Step 3: Implement the gate and call it from the apply**

Append to `scripts/lib/app-migrations.sh`:

```bash
# app_migrations_rls_gate PSQL_FN SCHEMA
#
# Every app on the box is handed the SAME core ANON_KEY, and anon/authenticated
# hold USAGE on every app schema plus DML on its tables — they must, because
# those are the roles that serve user-context requests. Under per-app stacks,
# cross-app reach was structurally impossible. After consolidation it is
# policy-dependent, and the policy is RLS. So RLS is mandatory, not advisory.
app_migrations_rls_gate() { # PSQL_FN SCHEMA
  local psql_fn="$1" schema="$2" unprotected
  unprotected="$("${psql_fn}" -c "select relname from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = '${schema}' and c.relkind = 'r' and not c.relrowsecurity order by relname;")"
  unprotected="$(printf '%s' "${unprotected}" | tr -d '\r' | grep -v '^$' || true)"
  if [[ -n "${unprotected}" ]]; then
    echo "error: RLS is not enabled on these tables in schema '${schema}':" >&2
    printf '  %s\n' ${unprotected} >&2
    echo "Every app on this box shares the same core ANON_KEY, and anon/authenticated hold DML on every app schema — so each table above is readable AND writable by every other app's browser bundle. Add 'alter table <t> enable row level security' plus policies to the migration, then re-run." >&2
    return 1
  fi
  echo "    RLS gate: every table in '${schema}' is protected"
  return 0
}
```

Extend the apply signature to take the schema and call the gate last. Change the function header and the tail of `app_migrations_apply`:

```bash
app_migrations_apply() { # IMG PSQL_FN TRACKER [SCHEMA]
  local img="$1" psql_fn="$2" tracker="$3" schema="${4:-}"
```

and immediately before the closing `}`, after `rm -rf "${mig_dir}"`:

```bash
  # The gate runs AFTER every migration, because a migration is exactly what
  # creates the table that would fail it.
  if [[ -n "${schema}" ]]; then
    app_migrations_rls_gate "${psql_fn}" "${schema}" || return 1
  fi
```

- [ ] **Step 4: Run both suites**

Run: `bash tests/test-app-migrations.sh`
Expected: all PASS.

Run: `bash tests/test-24-install-agent-apps.sh` (allow 5 minutes)
Expected: unchanged — 24 still calls the three-argument form, so the gate is inert there until Task 6.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/app-migrations.sh tests/test-app-migrations.sh
git commit -m "feat(app-migrations): fail-closed RLS gate after an app's migrations"
```

---

## Task 6: Retarget step 1 and step 2 — schema provisioning and core-database migrations

The first task that changes 24's contract, so it updates the fixtures and the assertions that describe the old one.

**Files:**
- Modify: `scripts/24-install-agent-apps.sh` (header comment, `SUB26`, loop step 1 and 2)
- Test: `tests/test-24-install-agent-apps.sh` (core-stack fixture, `SUB26` stub, replace `SUB20` assertions)

**Interfaces:**
- Consumes: `app_migrations_apply IMG PSQL_FN TRACKER SCHEMA`.
- Produces: `SUB26` injection seam (default `${SCRIPT_DIR}/26-provision-app-schema.sh`); `CORE_STACK_DIR` (default `$HOME/supabase-stack`); a `core_psql` function in 24 that runs psql in the core stack's `db` as `<name>_owner`.

- [ ] **Step 1: Add the core-stack fixture and `SUB26` stub to the test**

In `tests/test-24-install-agent-apps.sh`, after the existing `STACKS_DIR` fixture block:

```bash
# ---- fixture CORE supabase stack (what 26 provisions into and 24 reads) ----
export CORE_STACK_DIR="$T/supabase-stack"
mkdir -p "$CORE_STACK_DIR/app-keys"
cat > "$CORE_STACK_DIR/.env" <<'EOF'
ANON_KEY=core-anon
SERVICE_ROLE_KEY=core-service-role-DO-NOT-LEAK
SUPABASE_PUBLIC_URL=https://sb-core.test
POSTGRES_PASSWORD=corepw
JWT_SECRET=core-jwt-secret
PGRST_DB_SCHEMAS=public
EOF
: > "$CORE_STACK_DIR/docker-compose.yml"

# ---- SUB26 stub: logs stdin; materializes the app's owner JWT ----
export SUB26_LOG="$T/sub26.log"
cat > "$T/bin/sub26.sh" <<'SH'
#!/usr/bin/env bash
set -eu
cat > "${SUB26_LOG}"
name="$(sed -nE 's/^APP_NAME=(.*)$/\1/p' "${SUB26_LOG}" | tail -1)"
mkdir -p "${CORE_STACK_DIR}/app-keys"
printf 'jwt-for-%s' "${name}" > "${CORE_STACK_DIR}/app-keys/${name}.jwt"
SH
export SUB26="$T/bin/sub26.sh"
chmod +x "$SUB26"
```

- [ ] **Step 2: Replace the step-1 assertions**

Delete the six `SUB20 got …` assertions (currently test-24 lines 348-353) and put in their place:

```bash
grep -q '^APP_NAME=popbys$' "$SUB26_LOG" && ok "SUB26 got APP_NAME" || bad "SUB26 got APP_NAME"
grep -q "^CORE_STACK_DIR=${CORE_STACK_DIR}\$" "$SUB26_LOG" && ok "SUB26 got CORE_STACK_DIR" || bad "SUB26 got CORE_STACK_DIR"
[[ ! -s "$SUB20_LOG" ]] && ok "20-install-app-stack.sh is no longer called" || bad "24 still calls 20"
grep -q 'create table if not exists popbys._migrations' "$DOCKER_LOG" \
  && ok "tracker is popbys._migrations" || bad "tracker is not the per-schema table"
grep -q 'public._app_migrations' "$DOCKER_LOG" \
  && bad "still tracking in public._app_migrations" || ok "no longer tracking in public._app_migrations"
grep -qE 'psql .*-U popbys_owner' "$DOCKER_LOG" \
  && ok "migrations run as popbys_owner" || bad "migrations do not run as the owner role"
```

Also update the fake docker's `compose` branch so the applied-check regex matches the new tracker. Change:

```bash
        *"select 1 from public._app_migrations where name="*)
```

to:

```bash
        *"select 1 from "*"._migrations where name="*)
```

and add a branch above it so the gate query returns nothing by default (every table protected):

```bash
        *relrowsecurity*) : ;;
```

- [ ] **Step 3: Run to verify the new assertions fail**

Run: `bash tests/test-24-install-agent-apps.sh` (allow 5 minutes)
Expected: FAIL on `SUB26 got APP_NAME`, `24 still calls 20`, and the tracker assertions.

- [ ] **Step 4: Implement in 24**

Add the seam beside the others (near line 35):

```bash
SUB26="${SUB26:-${SCRIPT_DIR}/26-provision-app-schema.sh}"
CORE_DIR="${CORE_STACK_DIR:-$HOME/supabase-stack}"
```

Replace loop step 1 (currently lines 173-183, the `1/5: supabase stack` block) with:

```bash
  echo "==> agent-apps [${NAME}] 1/4: app schema + owner role in the core stack"
  {
    echo "APP_NAME=${NAME}"
    echo "CORE_STACK_DIR=${CORE_DIR}"
  } | bash "${SUB26}"
```

Replace loop step 2's connection setup (the `PGPASS`/`app_psql` block from Task 3) with:

```bash
  echo "==> agent-apps [${NAME}] 2/4: app migrations into schema '${NAME}'"
  CORE_PGPASS="$(supabase_app_env_val "${CORE_DIR}/.env" POSTGRES_PASSWORD)"
  [[ -n "${CORE_PGPASS}" ]] || { echo "error: POSTGRES_PASSWORD missing from ${CORE_DIR}/.env" >&2; exit 1; }
  core_psql() {
    # Runs as <name>_owner, NOT supabase_admin: objects must be owned by the
    # app's role so they inherit the default privileges 26 installed for the
    # PostgREST roles. Created as supabase_admin they would be unreachable.
    docker compose -f "${CORE_DIR}/docker-compose.yml" --env-file "${CORE_DIR}/.env" \
      exec -T -e PGPASSWORD="${CORE_PGPASS}" db \
      psql -h 127.0.0.1 -U "${NAME}_owner" -d postgres -v ON_ERROR_STOP=1 -qtA "$@"
  }
  app_migrations_apply "${IMG}" core_psql "${NAME}._migrations" "${NAME}"
```

Update the header comment block: step count 5 → 4, `20 (Supabase stack)` → `26 (app schema + owner role)`, and drop `SB_HOST` from the documented stdin keys.

- [ ] **Step 5: Run to verify**

Run: `bash tests/test-24-install-agent-apps.sh` (allow 5 minutes)
Expected: all PASS. Any remaining failure will be a step-3 assertion still expecting the app-stack anon key — that is Task 7's job; if so, note which and proceed only if the failures are exactly those.

- [ ] **Step 6: Commit**

```bash
git add scripts/24-install-agent-apps.sh tests/test-24-install-agent-apps.sh
git commit -m "feat(24): provision an app schema via 26 and migrate into the core DB"
```

---

## Task 7: Rewrite step 3's app environment

**Files:**
- Modify: `scripts/24-install-agent-apps.sh` (loop step 3)
- Test: `tests/test-24-install-agent-apps.sh`

**Interfaces:**
- Consumes: `CORE_DIR`, `SUB26`'s `app-keys/<name>.jwt` output.
- Produces: the rendered app environment contains `SUPABASE_URL`, `SUPABASE_INTERNAL_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_APP_KEY`, `SUPABASE_DB_SCHEMA`, and no service-role key.

- [ ] **Step 1: Write the failing assertions**

Replace the existing `SUB23 got SUPABASE_URL` / `SUPABASE_ANON_KEY` assertions with:

```bash
grep -q '^APP_ENV_SUPABASE_URL=https://sb-core.test$' "$SUB23_LOG" \
  && ok "SUB23 got core's public URL" || bad "SUB23 did not get core's public URL"
grep -q '^APP_ENV_SUPABASE_INTERNAL_URL=http://172.17.0.1:8000$' "$SUB23_LOG" \
  && ok "SUB23 got the core kong internal URL" || bad "internal URL is not core kong"
grep -q '^APP_ENV_SUPABASE_ANON_KEY=core-anon$' "$SUB23_LOG" \
  && ok "SUB23 got core's anon key" || bad "SUB23 did not get core's anon key"
grep -q '^APP_ENV_SUPABASE_APP_KEY=jwt-for-popbys$' "$SUB23_LOG" \
  && ok "SUB23 got the owner JWT as SUPABASE_APP_KEY" || bad "SUPABASE_APP_KEY missing or wrong"
grep -q '^APP_ENV_SUPABASE_DB_SCHEMA=popbys$' "$SUB23_LOG" \
  && ok "SUB23 got the schema name" || bad "schema name missing"

# CLOSED WHITELIST, not a narrow grep. Stage 1 learned this: test-26 replaced a
# TRIGGER grep with a whitelist because the grep was too weak to prove absence.
grep -qiE 'SERVICE_ROLE|core-service-role-DO-NOT-LEAK' "$SUB23_LOG" \
  && bad "a service-role key reached the app environment" \
  || ok "no service-role key in the app environment, in any form"
grep -qi 'SSO_SECRET' "$SUB23_LOG" \
  && bad "an SSO secret reached the app environment" || ok "no SSO secret in the app environment"
```

Remove the fixture cases that assert the SSO-secret warning path (`hermes-stack-nosso`), and the `SERVICE_ROLE_KEY missing from …` failure case — both describe behaviour this task deletes. Leave the `ORCHESTRATOR_KEY` cases alone; that key is unrelated to SSO and still used.

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/test-24-install-agent-apps.sh` (allow 5 minutes)
Expected: FAIL on the core-URL, `SUPABASE_APP_KEY`, `SUPABASE_DB_SCHEMA` and service-role-absence assertions.

- [ ] **Step 3: Implement**

Replace loop step 3's resolution block (the `ANON=…` through `SERVICE_ROLE_KEY` checks, and the `HIA_SSO_SECRET` block) with:

```bash
  echo "==> agent-apps [${NAME}] 3/4: app server (port ${APP_PORT})"
  CORE_URL="$(supabase_app_env_val "${CORE_DIR}/.env" SUPABASE_PUBLIC_URL)"
  ANON="$(supabase_app_env_val "${CORE_DIR}/.env" ANON_KEY)"
  [[ -n "${CORE_URL}" ]] || { echo "error: SUPABASE_PUBLIC_URL missing from ${CORE_DIR}/.env" >&2; exit 1; }
  [[ -n "${ANON}" ]] || { echo "error: ANON_KEY missing from ${CORE_DIR}/.env" >&2; exit 1; }
  # The app's runtime key: a JWT claiming role=<name>_owner, minted by 26.
  # This REPLACES service_role for the app. Core's service_role key bypasses
  # RLS and reaches every schema plus auth, so it must never reach a container.
  APP_KEY_FILE="${CORE_DIR}/app-keys/${NAME}.jwt"
  [[ -f "${APP_KEY_FILE}" ]] || { echo "error: ${APP_KEY_FILE} not found — 26 should have minted it in step 1/4" >&2; exit 1; }
  APP_KEY="$(cat "${APP_KEY_FILE}")"
  [[ -n "${APP_KEY}" ]] || { echo "error: ${APP_KEY_FILE} is empty" >&2; exit 1; }
```

and in the heredoc piped to `SUB23`, replace the Supabase and SSO lines with:

```bash
    echo "APP_ENV_SUPABASE_URL=${CORE_URL}"
    # Server-side callers must NOT use the public hostname: on a cloudflared
    # box it resolves to Cloudflare's edge, which bot-challenges non-browser
    # clients (HTTP 403) and breaks auth on every route. Core kong is
    # loopback-only, so reach it over the docker0 gateway bridge from 25.
    echo "APP_ENV_SUPABASE_INTERNAL_URL=http://172.17.0.1:8000"
    echo "APP_ENV_SUPABASE_ANON_KEY=${ANON}"
    echo "APP_ENV_SUPABASE_APP_KEY=${APP_KEY}"
    echo "APP_ENV_SUPABASE_DB_SCHEMA=${NAME}"
```

Delete the `APP_ENV_SUPABASE_SERVICE_ROLE_KEY` and `APP_ENV_HIA_SSO_SECRET` lines, the `HIA_SSO_SECRET` resolution and its `WARN`, and the `SERVICE_ROLE_KEY` resolution and its fatal check. Update the header comment to drop `HIA_SSO_SECRET` and `SUPABASE_SERVICE_ROLE_KEY`.

- [ ] **Step 4: Run to verify**

Run: `bash tests/test-24-install-agent-apps.sh` (allow 5 minutes)
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/24-install-agent-apps.sh tests/test-24-install-agent-apps.sh
git commit -m "feat(24): hand the app core's URL, anon key and its <name>_owner JWT"
```

---

## Task 8: Tile registration — `sso: false`

**Files:**
- Modify: `scripts/24-install-agent-apps.sh` (tile payload)
- Test: `tests/test-24-install-agent-apps.sh`

**Interfaces:**
- Consumes: nothing new.
- Produces: the tile payload's `config` carries `sso: false`.

**Why this is not cosmetic.** `ollie-hermes-frontend/src/pages/apps/ExternalWebApp.tsx:6-20`: with `sso` truthy, `src` starts as `null`, the tile renders "Opening…", fetches `/orchestrator-proxy/v1/sso/app-token`, and then points the iframe at `${baseUrl}sso?t=…` — a route the SSO collapse deletes. So a cut-over app registered with `sso: true` shows a 404 inside the frame, or "Couldn't open the app" if the token endpoint is gone, and never renders. With `sso` falsy the component sets `src = baseUrl` immediately and loads `/apps/<name>/`, using the first-party session cookie the same-origin proxy exists to preserve. Re-running 24 upserts the tile, so the flag flips during the cutover itself.

- [ ] **Step 1: Write the failing test**

Replace or extend the existing tile-payload assertion:

```bash
python3 - "$CURL_LOG.payload" <<'PY' && ok "tile config sets sso:false" || bad "tile config does not set sso:false"
import json, sys
cfg = json.load(open(sys.argv[1]))['config']
sys.exit(0 if cfg.get('sso') is False else 1)
PY
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test-24-install-agent-apps.sh` (allow 5 minutes)
Expected: FAIL — the payload currently carries `'sso': True`.

- [ ] **Step 3: Implement**

In the tile `PAYLOAD` python block, change:

```python
    'config': {'url': '/apps/' + app['name'] + '/', 'sso': True},
```

to:

```python
    # sso:False — the SSO handoff is deleted. ExternalWebApp.tsx treats a truthy
    # sso as "fetch an app-token, then load <base>sso?t=…", a route that no
    # longer exists; falsy makes it load /apps/<name>/ directly and use the
    # first-party session cookie the same-origin proxy preserves.
    'config': {'url': '/apps/' + app['name'] + '/', 'sso': False},
```

- [ ] **Step 4: Run to verify**

Run: `bash tests/test-24-install-agent-apps.sh` (allow 5 minutes)
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/24-install-agent-apps.sh tests/test-24-install-agent-apps.sh
git commit -m "fix(24): register tiles with sso:false now the handoff is gone"
```

---

## Task 9: Bridges — per-app app bridge, one core bridge, no caddy

**Files:**
- Modify: `scripts/24-install-agent-apps.sh` (the kong probe, step 5, the bridge prints)
- Test: `tests/test-24-install-agent-apps.sh`

**Interfaces:**
- Consumes: `WARNINGS`.
- Produces: step 4/4 prints only bridge commands; the core-kong probe runs once per run.

- [ ] **Step 1: Write the failing tests**

```bash
# the app bridge is probed per app, at the app port + health path
grep -qE 'curl .*172\.0?17\.0\.1:8130/api/health' "$CURL_LOG" \
  && ok "app bridge probed at the app port and health path" || bad "app bridge not probed"

# core kong is probed ONCE per run, not once per app
[[ "$(grep -c '172.17.0.1:8000/auth/v1/health' "$CURL_LOG")" -eq 1 ]] \
  && ok "core kong probed exactly once" || bad "core kong probe count wrong"

# no caddy step, and no per-app supabase host anywhere in the output
grep -qi 'caddy' "$T/out.log" && bad "caddy step still printed" || ok "no caddy step"
grep -qE '25-install-app-bridge.sh popbys:8130' "$T/out.log" \
  && ok "prints the app bridge command" || bad "app bridge command not printed"
grep -qE '25-install-app-bridge.sh core-sb:8000' "$T/out.log" \
  && ok "prints the core-sb bridge command" || bad "core-sb bridge command not printed"
grep -qE 'popbys-sb:' "$T/out.log" && bad "still prints a per-app supabase bridge" || ok "no per-app supabase bridge"

# a failing APP bridge probe warns, names the remedy, and suppresses the ✓
: > "$CURL_LOG"; printf '{"agents":[{"id":"real-estate"}]}' > "$AGENTS_JSON_FILE"
CURL_FAIL_URL_PATTERN="172.17.0.1:8130" run real-estate "${STDIN[@]}" "STACK_ENV_FILE=$T/stack-env/.env" \
  && ok "app-bridge probe failure is non-fatal" || bad "app-bridge probe failure aborted the run"
grep -qE "WARNING:.*25-install-app-bridge.sh popbys:8130" "$T/out.log" \
  && ok "warning names the missing app bridge" || bad "warning does not name the app bridge"
grep -qE "^⚠ agent-apps for profile 'real-estate' installed with 1 warning" "$T/out.log" \
  && ok "app-bridge warning is counted exactly once" || bad "warning count wrong"
export CURL_FAIL_URL_PATTERN=""
```

Update the existing per-app-kong probe test: change its `CURL_FAIL_URL_PATTERN` from `172.17.0.1:8030` to `172.17.0.1:8000` and its expected remedy string from `popbys-sb:8030` to `core-sb:8000`.

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/test-24-install-agent-apps.sh` (allow 5 minutes)
Expected: FAIL on the app-bridge probe, the core-kong probe port, and `no caddy step`.

- [ ] **Step 3: Implement**

Move the Supabase probe **out of the loop**, to just before it, and retarget it to core kong:

```bash
# One core Supabase for every app on this box, so this is a per-RUN check, not
# a per-app one. /api/health does not touch Supabase, so a missing bridge
# leaves every app "healthy" while every API call fails.
if ! curl -fsS --max-time 10 "http://172.17.0.1:8000/auth/v1/health" >/dev/null 2>&1; then
  echo "    WARNING: core Supabase at http://172.17.0.1:8000 is unreachable from the docker0 gateway — apps will look healthy but every API call will fail. Install the bridge: sudo bash ${SCRIPT_DIR}/25-install-app-bridge.sh core-sb:8000" >&2
  WARNINGS=$((WARNINGS+1))
fi
```

Replace the whole step 5/5 caddy block with a step 4/4 that probes the app bridge and prints the remedy:

```bash
  # Script 23 binds the app to 127.0.0.1 only, while the dashboard container
  # reaches tile apps over the docker0 gateway (host.docker.internal =
  # 172.17.0.1). A missing bridge means the tile 502s while every loopback
  # health check passes — exactly what happened to HIA on 2026-07-29.
  echo "==> agent-apps [${NAME}] 4/4: app bridge"
  if ! curl -fsS --max-time 10 "http://172.17.0.1:${APP_PORT}${HEALTH_PATH}" >/dev/null 2>&1; then
    echo "    WARNING: http://172.17.0.1:${APP_PORT}${HEALTH_PATH} is unreachable — the tile will 502 while the loopback health check passes. Install the bridge: sudo bash ${SCRIPT_DIR}/25-install-app-bridge.sh ${NAME}:${APP_PORT}" >&2
    WARNINGS=$((WARNINGS+1))
  else
    echo "    app bridge reachable"
  fi
```

Delete the caddy print, the `22 renders from ONLY its args` warning, the cloudflared NOTE, and the `<name>-sb:<kong_port>` bridge print. Apps are served same-origin under `/apps/<name>/` through the dashboard's nginx, so they have no vhost and no hostname of their own. Add one print after the loop:

```bash
echo "==> bridges (root step — run yourself, once per box for core-sb):"
echo "    sudo bash ${SCRIPT_DIR}/25-install-app-bridge.sh core-sb:8000"
```

and inside the loop, alongside the tile block, print the app's own bridge command.

Remove `KONG_PORT` and `EMAIL_ENABLED` from the manifest reads at the top of the loop — nothing consumes them now.

- [ ] **Step 4: Run to verify**

Run: `bash tests/test-24-install-agent-apps.sh` (allow 5 minutes)
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/24-install-agent-apps.sh tests/test-24-install-agent-apps.sh
git commit -m "feat(24): one core-sb bridge, per-app app-bridge check, no caddy step"
```

---

## Task 10: Per-app image resolution and the app-name filter — remove the guard

The multi-app core. Everything before this made one app work against a schema; this makes N work.

**Files:**
- Modify: `scripts/24-install-agent-apps.sh` (argv, loop bounds, `IMAGE_TARBALL` resolution, guard removal)
- Test: `tests/test-24-install-agent-apps.sh` (two-app fixture, `run_app` helper)

**Interfaces:**
- Consumes: everything above.
- Produces: `24-install-agent-apps.sh <profile> [app-name]`; per-app stdin key `IMAGE_TARBALL_<NAME>`.

- [ ] **Step 1: Add the two-app fixture and the `run_app` helper**

**Do not modify `run()`.** All 93 existing cases call it; the prior attempt at this work rewrote it and left the suite in a state a previous session reported as a hang. Add a sibling:

```bash
run_app() { # PROFILE APP KEY=VALUE...
  local profile="$1" app="$2"; shift 2
  printf '%s\n' "$@" | bash "${DIR}/scripts/24-install-agent-apps.sh" "${profile}" "${app}" > "$T/out.log" 2>&1
}
```

Two-app fixture manifest, plus a second `SUB26`/`SUB23` log so per-app values can be told apart:

```bash
cat > "$MANIFEST_DIR/two-app.json" <<'JSON'
{
  "profile": "two-app",
  "apps": [
    { "name": "popbys",
      "server": { "app_port": 8130, "container_port": 8080, "health_path": "/api/health" },
      "tile": { "label": "Pop Bys", "icon": "M0", "description": "d", "order": 10 } },
    { "name": "hia",
      "server": { "app_port": 8110, "container_port": 3000, "health_path": "/apps/hia/api/health",
                  "env": { "EXTRA_FROM_MANIFEST": "yes" } },
      "tile": { "label": "Home Inspection Advisor", "icon": "M1", "description": "d", "order": 20 } }
  ]
}
JSON

# SUB23 stub APPENDS per app so a two-app run is inspectable
cat > "$T/bin/sub23.sh" <<'SH'
#!/usr/bin/env bash
set -eu
body="$(cat)"
name="$(printf '%s' "$body" | sed -nE 's/^APP_NAME=(.*)$/\1/p' | tail -1)"
printf '%s' "$body" > "${SUB23_LOG}"
printf '%s' "$body" > "${SUB23_LOG}.${name}"
SH
chmod +x "$T/bin/sub23.sh"
: > "$T/img-hia.tar"
```

- [ ] **Step 2: Write the failing tests**

```bash
: > "$CURL_LOG"; : > "$DOCKER_LOG"; rm -f "$SUB23_LOG".*
printf '{"agents":[{"id":"two-app"}]}' > "$AGENTS_JSON_FILE"

# the guard is gone: a two-app manifest runs
run "two-app" "IMAGE_TARBALL_POPBYS=$T/img.tar" "IMAGE_TARBALL_HIA=$T/img-hia.tar" \
  "ORCH_ENV_FILE=$T/hermes-stack/.env" "STACK_ENV_FILE=$T/stack-env/.env" \
  && ok "two-app manifest installs" || bad "two-app manifest failed"

# THE regression the guard was hiding: no per-app value leaks across iterations
grep -q "img-hia.tar" "$DOCKER_LOG" && ok "hia's own tarball was loaded" || bad "hia's tarball not loaded"
grep -q '^APP_ENV_SUPABASE_DB_SCHEMA=hia$'    "$SUB23_LOG.hia"    && ok "hia got its own schema"    || bad "hia schema wrong"
grep -q '^APP_ENV_SUPABASE_DB_SCHEMA=popbys$' "$SUB23_LOG.popbys" && ok "popbys got its own schema" || bad "popbys schema wrong"
grep -q '^APP_PORT=8110$' "$SUB23_LOG.hia" && ok "hia got its own port" || bad "hia port leaked"
grep -q '^EXTRA_FROM_MANIFEST' "$SUB23_LOG.hia" \
  && ok "manifest server.env reached hia" || bad "server.env did not reach the app"
grep -q 'EXTRA_FROM_MANIFEST' "$SUB23_LOG.popbys" \
  && bad "hia's server.env leaked into popbys" || ok "server.env did not leak across apps"

# operator APP_ENV_<KEY> beats manifest server.env
run "two-app" "IMAGE_TARBALL_POPBYS=$T/img.tar" "IMAGE_TARBALL_HIA=$T/img-hia.tar" \
  "APP_ENV_EXTRA_FROM_MANIFEST=operator-wins" \
  "ORCH_ENV_FILE=$T/hermes-stack/.env" "STACK_ENV_FILE=$T/stack-env/.env" >/dev/null
grep -q '^APP_ENV_EXTRA_FROM_MANIFEST=operator-wins$' "$SUB23_LOG.hia" \
  && ok "operator APP_ENV wins over manifest server.env" || bad "manifest server.env beat the operator"

# the bare key is FATAL with two apps in play, and says which app wants what
run "two-app" "IMAGE_TARBALL=$T/img.tar" "ORCH_ENV_FILE=$T/hermes-stack/.env" \
  && bad "bare IMAGE_TARBALL accepted with two apps" || ok "bare IMAGE_TARBALL rejected with two apps"
grep -q 'IMAGE_TARBALL_HIA' "$T/out.log" \
  && ok "error names the per-app key it wants" || bad "error does not name the per-app key"

# the filter narrows to one app — and the bare key is legal again
: > "$DOCKER_LOG"; rm -f "$SUB23_LOG".*
run_app "two-app" "hia" "IMAGE_TARBALL=$T/img-hia.tar" \
  "ORCH_ENV_FILE=$T/hermes-stack/.env" "STACK_ENV_FILE=$T/stack-env/.env" \
  && ok "filtered run accepts the bare key" || bad "filtered run rejected the bare key"
[[ -f "$SUB23_LOG.hia" && ! -f "$SUB23_LOG.popbys" ]] \
  && ok "filter installed ONLY the named app" || bad "filter did not narrow the run"

# an unknown app name errors and lists the valid ones
run_app "two-app" "nope" "IMAGE_TARBALL=$T/img.tar" "ORCH_ENV_FILE=$T/hermes-stack/.env" \
  && bad "unknown app name accepted" || ok "unknown app name rejected"
grep -q 'popbys' "$T/out.log" && grep -q 'hia' "$T/out.log" \
  && ok "error lists the manifest's app names" || bad "error does not list valid names"
```

- [ ] **Step 3: Run to verify they fail**

Run: `bash tests/test-24-install-agent-apps.sh` (allow 5 minutes)
Expected: FAIL on `two-app manifest installs` first — the guard is still in place.

- [ ] **Step 4: Implement**

Accept the filter and compute the target index list, replacing the `APP_COUNT > 1` guard (lines 62-66):

```bash
APP_FILTER="${2:-}"
TARGETS=()
if [[ -n "${APP_FILTER}" ]]; then
  for i in $(seq 0 $((APP_COUNT-1))); do
    [[ "$(mf "['apps'][${i}]['name']")" == "${APP_FILTER}" ]] && TARGETS+=("${i}")
  done
  if [[ ${#TARGETS[@]} -eq 0 ]]; then
    NAMES=""
    for i in $(seq 0 $((APP_COUNT-1))); do NAMES="${NAMES} $(mf "['apps'][${i}]['name']")"; done
    echo "error: no app '${APP_FILTER}' in ${MANIFEST} — manifest apps are:${NAMES}" >&2
    exit 1
  fi
else
  for i in $(seq 0 $((APP_COUNT-1))); do TARGETS+=("${i}"); done
fi
# How many apps this RUN installs — not how many the manifest holds. The bare
# stdin keys are legal only when this is 1.
TARGET_COUNT=${#TARGETS[@]}
```

Change the loop header from `for i in $(seq 0 $((APP_COUNT-1))); do` to `for i in "${TARGETS[@]}"; do`.

Resolve the image into a **per-iteration local**:

```bash
  # Per-iteration local. NEVER assign back to IMAGE_TARBALL: with two apps that
  # leaks app 0's tarball into app 1, which installs app 0's IMAGE under app 1's
  # name and port — where it passes app 1's own health check. Worse than a
  # wrong host, because nothing looks broken.
  UPPER="$(printf '%s' "${NAME}" | tr '[:lower:]' '[:upper:]')"
  PER_APP_VAR="IMAGE_TARBALL_${UPPER}"
  APP_TARBALL="${!PER_APP_VAR:-}"
  if [[ -z "${APP_TARBALL}" ]]; then
    # Re-run path: the image is already pinned in the app's own .env.
    if [[ -n "$(app_image_from_env "${NAME}")" ]]; then
      APP_TARBALL=""
    elif [[ "${TARGET_COUNT}" -eq 1 ]]; then
      APP_TARBALL="${IMAGE_TARBALL}"
    else
      echo "error: no image for '${NAME}' — pass ${PER_APP_VAR}=<path>. The bare IMAGE_TARBALL key is only legal when exactly one app is being installed (a single-app manifest, or narrow this run with: 24-install-agent-apps.sh ${PROFILE} ${NAME})" >&2
      exit 1
    fi
    if [[ -z "${APP_TARBALL}" && -z "$(app_image_from_env "${NAME}")" ]]; then
      echo "error: no image for '${NAME}' — pass ${PER_APP_VAR}=<path> on first install" >&2
      exit 1
    fi
  fi
```

Collect `IMAGE_TARBALL_*` in the stdin parse by adding a case beside `APP_ENV_*`:

```bash
    IMAGE_TARBALL_*) export "${k}=${v}" ;;
```

Use `APP_TARBALL` in place of `IMAGE_TARBALL` in the step-2 image resolution and in the `SUB23` heredoc. Read `server.env` per app and emit it before the passthrough so operator keys still win:

```bash
  MF_ENV="$(python3 -c "
import json
d = json.load(open('${MANIFEST}'))
for k, v in ((d['apps'][${i}].get('server') or {}).get('env') or {}).items():
    print('APP_ENV_%s=%s' % (k, v))
")"
```

and inside the heredoc, before `printf '%s\n' "${PASSTHRU[@]:-}"`:

```bash
    [[ -n "${MF_ENV}" ]] && printf '%s\n' "${MF_ENV}"
```

Update the usage comment: `24-install-agent-apps.sh <profile> [app-name]`.

- [ ] **Step 5: Run to verify**

Run: `bash tests/test-24-install-agent-apps.sh` (allow 5 minutes)
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add scripts/24-install-agent-apps.sh tests/test-24-install-agent-apps.sh
git commit -m "feat(24): install N apps with per-app images and an app-name filter"
```

---

## Task 11: Update the manifest — drop `stack`, re-land HIA

Last, so main never carries a manifest 24 cannot install.

**Files:**
- Modify: `apps/real-estate.json`

**Interfaces:**
- Consumes: every task above.
- Produces: the real-estate profile bundles Pop Bys and HIA.

**Ordering constraint — do not skip this.** The rewritten 24 can only install a **cut-over** app. Committing the HIA entry is safe (it changes no box), but on a live box an unfiltered `24 real-estate` after this commit will try to install *both* apps as schemas. Pop Bys must be cut over first — it has 0 rows on both boxes and is the manifest's only app today, so cutting it over first leaves no un-cut-over app in the manifest. Until then, only ever run `24 real-estate <app>` with the filter.

- [ ] **Step 1: Rewrite the manifest**

```json
{
  "profile": "real-estate",
  "agent": {
    "display_name": "Emma Ellis",
    "subtitle": "Real Estate Assistant",
    "color": "#0e7c86"
  },
  "apps": [
    {
      "name": "hia",
      "server": { "app_port": 8110, "container_port": 3000, "health_path": "/apps/hia/api/health" },
      "tile": {
        "label": "Home Inspection Advisor",
        "icon": "M3 12l2-2m0 0l7-7 7 7M5 10v10a1 1 0 001 1h3m10-11l2 2m-2-2v10a1 1 0 01-1 1h-3m-6 0a1 1 0 001-1v-4a1 1 0 011-1h2a1 1 0 011 1v4a1 1 0 001 1m-6 0h6",
        "description": "Inspection report analysis: buyer and seller reports, cost estimates",
        "order": 20
      }
    },
    {
      "name": "popbys",
      "server": { "app_port": 8130, "container_port": 8080, "health_path": "/api/health" },
      "tile": {
        "label": "Pop Bys",
        "icon": "M15 10.5a3 3 0 11-6 0 3 3 0 016 0z M19.5 10.5c0 7.142-7.5 11.25-7.5 11.25S4.5 17.642 4.5 10.5a7.5 7.5 0 1115 0z",
        "description": "Pop-by planning: contacts, cadence, routes, calendar",
        "order": 10
      }
    }
  ]
}
```

- [ ] **Step 2: Verify it parses and both names are valid**

Run:

```bash
python3 -c "
import json,re
d=json.load(open('apps/real-estate.json'))
ns=[a['name'] for a in d['apps']]
assert all(re.match(r'^[a-z][a-z0-9]*\$', n) for n in ns), ns
assert not any('stack' in a for a in d['apps']), 'stack block still present'
print('ok', ns)
"
```

Expected: `ok ['hia', 'popbys']`

- [ ] **Step 3: Run the full suite plus the repo's parity gate**

Run: `bash tests/test-24-install-agent-apps.sh` (allow 5 minutes)
Run: `bash tests/test-app-migrations.sh`
Run: `bash tests/test-23-install-app-server.sh`
Expected: all PASS. If `scripts/check-box-config.sh` has a manifest parity assertion, run it with `OPERATOR_EMAIL=jb@jnow.io` — without that variable its last line is a spurious FAIL.

- [ ] **Step 4: Commit**

```bash
git add apps/real-estate.json
git commit -m "feat(agent-apps): re-land HIA in the real-estate manifest"
```

---

## Task 12: Run the whole suite and record what was not verified

**Files:** none — verification only.

- [ ] **Step 1: Run every affected suite from a clean tree**

```bash
bash tests/test-app-migrations.sh
bash tests/test-23-install-app-server.sh
bash tests/test-24-install-agent-apps.sh
```

Record the actual pass/fail counts. Do not claim success without pasting them.

- [ ] **Step 2: State the limits of that evidence plainly**

Every test above is shim-based: fake `docker`, fake `curl`, stub `SUB26`/`SUB23`. They prove 24 constructs the right calls. They **cannot** prove:

- that `<name>_owner` can actually create tables in its schema (no real Postgres)
- that the RLS gate's SQL is valid against a real `pg_class`
- that PostgREST serves the schema after 26 registers it
- that the tile renders with `sso: false`

Those are the sandbox acceptance run in the spec, and they are the reason acceptance lists six steps. Say so in the handoff instead of implying the suite covers them.

- [ ] **Step 3: Commit nothing; report**

Report: the counts, the spec sections covered, and the acceptance steps still outstanding.

---

## Plan Self-Review

**Spec coverage.** §1 step 1 → Task 6. §1 step 2 / §2 → Tasks 3, 4, 6. §3 RLS gate → Task 5. §1 step 3 → Task 7. §1 step 4 / `config.sso` → Task 8. §1 step 5 / §7 bridges → Task 9. §4 manifest → Tasks 2, 11. §5 per-app input → Task 10. §6 filter → Task 10. §8 `NODE_OPTIONS` → Task 1. §9 guard removal → Task 10. Testing section → Tasks 4, 5, 10, 12. Acceptance → Task 12 records it as outstanding; steps 1-6 need a box.

**Open item the spec deferred, now closed.** `config.sso` is resolved in Task 8 against the actual frontend component, not guessed.

**Not covered by this plan, by design.** Acceptance step 1, the Pop Bys client cutover, is app-side work in `jnow-workspace` (stage 3). It is a prerequisite to acceptance, not a task here — see Task 11's ordering constraint.

**Naming consistency check.** `app_migrations_apply IMG PSQL_FN TRACKER [SCHEMA]` — three-arg in Task 3, four-arg from Task 5, and Task 6 passes four. `app_migrations_rls_gate PSQL_FN SCHEMA` — defined Task 5, used Tasks 5 and 6. `SUB26` / `CORE_STACK_DIR` / `CORE_DIR` — introduced Task 6, used Tasks 6 and 7. `APP_TARBALL` / `PER_APP_VAR` / `TARGET_COUNT` / `TARGETS` — introduced Task 10 only. `run_app()` — Task 10; `run()` is never modified.
