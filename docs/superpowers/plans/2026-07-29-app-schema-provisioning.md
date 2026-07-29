# App Schema Provisioning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A new `scripts/26-provision-app-schema.sh` that prepares the core Supabase stack to host one app as a Postgres schema — schema, scoped owner role, grants, PostgREST registration, and a `<name>_owner` JWT.

**Architecture:** Stage 1 of `docs/superpowers/specs/2026-07-29-single-supabase-app-schemas-design.md`. Infrastructure only: it touches nothing an app or user currently uses, so it is safe to land and verify on its own. Later stages call it. Follows the repo's existing numbered-script conventions — stdin `KEY=VALUE` input, refuses root, idempotent re-runs.

**Tech Stack:** Bash (`set -euo pipefail`), `psql` via `docker compose exec`, Python 3 stdlib for JWT minting, shim-based shell tests.

## Global Constraints

- Run as the **service user**, never root — mirrors every other numbered script.
- **Idempotent.** Every step re-runnable without error and without duplicate side effects.
- **The owner role gets NO grants on `public`, no grants on any other app schema, and NEVER `TRIGGER` on `auth.users`.** These are the guarantees the whole consolidation rests on; they have explicit negative tests.
- Core stack lives at `$HOME/supabase-stack` (verified on sandbox via the compose working-dir label). Overridable by `CORE_STACK_DIR=`.
- Schema/role names are Postgres identifiers: `^[a-z][a-z0-9_]*$`. Hyphens are **not** valid unquoted — an app named `foo-bar` must be passed as `foo_bar`.
- The JWT secret is `JWT_SECRET` in the core stack `.env`. It must **never** be passed as a command-line argument (visible in `ps`) — stdin only.
- Work in a worktree with a **short** path (`D:\ohi-schemas`), not the shared main checkout and not the scratchpad — Windows MAX_PATH.
- Run tests with `bash tests/test-26-provision-app-schema.sh` from the repo root.

---

### Task 1: Script skeleton — guards and input validation

**Files:**
- Create: `scripts/26-provision-app-schema.sh`
- Create: `tests/test-26-provision-app-schema.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: the script contract — stdin keys `APP_NAME` (required) and `CORE_STACK_DIR` (optional, defaults `$HOME/supabase-stack`); shell vars `APP_NAME`, `CORE_DIR`, `OWNER_ROLE` (`${APP_NAME}_owner`) used by Tasks 2-4.

- [ ] **Step 1: Write the failing test**

Create `tests/test-26-provision-app-schema.sh`:

```bash
#!/usr/bin/env bash
# tests/test-26-provision-app-schema.sh — shim-based checks for app schema provisioning.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
mkdir -p "$T/bin"

# docker shim: log argv, and capture psql stdin (the SQL) for assertions.
cat > "$T/bin/docker" <<'SH'
#!/usr/bin/env bash
echo "docker $*" >> "${DOCKER_LOG}"
if [[ "$*" == *psql* ]]; then cat >> "${PSQL_SQL_LOG}"; fi
exit 0
SH
chmod +x "$T/bin/docker"
export PATH="$T/bin:$PATH" DOCKER_LOG="$T/docker.log" PSQL_SQL_LOG="$T/psql.sql"

# a core stack dir that looks real
CORE="$HOME/supabase-stack"; mkdir -p "$CORE"
cat > "$CORE/.env" <<'ENVEOF'
JWT_SECRET=ec3ca9f92d1de0f79e03897b324c9ec100ec647e
ANON_KEY=stub-anon
SERVICE_ROLE_KEY=stub-service
POSTGRES_PASSWORD=pw
PGRST_DB_SCHEMAS=public
ENVEOF
touch "$CORE/docker-compose.yml"

run() { printf '%s\n' "$@" | bash "${DIR}/scripts/26-provision-app-schema.sh"; }
reset_logs() { : > "$DOCKER_LOG"; : > "$PSQL_SQL_LOG"; }

# 1. missing APP_NAME refuses
reset_logs
run "CORE_STACK_DIR=$CORE" >/dev/null 2>&1 \
  && bad "missing APP_NAME refused" || ok "missing APP_NAME refused"

# 2. hyphens refused — not a valid unquoted Postgres identifier
reset_logs
run "APP_NAME=pop-bys" "CORE_STACK_DIR=$CORE" >/dev/null 2>&1 \
  && bad "hyphenated name refused" || ok "hyphenated name refused"

# 3. uppercase refused
reset_logs
run "APP_NAME=PopBys" "CORE_STACK_DIR=$CORE" >/dev/null 2>&1 \
  && bad "uppercase name refused" || ok "uppercase name refused"

# 4. missing core stack dir refuses with a useful message
reset_logs
out="$(run "APP_NAME=popbys" "CORE_STACK_DIR=$T/nope" 2>&1)" \
  && bad "missing core dir refused" || ok "missing core dir refused"
grep -qi "core stack" <<<"$out" && ok "error names the core stack dir" || bad "error names the core stack dir"

# 5. happy path exits 0
reset_logs
run "APP_NAME=popbys" "CORE_STACK_DIR=$CORE" >/dev/null 2>&1 \
  && ok "happy path exits 0" || bad "happy path exits 0"

echo; echo "passed=$pass failed=$fail"
[[ $fail -eq 0 ]]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-26-provision-app-schema.sh`
Expected: FAIL — the script does not exist, so every case errors.

- [ ] **Step 3: Write the minimal script**

Create `scripts/26-provision-app-schema.sh`:

```bash
#!/usr/bin/env bash
# 26-provision-app-schema.sh — prepare the CORE Supabase stack to host one app
# as a Postgres schema: schema, scoped owner role, grants, PostgREST
# registration, and the app's <name>_owner JWT.
#
# Stage 1 of the single-Supabase app-schema design. Touches nothing an app or
# user currently uses — safe to run before anything migrates.
#
# Run as: the service user. Idempotent.
# Input (stdin, KEY=VALUE lines):
#   APP_NAME=<^[a-z][a-z0-9_]*$, required>   Postgres identifier; hyphens invalid
#   CORE_STACK_DIR=<path>                    default $HOME/supabase-stack
set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  echo "error: run as the service user, not root" >&2; exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

APP_NAME="" ; CORE_STACK_DIR=""
while IFS='=' read -r k v || [[ -n "${k:-}" ]]; do
  case "${k}" in
    APP_NAME) APP_NAME="${v}" ;;
    CORE_STACK_DIR) CORE_STACK_DIR="${v}" ;;
  esac
done

if [[ ! "${APP_NAME}" =~ ^[a-z][a-z0-9_]*$ ]]; then
  echo "error: APP_NAME required, ^[a-z][a-z0-9_]*\$ — Postgres identifier, hyphens are not valid (got: '${APP_NAME}')" >&2
  exit 1
fi

CORE_DIR="${CORE_STACK_DIR:-${HOME}/supabase-stack}"
if [[ ! -f "${CORE_DIR}/.env" || ! -f "${CORE_DIR}/docker-compose.yml" ]]; then
  echo "error: core stack not found at ${CORE_DIR} (expected .env and docker-compose.yml)" >&2
  exit 1
fi

OWNER_ROLE="${APP_NAME}_owner"

echo "==> provisioning schema '${APP_NAME}' (owner role '${OWNER_ROLE}') in ${CORE_DIR}"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-26-provision-app-schema.sh`
Expected: PASS — 6 assertions.

- [ ] **Step 5: Commit**

```bash
git add scripts/26-provision-app-schema.sh tests/test-26-provision-app-schema.sh
git commit -m "feat(26): app schema provisioning skeleton with input guards"
```

---

### Task 2: SQL provisioning — schema, owner role, grants

**Files:**
- Modify: `scripts/26-provision-app-schema.sh` (append after the echo from Task 1)
- Modify: `tests/test-26-provision-app-schema.sh` (append before the summary block)

**Interfaces:**
- Consumes: `APP_NAME`, `CORE_DIR`, `OWNER_ROLE` from Task 1.
- Produces: the provisioned schema and role in the database, and the shell function `core_psql()` (SQL on stdin). Tasks 3-4 do not use `core_psql()` — they shell out to `docker compose` and `python3` directly — but it is the entry point for any later stage that needs SQL against the core stack.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test-26-provision-app-schema.sh`, immediately before the `echo; echo "passed=..."` summary:

```bash
# ---- SQL provisioning ----
reset_logs
run "APP_NAME=popbys" "CORE_STACK_DIR=$CORE" >/dev/null 2>&1

# positive: the things that must exist
grep -q "CREATE SCHEMA IF NOT EXISTS popbys" "$PSQL_SQL_LOG" \
  && ok "creates the schema" || bad "creates the schema"
grep -q "CREATE ROLE popbys_owner" "$PSQL_SQL_LOG" \
  && ok "creates the owner role" || bad "creates the owner role"
grep -q "ALTER SCHEMA popbys OWNER TO popbys_owner" "$PSQL_SQL_LOG" \
  && ok "role owns the schema" || bad "role owns the schema"
grep -qE "GRANT USAGE ON SCHEMA popbys TO anon, authenticated, service_role" "$PSQL_SQL_LOG" \
  && ok "PostgREST roles can reach the schema" || bad "PostgREST roles can reach the schema"
grep -q "GRANT popbys_owner TO authenticator" "$PSQL_SQL_LOG" \
  && ok "authenticator can switch into the owner role" || bad "authenticator can switch into the owner role"
grep -q "GRANT USAGE ON SCHEMA auth TO popbys_owner" "$PSQL_SQL_LOG" \
  && ok "owner may reference the auth schema" || bad "owner may reference the auth schema"
grep -q "GRANT REFERENCES ON TABLE auth.users TO popbys_owner" "$PSQL_SQL_LOG" \
  && ok "owner may FK to auth.users" || bad "owner may FK to auth.users"
grep -q "ALTER DEFAULT PRIVILEGES FOR ROLE popbys_owner IN SCHEMA popbys" "$PSQL_SQL_LOG" \
  && ok "future tables are reachable by PostgREST roles" || bad "future tables are reachable by PostgREST roles"

# NEGATIVE — these are the isolation guarantees the design rests on.
grep -qiE "GRANT .* ON SCHEMA public TO popbys_owner" "$PSQL_SQL_LOG" \
  && bad "must NOT grant on public" || ok "must NOT grant on public"
grep -qi "TRIGGER" "$PSQL_SQL_LOG" \
  && bad "must NOT grant TRIGGER on auth.users" || ok "must NOT grant TRIGGER on auth.users"
grep -q "REVOKE ALL ON SCHEMA public FROM popbys_owner" "$PSQL_SQL_LOG" \
  && ok "explicitly revokes public" || bad "explicitly revokes public"

# idempotency: a second run must not error and must not double-create
reset_logs
run "APP_NAME=popbys" "CORE_STACK_DIR=$CORE" >/dev/null 2>&1 \
  && ok "re-run exits 0" || bad "re-run exits 0"
[[ "$(grep -c 'CREATE SCHEMA IF NOT EXISTS popbys' "$PSQL_SQL_LOG")" == "1" ]] \
  && ok "re-run issues the schema create once" || bad "re-run issues the schema create once"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/test-26-provision-app-schema.sh`
Expected: FAIL — no SQL is emitted yet, so every positive assertion fails.

- [ ] **Step 3: Implement the SQL block**

Append to `scripts/26-provision-app-schema.sh`:

```bash
core_psql() {  # SQL on stdin
  docker compose -f "${CORE_DIR}/docker-compose.yml" --env-file "${CORE_DIR}/.env" \
    exec -T db psql -v ON_ERROR_STOP=1 -U postgres -d postgres
}

core_psql <<SQL
-- Owner role. CREATE ROLE has no IF NOT EXISTS, so guard it.
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${OWNER_ROLE}') THEN
    CREATE ROLE ${OWNER_ROLE} NOLOGIN;
  END IF;
END
\$\$;

CREATE SCHEMA IF NOT EXISTS ${APP_NAME} AUTHORIZATION ${OWNER_ROLE};
ALTER SCHEMA ${APP_NAME} OWNER TO ${OWNER_ROLE};

-- PostgREST's roles must reach the schema; the owner is switched into by
-- authenticator when the app presents its <name>_owner JWT.
GRANT USAGE ON SCHEMA ${APP_NAME} TO anon, authenticated, service_role;
GRANT ${OWNER_ROLE} TO authenticator;

-- Narrow, unavoidable cross-schema need: app rows FK to identity.
-- USAGE + REFERENCES only. NOT trigger, NOT select, NOT insert.
GRANT USAGE ON SCHEMA auth TO ${OWNER_ROLE};
GRANT REFERENCES ON TABLE auth.users TO ${OWNER_ROLE};

-- Tables the owner creates later must be reachable by the PostgREST roles.
ALTER DEFAULT PRIVILEGES FOR ROLE ${OWNER_ROLE} IN SCHEMA ${APP_NAME}
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE ${OWNER_ROLE} IN SCHEMA ${APP_NAME}
  GRANT USAGE, SELECT ON SEQUENCES TO anon, authenticated, service_role;

-- Isolation guarantee: the owner has no business in public.
REVOKE ALL ON SCHEMA public FROM ${OWNER_ROLE};
SQL

echo "    schema + owner role provisioned"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/test-26-provision-app-schema.sh`
Expected: PASS — 19 assertions.

- [ ] **Step 5: Commit**

```bash
git add scripts/26-provision-app-schema.sh tests/test-26-provision-app-schema.sh
git commit -m "feat(26): provision app schema, scoped owner role, and grants"
```

---

### Task 3: Register the schema with PostgREST

**Files:**
- Modify: `scripts/26-provision-app-schema.sh`
- Modify: `tests/test-26-provision-app-schema.sh`

**Interfaces:**
- Consumes: `APP_NAME`, `CORE_DIR` from Task 1.
- Produces: `PGRST_DB_SCHEMAS` in the core `.env` containing `APP_NAME`, and a recreated `rest` container.

- [ ] **Step 1: Write the failing tests**

Append before the summary block:

```bash
# ---- PostgREST registration ----
# Write CORE2 fresh rather than copying $CORE/.env — earlier happy-path runs
# already appended popbys to $CORE's PGRST_DB_SCHEMAS, so a copy would start
# from "public,popbys" and these assertions would be testing the wrong thing.
CORE2="$HOME/core2"; mkdir -p "$CORE2"
cat > "$CORE2/.env" <<'ENVEOF'
JWT_SECRET=ec3ca9f92d1de0f79e03897b324c9ec100ec647e
ANON_KEY=stub-anon
SERVICE_ROLE_KEY=stub-service
POSTGRES_PASSWORD=pw
PGRST_DB_SCHEMAS=public
ENVEOF
touch "$CORE2/docker-compose.yml"

reset_logs
run "APP_NAME=popbys" "CORE_STACK_DIR=$CORE2" >/dev/null 2>&1
grep -q "^PGRST_DB_SCHEMAS=public,popbys$" "$CORE2/.env" \
  && ok "schema appended to PGRST_DB_SCHEMAS" || bad "schema appended to PGRST_DB_SCHEMAS"
grep -q "force-recreate rest" "$DOCKER_LOG" \
  && ok "rest recreated so the schema is served" || bad "rest recreated so the schema is served"

# idempotent: re-run must not append twice
reset_logs
run "APP_NAME=popbys" "CORE_STACK_DIR=$CORE2" >/dev/null 2>&1
grep -q "^PGRST_DB_SCHEMAS=public,popbys$" "$CORE2/.env" \
  && ok "re-run leaves PGRST_DB_SCHEMAS unchanged" || bad "re-run leaves PGRST_DB_SCHEMAS unchanged"

# a second app appends rather than replaces
reset_logs
run "APP_NAME=hia" "CORE_STACK_DIR=$CORE2" >/dev/null 2>&1
grep -q "^PGRST_DB_SCHEMAS=public,popbys,hia$" "$CORE2/.env" \
  && ok "second app appends" || bad "second app appends"

# a missing key is created rather than silently skipped
CORE3="$HOME/core3"; mkdir -p "$CORE3"
grep -v '^PGRST_DB_SCHEMAS=' "$CORE/.env" > "$CORE3/.env"; touch "$CORE3/docker-compose.yml"
reset_logs
run "APP_NAME=popbys" "CORE_STACK_DIR=$CORE3" >/dev/null 2>&1
grep -q "^PGRST_DB_SCHEMAS=public,popbys$" "$CORE3/.env" \
  && ok "absent key is created with public first" || bad "absent key is created with public first"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/test-26-provision-app-schema.sh`
Expected: FAIL — `.env` is never modified and `rest` is never recreated.

- [ ] **Step 3: Implement registration**

Append to `scripts/26-provision-app-schema.sh`:

```bash
# Register the schema with PostgREST. Absent key => start from "public", which
# is the shipped default (verified on the sandbox: PGRST_DB_SCHEMAS=public).
CUR="$(grep -E '^PGRST_DB_SCHEMAS=' "${CORE_DIR}/.env" | tail -1 | cut -d= -f2- || true)"
[[ -z "${CUR}" ]] && CUR="public"

if [[ ",${CUR}," == *",${APP_NAME},"* ]]; then
  echo "    PGRST_DB_SCHEMAS already lists ${APP_NAME}"
else
  NEW="${CUR},${APP_NAME}"
  if grep -qE '^PGRST_DB_SCHEMAS=' "${CORE_DIR}/.env"; then
    sed -i "s|^PGRST_DB_SCHEMAS=.*|PGRST_DB_SCHEMAS=${NEW}|" "${CORE_DIR}/.env"
  else
    echo "PGRST_DB_SCHEMAS=${NEW}" >> "${CORE_DIR}/.env"
  fi
  echo "    PGRST_DB_SCHEMAS -> ${NEW}"
fi

docker compose -f "${CORE_DIR}/docker-compose.yml" --env-file "${CORE_DIR}/.env" \
  up -d --force-recreate rest
echo "    rest recreated"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/test-26-provision-app-schema.sh`
Expected: PASS — 24 assertions.

- [ ] **Step 5: Commit**

```bash
git add scripts/26-provision-app-schema.sh tests/test-26-provision-app-schema.sh
git commit -m "feat(26): register app schema with PostgREST idempotently"
```

---

### Task 4: Mint and emit the `<name>_owner` JWT

**Files:**
- Modify: `scripts/lib/gen-supabase-keys.py:__main__` (add a `--mint-role` mode)
- Modify: `tests/test_gen_supabase_keys.py`
- Modify: `scripts/26-provision-app-schema.sh`
- Modify: `tests/test-26-provision-app-schema.sh`
- Create: `docs/runbooks/app-schema-provisioning.md`

**Interfaces:**
- Consumes: `APP_NAME`, `CORE_DIR`, `OWNER_ROLE`.
- Produces: `python3 scripts/lib/gen-supabase-keys.py --mint-role <role>` reading the secret from **stdin** and printing one JWT; and script 26 writing `${CORE_DIR}/app-keys/<APP_NAME>.jwt` (mode 600).

- [ ] **Step 1: Write the failing test for the mint mode**

Append to `tests/test_gen_supabase_keys.py`:

```python
def test_mint_role_mode_reads_secret_from_stdin():
    """The secret must never be an argv value — it is visible in ps."""
    script = Path(__file__).resolve().parent.parent / "scripts" / "lib" / "gen-supabase-keys.py"
    secret = "ec3ca9f92d1de0f79e03897b324c9ec100ec647e"
    out = subprocess.run(
        [sys.executable, str(script), "--mint-role", "popbys_owner"],
        input=secret, capture_output=True, text=True, check=True,
    ).stdout.strip()

    header_b64, payload_b64, sig_b64 = out.split(".")

    def _unb64(s):
        return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))

    assert json.loads(_unb64(payload_b64))["role"] == "popbys_owner"
    expected = hmac.new(secret.encode(), f"{header_b64}.{payload_b64}".encode(),
                        hashlib.sha256).digest()
    assert sig_b64 == base64.urlsafe_b64encode(expected).rstrip(b"=").decode()


def test_mint_role_mode_refuses_empty_secret():
    script = Path(__file__).resolve().parent.parent / "scripts" / "lib" / "gen-supabase-keys.py"
    r = subprocess.run(
        [sys.executable, str(script), "--mint-role", "popbys_owner"],
        input="", capture_output=True, text=True,
    )
    assert r.returncode != 0
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python3 -m pytest tests/test_gen_supabase_keys.py -v`
Expected: FAIL — `--mint-role` is not recognised, so the bundle JSON is printed and `out.split(".")` raises.

- [ ] **Step 3: Add the mint mode**

Replace the `__main__` block at the end of `scripts/lib/gen-supabase-keys.py`:

```python
if __name__ == "__main__":
    import sys
    if len(sys.argv) == 3 and sys.argv[1] == "--mint-role":
        # Secret on stdin, never argv — argv is world-readable via ps.
        secret = sys.stdin.read().strip()
        if not secret:
            sys.exit("error: JWT secret required on stdin")
        print(mint_hs256_jwt(secret, sys.argv[2]))
    else:
        print(json.dumps(build_bundle()))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python3 -m pytest tests/test_gen_supabase_keys.py -v`
Expected: PASS — including the pre-existing bundle tests, which must still pass.

- [ ] **Step 5: Write the failing test for script 26 emitting the key**

Append to `tests/test-26-provision-app-schema.sh` before the summary:

```bash
# ---- owner JWT ----
reset_logs
run "APP_NAME=popbys" "CORE_STACK_DIR=$CORE" >/dev/null 2>&1
KEYFILE="$CORE/app-keys/popbys.jwt"
[[ -f "$KEYFILE" ]] && ok "owner JWT written" || bad "owner JWT written"
[[ "$(cat "$KEYFILE" 2>/dev/null | tr -cd '.' | wc -c)" == "2" ]] \
  && ok "JWT has three segments" || bad "JWT has three segments"
python3 - "$KEYFILE" <<'PY' && ok "JWT role claim is popbys_owner" || bad "JWT role claim is popbys_owner"
import base64, json, sys
tok = open(sys.argv[1]).read().strip().split(".")[1]
tok += "=" * (-len(tok) % 4)
sys.exit(0 if json.loads(base64.urlsafe_b64decode(tok))["role"] == "popbys_owner" else 1)
PY
```

(An assertion that the file "does not contain `service_role`" would be
meaningless — a JWT payload is base64, so the literal string never appears
either way. The decoded `role` claim check above is what actually proves it.)

- [ ] **Step 6: Run test to verify it fails**

Run: `bash tests/test-26-provision-app-schema.sh`
Expected: FAIL — no key file is written.

- [ ] **Step 7: Emit the key from script 26**

Append to `scripts/26-provision-app-schema.sh`:

```bash
# Mint the app's runtime key: a JWT claiming role=<name>_owner, signed with the
# core JWT secret. PostgREST switches into that role, so the app has full rights
# inside its own schema and none outside it. This REPLACES service_role for the
# app — core's service_role key must never reach an app container.
JWT_SECRET="$(grep -E '^JWT_SECRET=' "${CORE_DIR}/.env" | tail -1 | cut -d= -f2-)"
if [[ -z "${JWT_SECRET}" ]]; then
  echo "error: JWT_SECRET not found in ${CORE_DIR}/.env" >&2; exit 1
fi

mkdir -p "${CORE_DIR}/app-keys"
chmod 700 "${CORE_DIR}/app-keys"
KEYFILE="${CORE_DIR}/app-keys/${APP_NAME}.jwt"
printf '%s' "${JWT_SECRET}" \
  | python3 "${SCRIPT_DIR}/lib/gen-supabase-keys.py" --mint-role "${OWNER_ROLE}" \
  > "${KEYFILE}"
chmod 600 "${KEYFILE}"

echo "    owner JWT -> ${KEYFILE}"
echo
echo "✓ schema '${APP_NAME}' ready. Give the app:"
echo "    SUPABASE_URL       = core stack's public URL"
echo "    SUPABASE_ANON_KEY  = ANON_KEY from ${CORE_DIR}/.env"
echo "    SUPABASE_APP_KEY   = contents of ${KEYFILE}"
echo "    schema             = ${APP_NAME}   (supabase-js: db: { schema: '${APP_NAME}' })"
```

- [ ] **Step 8: Run tests to verify they pass**

Run: `bash tests/test-26-provision-app-schema.sh`
Expected: PASS — 27 assertions.

- [ ] **Step 9: Write the runbook**

Create `docs/runbooks/app-schema-provisioning.md`:

```markdown
# Provision an app schema in the core Supabase

Stage 1 of the single-Supabase design. Prepares the core stack to host one app
as a Postgres schema. Safe to run before anything migrates — it touches nothing
an app or user currently uses.

    ssh <box>
    cd ~/ollie-hermes-install
    printf 'APP_NAME=popbys\n' | bash scripts/26-provision-app-schema.sh

`APP_NAME` is a Postgres identifier: `^[a-z][a-z0-9_]*$`. Hyphens are not valid
— an app named `foo-bar` is provisioned as `foo_bar`.

What it does, idempotently:

- creates schema `<name>` owned by role `<name>_owner`
- grants the PostgREST roles `USAGE` on the schema, and `<name>_owner` to
  `authenticator` so PostgREST can switch into it
- grants `<name>_owner` only `USAGE` on `auth` and `REFERENCES` on `auth.users`
  — the narrow, unavoidable need for app rows to FK to identity
- revokes everything on `public` from `<name>_owner`
- appends the schema to `PGRST_DB_SCHEMAS` and recreates `rest`
- writes `~/supabase-stack/app-keys/<name>.jwt` (mode 600) — the app's runtime
  key, claiming `role: <name>_owner`

**The app never receives core's `service_role` key.** That key bypasses RLS and
reaches every schema plus `auth`; the whole point of the owner role is that a
compromised app cannot leave its own schema.

## Verify

    docker exec supabase-db psql -U postgres -d postgres \
      -c "\dn" -c "\du <name>_owner"
    grep PGRST_DB_SCHEMAS ~/supabase-stack/.env

Negative check — the owner must not be able to read another schema:

    docker exec supabase-db psql -U postgres -d postgres \
      -c "SET ROLE <name>_owner; SELECT count(*) FROM auth.users;"

Expected: `ERROR: permission denied for table users`. If that returns a count,
the grants are wrong and the isolation guarantee is not holding.
```

- [ ] **Step 10: Commit**

```bash
git add scripts/lib/gen-supabase-keys.py tests/test_gen_supabase_keys.py \
        scripts/26-provision-app-schema.sh tests/test-26-provision-app-schema.sh \
        docs/runbooks/app-schema-provisioning.md
git commit -m "feat(26): mint the <name>_owner JWT and document provisioning"
```

---

## Deliberately out of scope

**Storage bucket grants.** The spec lists "its own storage buckets only" among the
owner role's grants. Buckets are rows in `storage.buckets` with RLS on
`storage.objects`, and they only exist once an app creates them — there is nothing
to grant against at provisioning time. Bucket creation and its RLS land in stage 3,
per app, alongside that app's data. Of the three apps only HIA uses storage
(`inspection_pdfs`, `amendment_pdfs`, `report_pdfs`).

**Wiring into `24-install-agent-apps.sh`.** Script 26 is standalone and operator-run
in this stage. Stage 3 calls it. Wiring it into 24 now would provision unused schemas
on boxes whose apps still run on their own stacks — noise with no benefit — and 24 is
also the file the held multi-app branch rewrites.

## Acceptance

Run on the **sandbox** first, against throwaway names. The unit tests are
shim-based — the fake `docker` logs stdin and always exits 0, so they can only
prove what SQL and what `.env` edits the script *emits*. Everything that matters
about the security boundary (does the minted JWT verify, does it land in the
right role, is the schema genuinely served, can the owner leave its schema) is
only observable against a real database. That is what this section is for.

Two schemas are provisioned, because cross-app isolation cannot be tested with
one.

```bash
SB=~/supabase-stack
printf 'APP_NAME=scratch\n'  | bash scripts/26-provision-app-schema.sh   # step 1
printf 'APP_NAME=scratch2\n' | bash scripts/26-provision-app-schema.sh
ANON="$(grep -E '^ANON_KEY=' "$SB/.env" | cut -d= -f2-)"
APPJWT="$(cat "$SB/app-keys/scratch.jwt")"
```

1. **Both provision runs exit 0.**

2. **Re-run `scratch` — exits 0, `PGRST_DB_SCHEMAS` unchanged, no duplicate
   entry, no duplicate schema.**

3. **PostgREST actually received the schema list.** The `.env` value proves
   nothing on its own — `rest` has no `env_file:`, so it sees the key only
   because the compose file substitutes `${PGRST_DB_SCHEMAS:-public}`:

   ```bash
   grep '^PGRST_DB_SCHEMAS=' "$SB/.env"                   # lists scratch,scratch2
   docker exec supabase-rest env | grep PGRST_DB_SCHEMAS   # must list them too
   ```

   If the container still shows only `public`, the stack's compose file predates
   the parameterisation and must be redeployed via `11-install-supabase.sh
   --deploy`. Script 26 refuses such a stack, so this should be impossible.

4. **The owner can CREATE TABLE in its own schema** — the default privileges the
   script sets are useless if it cannot. This also exercises the `REFERENCES`
   grant on `auth.users` (the FK) and sequence creation:

   ```bash
   docker exec -i supabase-db psql -U postgres -d postgres -v ON_ERROR_STOP=1 <<'SQL'
   SET ROLE scratch_owner;
   CREATE TABLE scratch.probe (
     id bigserial PRIMARY KEY,
     user_id uuid REFERENCES auth.users(id),
     note text);
   INSERT INTO scratch.probe (note) VALUES ('hello');
   CREATE FUNCTION scratch.whoami() RETURNS text LANGUAGE sql AS 'SELECT current_user::text';
   RESET ROLE;
   SET ROLE scratch2_owner;
   CREATE TABLE scratch2.probe (id bigserial PRIMARY KEY, note text);
   INSERT INTO scratch2.probe (note) VALUES ('other app');
   SQL
   docker exec supabase-db psql -U postgres -d postgres -c "NOTIFY pgrst, 'reload schema';"
   ```

   Expected: no error. `permission denied for schema scratch` here means the
   `AUTHORIZATION` / `ALTER SCHEMA OWNER` step did not take.

5. **The schema is genuinely served** — this is the request that 404'd before the
   compose file was parameterised:

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' -H "apikey: $ANON" \
     -H 'Accept-Profile: scratch' http://127.0.0.1:8000/rest/v1/probe
   ```

   Expected `200`. A `404` whose body is `{"message":"The schema must be one of
   the following: public"}` is the exact silent failure this stage exists to
   prevent.

6. **The minted JWT is accepted and lands in the right role.** The failure mode
   without this check is silent, not loud: if PostgREST cannot verify the token
   it does **not** error — it falls back to `PGRST_DB_ANON_ROLE=anon` and serves
   the request, so the app runs with the *wrong role* (broad anon DML across
   every app schema) while looking healthy.

   ```bash
   curl -s -H "apikey: $ANON" -H "Authorization: Bearer $APPJWT" \
     -H 'Accept-Profile: scratch' -H 'Content-Profile: scratch' \
     -X POST http://127.0.0.1:8000/rest/v1/rpc/whoami
   ```

   Expected exactly `"scratch_owner"`. **`"anon"` is a failure** — the token was
   rejected and silently downgraded; check `docker logs supabase-rest` for a JWT
   error and confirm `JWT_SECRET` in `.env` is the secret the token was signed
   with. (The token is HS256 with no `kid`, verified against the legacy `oct`
   entry in `JWT_JWKS` — the same path `ANON_KEY` and `SERVICE_ROLE_KEY` already
   take, so a failure here means the secret, not the mechanism.)

7. **The owner cannot read another app's schema:**

   ```bash
   docker exec supabase-db psql -U postgres -d postgres \
     -c "SET ROLE scratch_owner; SELECT count(*) FROM scratch2.probe;"
   ```

   Expected: `ERROR: permission denied for schema scratch2`. A count means the
   consolidation's core guarantee is not holding — stop.

8. **The owner cannot read `auth.users`:**

   ```bash
   docker exec supabase-db psql -U postgres -d postgres \
     -c "SET ROLE scratch_owner; SELECT count(*) FROM auth.users;"
   ```

   Expected: `ERROR: permission denied for table users`. **This is the sharpest
   check in the list** — if it returns a count instead, stop and fix the grants
   before any app data moves. Pair it with the privilege read in the runbook
   (`has_table_privilege(...,'auth.users','SELECT'|'TRIGGER')` must both be `f`),
   which reads the privileges directly rather than inferring them.

9. **Mandatory RLS coverage.** Every app is handed the *same* core `ANON_KEY`,
   and `anon`/`authenticated` hold `USAGE` on every app schema plus DML on its
   tables — they must, for user-context requests. So app A's browser bundle
   carries a key that reaches app B's schema, and the only control is RLS:

   ```bash
   docker exec supabase-db psql -U postgres -d postgres -c "
     SELECT relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'scratch' AND c.relkind = 'r' AND NOT c.relrowsecurity;"
   ```

   **Every row returned is a table that every app on the box can read — and
   write — with the shared anon key.** An empty result is the gate.

   At this stage `scratch.probe` (created in step 4 without RLS) *will* be
   returned — which is what proves the query works, and the hazard is real.
   Demonstrate it, using the same anon key against the *other* app's schema:

   ```bash
   curl -s -H "apikey: $ANON" -H 'Accept-Profile: scratch2' \
     http://127.0.0.1:8000/rest/v1/probe
   ```

   That returns `[{"id":1,"note":"other app"}]` — one app's key reading another
   app's data, because RLS is off. Then enable RLS on `scratch2.probe`
   (`ALTER TABLE scratch2.probe ENABLE ROW LEVEL SECURITY;`) and re-run both: the
   query returns nothing and the curl returns `[]`. Stage 3 migrations must
   enable RLS on every table they create, and this query is the gate on each.

10. `curl -s -o /dev/null -w '%{http_code}' -H "apikey: $ANON"
    http://127.0.0.1:8000/rest/v1/` still returns its normal status — existing
    apps are unaffected. Note this one proves only that nothing *broke*: it
    passed unchanged while registration was a no-op, so it can never stand in
    for steps 5 and 6.

11. **Clean up:**

    ```bash
    docker exec -i supabase-db psql -U postgres -d postgres <<'SQL'
    DROP SCHEMA scratch CASCADE;
    DROP SCHEMA scratch2 CASCADE;
    DROP OWNED BY scratch_owner;    -- default-privilege entries survive DROP SCHEMA
    DROP OWNED BY scratch2_owner;
    DROP ROLE scratch_owner;
    DROP ROLE scratch2_owner;
    SQL
    # remove scratch,scratch2 from PGRST_DB_SCHEMAS, then:
    docker compose -f "$SB/docker-compose.yml" --env-file "$SB/.env" up -d --force-recreate rest
    rm -f "$SB"/app-keys/scratch.jwt "$SB"/app-keys/scratch2.jwt
    ```

Nothing in this stage touches a running app. If acceptance fails, nothing needs
rolling back beyond the cleanup in step 11.
