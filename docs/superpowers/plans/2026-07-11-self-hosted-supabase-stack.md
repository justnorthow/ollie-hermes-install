# Self-Hosted Supabase Stack (Install Repo) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every Ollie box a co-located, trimmed self-hosted Supabase stack (Postgres + GoTrue + PostgREST + Storage behind Kong), deployed idempotently by `11-install-supabase.sh --deploy`, replacing the hosted-project dependency.

**Architecture:** A second compose project at `~/supabase-stack/` (vendored from `templates/supabase/`), with keys generated on-box by a testable Python generator and an idempotent `.env` renderer that preserves secrets across re-runs (the S72 lesson). Kong publishes on `127.0.0.1:8000`; the browser reaches it via a cloudflared hostname (`sb.<instance-host>`). The existing `11-install-supabase.sh` apply path (orchestrator env write → schema probe → restart) is reused verbatim as the tail of deploy mode.

**Tech Stack:** Bash (strict mode, sourceable libs), Python 3 stdlib + openssl CLI (key generation), Docker Compose, Kong 2.8 declarative config, supabase/postgres, supabase/gotrue, postgrest, supabase/storage-api.

**Spec:** `docs/superpowers/specs/2026-07-11-self-hosted-supabase-design.md`

**Out of scope (follow-up plans):** ollie-fleet provision-form changes (Plan 2); sandbox/apps-VPS/prod data migrations (Plan 3, runbook-style); fleetctl `update supabase` step; PITR/offsite backups.

## Global Constraints

- All scripts run as the service user (`ollie`), never root — copy the existing `id -u` guard.
- Bash: `set -euo pipefail` in executables; `set -uo pipefail` in sourceable libs (match `supabase-env.sh`).
- Images MUST be pinned to exact tags in the renderer (never `latest`); pins are NOT preserved across re-runs — renderer values are authoritative (same rule as `CORTEX_IMAGE`/`FRONTEND_IMAGE` in `stack-env.sh`).
- Secrets (POSTGRES_PASSWORD, JWT material, ANON/SERVICE keys, Google creds) ARE preserved across re-runs — a re-run must never rotate keys or blank values (S72 class).
- Kong binds `127.0.0.1:8000` only. Exposure posture stays "only :22 open"; public access is cloudflared-only.
- Bash tests use `tests/lib/assert.sh` + a `test-<name>.sh` runner; Python tests use pytest, mirroring `tests/test_seed_operator_role.py`.
- Secrets arrive on stdin as KEY=VALUE lines, never argv (existing 11-install pattern).
- Commit after every task; conventional-commit messages; do not push.

---

### Task 1: Key generator — `gen-supabase-keys.py`

Generates the full key bundle for one box: legacy `JWT_SECRET` (HS256), anon + service_role API-key JWTs signed with it, an ES256 keypair, and the `GOTRUE_JWT_KEYS` / `JWT_JWKS` JSON blobs per the Supabase self-hosted signing-keys docs (`supabase.com/docs/guides/self-hosting/self-hosted-auth-keys`).

**Files:**
- Create: `scripts/lib/gen-supabase-keys.py`
- Test: `tests/test_gen_supabase_keys.py`

**Interfaces:**
- Consumes: `openssl` CLI (present on all boxes; also on dev machines for tests).
- Produces: CLI contract used by Task 2 — `python3 gen-supabase-keys.py` prints a single JSON object to stdout:
  `{"jwt_secret": str, "anon_key": str, "service_role_key": str, "gotrue_jwt_keys": str, "jwt_jwks": str, "postgres_password": str}`
  where `gotrue_jwt_keys` is a JSON-encoded array (private ES256 JWK + legacy oct JWK) and `jwt_jwks` is a JSON-encoded `{"keys":[...]}` public set (EC public JWK without `d`, plus the oct verify-only JWK). Also importable: `mint_hs256_jwt(secret, role, iat)`, `ec_pem_to_jwk(pem_text, kid)`, `build_bundle(...)`.

- [ ] **Step 1: Write the failing tests**

```python
# tests/test_gen_supabase_keys.py
import base64, hashlib, hmac, json, subprocess, sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts" / "lib"))
gen = __import__("gen-supabase-keys")

# Fixed P-256 key so JWK output is deterministic.
FIXED_PEM = subprocess.run(
    ["openssl", "ecparam", "-genkey", "-name", "prime256v1", "-noout"],
    capture_output=True, text=True, check=True,
).stdout

def b64url_decode(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))

def test_mint_hs256_jwt_known_vector():
    tok = gen.mint_hs256_jwt("test-secret", "anon", iat=1700000000)
    h, p, sig = tok.split(".")
    assert json.loads(b64url_decode(h)) == {"alg": "HS256", "typ": "JWT"}
    payload = json.loads(b64url_decode(p))
    assert payload["role"] == "anon"
    assert payload["iss"] == "supabase"
    assert payload["exp"] == 1700000000 + 10 * 365 * 24 * 3600
    expect = hmac.new(b"test-secret", f"{h}.{p}".encode(), hashlib.sha256).digest()
    assert b64url_decode(sig) == expect

def test_ec_pem_to_jwk_roundtrip():
    jwk = gen.ec_pem_to_jwk(FIXED_PEM, kid="test-kid")
    assert jwk["kty"] == "EC" and jwk["crv"] == "P-256" and jwk["alg"] == "ES256"
    assert jwk["kid"] == "test-kid"
    # x, y are 32-byte coords; d is the 32-byte private scalar.
    assert len(b64url_decode(jwk["x"])) == 32
    assert len(b64url_decode(jwk["y"])) == 32
    assert len(b64url_decode(jwk["d"])) == 32

def test_build_bundle_shape():
    bundle = gen.build_bundle()
    for k in ("jwt_secret", "anon_key", "service_role_key",
              "gotrue_jwt_keys", "jwt_jwks", "postgres_password"):
        assert bundle[k], f"missing {k}"
    keys = json.loads(bundle["gotrue_jwt_keys"])
    algs = {k["alg"] for k in keys}
    assert algs == {"ES256", "HS256"}
    # Private material only in gotrue_jwt_keys, never in the public JWKS.
    jwks = json.loads(bundle["jwt_jwks"])["keys"]
    ec_pub = [k for k in jwks if k["kty"] == "EC"][0]
    assert "d" not in ec_pub
    # anon/service tokens verify against jwt_secret.
    tok = bundle["anon_key"]
    h, p, sig = tok.split(".")
    expect = hmac.new(bundle["jwt_secret"].encode(), f"{h}.{p}".encode(),
                      hashlib.sha256).digest()
    assert b64url_decode(sig) == expect
    assert json.loads(b64url_decode(p))["role"] == "anon"

def test_cli_prints_json():
    out = subprocess.run(
        [sys.executable, "scripts/lib/gen-supabase-keys.py"],
        capture_output=True, text=True, check=True, cwd=Path(__file__).resolve().parent.parent,
    ).stdout
    assert set(json.loads(out)) == {"jwt_secret", "anon_key", "service_role_key",
                                    "gotrue_jwt_keys", "jwt_jwks", "postgres_password"}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python3 -m pytest tests/test_gen_supabase_keys.py -v`
Expected: FAIL / import error (module has no attributes).

- [ ] **Step 3: Write the implementation**

```python
#!/usr/bin/env python3
"""gen-supabase-keys.py — generate the per-box Supabase key bundle.

Prints one JSON object to stdout. No third-party deps: EC keygen shells out
to the openssl CLI; HS256 JWTs are minted with stdlib hmac. Formats follow
supabase.com/docs/guides/self-hosting/self-hosted-auth-keys:
  - gotrue_jwt_keys -> GOTRUE_JWT_KEYS (private ES256 JWK + legacy oct JWK)
  - jwt_jwks        -> JWT_JWKS for PostgREST/Storage (public EC + oct verify)
"""
import base64, hashlib, hmac, json, re, secrets, subprocess, time


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def mint_hs256_jwt(secret: str, role: str, iat: int | None = None) -> str:
    iat = int(time.time()) if iat is None else iat
    header = _b64url(json.dumps({"alg": "HS256", "typ": "JWT"},
                                separators=(",", ":")).encode())
    payload = _b64url(json.dumps(
        {"role": role, "iss": "supabase", "iat": iat,
         "exp": iat + 10 * 365 * 24 * 3600},
        separators=(",", ":")).encode())
    sig = hmac.new(secret.encode(), f"{header}.{payload}".encode(),
                   hashlib.sha256).digest()
    return f"{header}.{payload}.{_b64url(sig)}"


def _openssl_ec_text(pem: str) -> str:
    return subprocess.run(["openssl", "ec", "-text", "-noout"],
                          input=pem, capture_output=True, text=True,
                          check=True).stdout


def _hex_block(text: str, label: str) -> bytes:
    """Extract openssl's indented colon-hex block following `label:`."""
    m = re.search(rf"{label}:\n((?:\s+[0-9a-f:]+\n)+)", text)
    if not m:
        raise ValueError(f"openssl output missing {label} block")
    return bytes.fromhex(m.group(1).replace(":", "").replace(" ", "").replace("\n", ""))


def ec_pem_to_jwk(pem: str, kid: str) -> dict:
    text = _openssl_ec_text(pem)
    priv = _hex_block(text, "priv")
    pub = _hex_block(text, "pub")
    if pub[0] != 0x04 or len(pub) != 65:
        raise ValueError("expected uncompressed P-256 public point")
    d = priv[-32:]  # openssl may emit a leading 0x00 pad byte
    return {"kty": "EC", "crv": "P-256", "alg": "ES256", "kid": kid,
            "key_ops": ["sign", "verify"],
            "x": _b64url(pub[1:33]), "y": _b64url(pub[33:65]),
            "d": _b64url(d)}


def build_bundle() -> dict:
    jwt_secret = secrets.token_hex(20)
    pem = subprocess.run(
        ["openssl", "ecparam", "-genkey", "-name", "prime256v1", "-noout"],
        capture_output=True, text=True, check=True).stdout
    ec_priv = ec_pem_to_jwk(pem, kid=secrets.token_hex(8))
    ec_pub = {k: v for k, v in ec_priv.items() if k != "d"}
    ec_pub["key_ops"] = ["verify"]
    oct_jwk = {"kty": "oct", "alg": "HS256", "kid": "legacy",
               "key_ops": ["verify"], "k": _b64url(jwt_secret.encode())}
    return {
        "jwt_secret": jwt_secret,
        "anon_key": mint_hs256_jwt(jwt_secret, "anon"),
        "service_role_key": mint_hs256_jwt(jwt_secret, "service_role"),
        "gotrue_jwt_keys": json.dumps([ec_priv, {**oct_jwk}],
                                      separators=(",", ":")),
        "jwt_jwks": json.dumps({"keys": [ec_pub, oct_jwk]},
                               separators=(",", ":")),
        "postgres_password": secrets.token_hex(24),
    }


if __name__ == "__main__":
    print(json.dumps(build_bundle()))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python3 -m pytest tests/test_gen_supabase_keys.py -v`
Expected: 4 PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/gen-supabase-keys.py tests/test_gen_supabase_keys.py
git commit -m "feat(supabase): per-box key bundle generator (ES256 + legacy HS256, stdlib+openssl)"
```

---

### Task 2: Supabase stack `.env` renderer — `supabase-stack-env.sh`

Idempotent renderer for `~/supabase-stack/.env`: generates the key bundle on first run, preserves ALL secrets on re-runs, always stamps the current image pins.

**Files:**
- Create: `scripts/lib/supabase-stack-env.sh`
- Test: `tests/test-supabase-stack-env.sh`

**Interfaces:**
- Consumes: `gen-supabase-keys.py` CLI JSON (Task 1); caller-exported `SUPABASE_PUBLIC_URL`, optional `GOOGLE_CLIENT_ID`/`GOOGLE_CLIENT_SECRET`.
- Produces: `render_supabase_stack_env OUT_PATH OLD_PATH` writing keys consumed by the Task 3 compose file: `POSTGRES_PASSWORD JWT_SECRET GOTRUE_JWT_KEYS JWT_JWKS ANON_KEY SERVICE_ROLE_KEY SUPABASE_PUBLIC_URL GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET GOOGLE_ENABLED SB_DB_IMAGE SB_AUTH_IMAGE SB_REST_IMAGE SB_STORAGE_IMAGE SB_KONG_IMAGE`. Also `supabase_stack_env_val FILE KEY` (read-back helper reused by Task 4).

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# tests/test-supabase-stack-env.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/assert.sh"
. "$HERE/../scripts/lib/supabase-stack-env.sh"

test_fresh_render_generates_secrets_and_pins() {
  local d; d="$(mktemp -d)"
  export SUPABASE_PUBLIC_URL="https://sb.example.jnow.io"
  export GOOGLE_CLIENT_ID="" GOOGLE_CLIENT_SECRET=""
  render_supabase_stack_env "$d/.env" ""
  for k in POSTGRES_PASSWORD JWT_SECRET GOTRUE_JWT_KEYS JWT_JWKS ANON_KEY \
           SERVICE_ROLE_KEY SB_DB_IMAGE SB_AUTH_IMAGE SB_REST_IMAGE \
           SB_STORAGE_IMAGE SB_KONG_IMAGE; do
    v="$(supabase_stack_env_val "$d/.env" "$k")"
    assert_nonempty "fresh render sets $k" "$v"
  done
  assert_eq "google disabled when no client id" \
    "$(supabase_stack_env_val "$d/.env" GOOGLE_ENABLED)" "false"
  # No image pin may ever be 'latest'.
  ! grep -E '^SB_.*_IMAGE=.*latest' "$d/.env"
  assert_eq "no latest pins" "$?" "0"
}

test_rerun_preserves_secrets_and_restamps_pins() {
  local d; d="$(mktemp -d)"
  export SUPABASE_PUBLIC_URL="https://sb.example.jnow.io"
  export GOOGLE_CLIENT_ID="gid" GOOGLE_CLIENT_SECRET="gsec"
  render_supabase_stack_env "$d/.env" ""
  local secret1 anon1
  secret1="$(supabase_stack_env_val "$d/.env" JWT_SECRET)"
  anon1="$(supabase_stack_env_val "$d/.env" ANON_KEY)"
  # Simulate an old pin so we can prove pins get restamped, secrets don't.
  sed -i 's|^SB_KONG_IMAGE=.*|SB_KONG_IMAGE=kong:0.0-old|' "$d/.env"
  cp "$d/.env" "$d/.env.old"
  render_supabase_stack_env "$d/.env" "$d/.env.old"
  assert_eq "JWT_SECRET preserved" \
    "$(supabase_stack_env_val "$d/.env" JWT_SECRET)" "$secret1"
  assert_eq "ANON_KEY preserved" \
    "$(supabase_stack_env_val "$d/.env" ANON_KEY)" "$anon1"
  assert_eq "google creds preserved" \
    "$(supabase_stack_env_val "$d/.env" GOOGLE_CLIENT_SECRET)" "gsec"
  assert_eq "google enabled with client id" \
    "$(supabase_stack_env_val "$d/.env" GOOGLE_ENABLED)" "true"
  [ "$(supabase_stack_env_val "$d/.env" SB_KONG_IMAGE)" != "kong:0.0-old" ]
  assert_eq "pin restamped from renderer" "$?" "0"
}

run_tests "$@"
```

(Confirm `tests/lib/assert.sh` provides `assert_nonempty`; if not, add it there alongside `assert_eq`, following its existing style, and cover it in this test run.)

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-supabase-stack-env.sh`
Expected: FAIL — `supabase-stack-env.sh: No such file or directory`.

- [ ] **Step 3: Write the implementation**

```bash
#!/usr/bin/env bash
# supabase-stack-env.sh — idempotent renderer for ~/supabase-stack/.env.
# Sourceable + unit-testable. Secrets are generated once and preserved on
# every re-run; image pins are ALWAYS restamped from the values below
# (same authority rule as stack-env.sh — never preserve pins).
set -uo pipefail

# Pinned images. Bump here (sandbox-first) — verify against the current
# supabase/docker compose (github.com/supabase/supabase/tree/master/docker)
# when bumping.
SB_DB_IMAGE_PIN="supabase/postgres:15.8.1.085"
SB_AUTH_IMAGE_PIN="supabase/gotrue:v2.177.0"
SB_REST_IMAGE_PIN="postgrest/postgrest:v12.2.12"
SB_STORAGE_IMAGE_PIN="supabase/storage-api:v1.25.7"
SB_KONG_IMAGE_PIN="kong:2.8.1"

supabase_stack_env_val() { # FILE KEY
  [ -f "$1" ] || return 0
  grep -E "^$2=" "$1" | tail -1 | cut -d= -f2- || true
}

# Resolve a secret: old .env value wins (never rotate); else from bundle.
_sb_keep() { # KEY OLDENV BUNDLE_JSON_KEY BUNDLE
  local old_v; old_v="$(supabase_stack_env_val "$2" "$1")"
  if [ -n "$old_v" ]; then printf '%s' "$old_v"; else
    printf '%s' "$4" | python3 -c "import sys,json;print(json.load(sys.stdin)['$3'])"
  fi
}

render_supabase_stack_env() { # OUT OLD
  local out="$1" old="${2:-}"
  local bundle=""
  # Generate a bundle only if any secret is missing from the old env.
  local need=0 k
  for k in POSTGRES_PASSWORD JWT_SECRET GOTRUE_JWT_KEYS JWT_JWKS ANON_KEY SERVICE_ROLE_KEY; do
    [ -z "$(supabase_stack_env_val "$old" "$k")" ] && need=1
  done
  if [ "$need" -eq 1 ]; then
    bundle="$(python3 "$(dirname "${BASH_SOURCE[0]}")/gen-supabase-keys.py")"
  fi
  local pg jwt gkeys jwks anon srk
  pg="$(_sb_keep POSTGRES_PASSWORD "$old" postgres_password "$bundle")"
  jwt="$(_sb_keep JWT_SECRET "$old" jwt_secret "$bundle")"
  gkeys="$(_sb_keep GOTRUE_JWT_KEYS "$old" gotrue_jwt_keys "$bundle")"
  jwks="$(_sb_keep JWT_JWKS "$old" jwt_jwks "$bundle")"
  anon="$(_sb_keep ANON_KEY "$old" anon_key "$bundle")"
  srk="$(_sb_keep SERVICE_ROLE_KEY "$old" service_role_key "$bundle")"
  # Operator-supplied: exported value wins, else carried forward.
  local url gid gsec
  url="${SUPABASE_PUBLIC_URL:-$(supabase_stack_env_val "$old" SUPABASE_PUBLIC_URL)}"
  gid="${GOOGLE_CLIENT_ID:-$(supabase_stack_env_val "$old" GOOGLE_CLIENT_ID)}"
  gsec="${GOOGLE_CLIENT_SECRET:-$(supabase_stack_env_val "$old" GOOGLE_CLIENT_SECRET)}"
  local genabled="false"; [ -n "$gid" ] && genabled="true"
  cat > "$out" <<EOF
# Generated by supabase-stack-env.sh — re-run 11-install-supabase.sh --deploy to refresh.
POSTGRES_PASSWORD=${pg}
JWT_SECRET=${jwt}
GOTRUE_JWT_KEYS=${gkeys}
JWT_JWKS=${jwks}
ANON_KEY=${anon}
SERVICE_ROLE_KEY=${srk}
SUPABASE_PUBLIC_URL=${url}
GOOGLE_ENABLED=${genabled}
GOOGLE_CLIENT_ID=${gid}
GOOGLE_CLIENT_SECRET=${gsec}
SB_DB_IMAGE=${SB_DB_IMAGE_PIN}
SB_AUTH_IMAGE=${SB_AUTH_IMAGE_PIN}
SB_REST_IMAGE=${SB_REST_IMAGE_PIN}
SB_STORAGE_IMAGE=${SB_STORAGE_IMAGE_PIN}
SB_KONG_IMAGE=${SB_KONG_IMAGE_PIN}
EOF
  chmod 600 "$out"
  return 0
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-supabase-stack-env.sh`
Expected: both tests PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/supabase-stack-env.sh tests/test-supabase-stack-env.sh
git commit -m "feat(supabase): idempotent supabase-stack .env renderer (secrets preserved, pins authoritative)"
```

---

### Task 3: Stack templates — compose + Kong declarative config

**Files:**
- Create: `templates/supabase/docker-compose.yml`
- Create: `templates/supabase/kong.yml`
- Test: `tests/test-supabase-compose.sh`

**Interfaces:**
- Consumes: every `.env` key from Task 2 (exact names above).
- Produces: compose project `supabase` with services `db`, `auth`, `rest`, `storage`, `kong`; Kong on `127.0.0.1:8000`; routes `/auth/v1/*`, `/rest/v1/*`, `/storage/v1/*`. Task 4 depends on these service names and the port.

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# tests/test-supabase-compose.sh — static checks; docker not required.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/assert.sh"
COMPOSE="$HERE/../templates/supabase/docker-compose.yml"
KONG="$HERE/../templates/supabase/kong.yml"

test_compose_shape() {
  assert_file_exists "compose exists" "$COMPOSE"
  for svc in "db:" "auth:" "rest:" "storage:" "kong:"; do
    grep -qE "^  ${svc}" "$COMPOSE"; assert_eq "service ${svc}" "$?" "0"
  done
  # Only Kong publishes, loopback only.
  assert_eq "exactly one ports block" "$(grep -c 'ports:' "$COMPOSE")" "1"
  grep -q '127.0.0.1:8000:8000' "$COMPOSE"; assert_eq "kong loopback" "$?" "0"
  # Trimmed: no realtime/functions/analytics/studio services.
  for absent in realtime functions analytics studio imgproxy; do
    ! grep -qE "^  ${absent}:" "$COMPOSE"
    assert_eq "no ${absent} service" "$?" "0"
  done
  # Every image comes from a required .env pin (no inline tags, no latest).
  assert_eq "5 pinned image refs" \
    "$(grep -cE 'image: \$\{SB_(DB|AUTH|REST|STORAGE|KONG)_IMAGE:\?' "$COMPOSE")" "5"
  # Hook + signing keys env present on auth.
  grep -q 'GOTRUE_HOOK_CUSTOM_ACCESS_TOKEN_ENABLED' "$COMPOSE"; assert_eq "hook env" "$?" "0"
  grep -q 'GOTRUE_JWT_KEYS' "$COMPOSE"; assert_eq "signing keys env" "$?" "0"
}

test_kong_routes_and_consumers() {
  assert_file_exists "kong.yml exists" "$KONG"
  for path in "/auth/v1" "/rest/v1" "/storage/v1"; do
    grep -q -- "$path" "$KONG"; assert_eq "route $path" "$?" "0"
  done
  for consumer in "anon" "service_role"; do
    grep -q "username: ${consumer}" "$KONG"; assert_eq "consumer $consumer" "$?" "0"
  done
}

run_tests "$@"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-supabase-compose.sh`
Expected: FAIL — compose file missing.

- [ ] **Step 3: Write `templates/supabase/docker-compose.yml`**

```yaml
# Trimmed self-hosted Supabase for one Ollie box: db + auth + rest + storage
# behind Kong. No Realtime / Edge Functions / analytics / Studio (run Studio
# ad-hoc if ever needed; migrations go through psql).
# Spec: docs/superpowers/specs/2026-07-11-self-hosted-supabase-design.md
# Derived from github.com/supabase/supabase/tree/master/docker — when bumping
# image pins (scripts/lib/supabase-stack-env.sh), re-diff env vars against it.
name: supabase
services:
  db:
    image: ${SB_DB_IMAGE:?pinned in .env by supabase-stack-env.sh}
    container_name: supabase-db
    restart: unless-stopped
    environment:
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - POSTGRES_HOST=/var/run/postgresql
      - PGPORT=5432
      - JWT_SECRET=${JWT_SECRET}
      - JWT_EXP=3600
    volumes:
      - db-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "postgres", "-h", "localhost"]
      interval: 5s
      timeout: 5s
      retries: 20

  auth:
    image: ${SB_AUTH_IMAGE:?pinned in .env by supabase-stack-env.sh}
    container_name: supabase-auth
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    environment:
      - GOTRUE_API_HOST=0.0.0.0
      - GOTRUE_API_PORT=9999
      - API_EXTERNAL_URL=${SUPABASE_PUBLIC_URL}
      - GOTRUE_DB_DRIVER=postgres
      - GOTRUE_DB_DATABASE_URL=postgres://supabase_auth_admin:${POSTGRES_PASSWORD}@db:5432/postgres
      - GOTRUE_SITE_URL=${SUPABASE_PUBLIC_URL}
      - GOTRUE_URI_ALLOW_LIST=*
      - GOTRUE_DISABLE_SIGNUP=false
      - GOTRUE_JWT_ADMIN_ROLES=service_role
      - GOTRUE_JWT_AUD=authenticated
      - GOTRUE_JWT_DEFAULT_GROUP_NAME=authenticated
      - GOTRUE_JWT_EXP=3600
      - GOTRUE_JWT_SECRET=${JWT_SECRET}
      # Asymmetric user-token signing (ES256) + legacy HS256 verification.
      - GOTRUE_JWT_KEYS=${GOTRUE_JWT_KEYS}
      # ollie-core access-token hook (created by supabase/ollie-core/0006).
      - GOTRUE_HOOK_CUSTOM_ACCESS_TOKEN_ENABLED=true
      - GOTRUE_HOOK_CUSTOM_ACCESS_TOKEN_URI=pg-functions://postgres/public/custom_access_token_hook
      # Google-only sign-in; SMTP intentionally unconfigured.
      - GOTRUE_EXTERNAL_GOOGLE_ENABLED=${GOOGLE_ENABLED}
      - GOTRUE_EXTERNAL_GOOGLE_CLIENT_ID=${GOOGLE_CLIENT_ID}
      - GOTRUE_EXTERNAL_GOOGLE_SECRET=${GOOGLE_CLIENT_SECRET}
      - GOTRUE_EXTERNAL_GOOGLE_REDIRECT_URI=${SUPABASE_PUBLIC_URL}/auth/v1/callback
      - GOTRUE_MAILER_AUTOCONFIRM=true

  rest:
    image: ${SB_REST_IMAGE:?pinned in .env by supabase-stack-env.sh}
    container_name: supabase-rest
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    environment:
      - PGRST_DB_URI=postgres://authenticator:${POSTGRES_PASSWORD}@db:5432/postgres
      - PGRST_DB_SCHEMAS=public
      - PGRST_DB_ANON_ROLE=anon
      - PGRST_JWT_SECRET=${JWT_JWKS}
      - PGRST_DB_USE_LEGACY_GUCS=false

  storage:
    image: ${SB_STORAGE_IMAGE:?pinned in .env by supabase-stack-env.sh}
    container_name: supabase-storage
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
      rest:
        condition: service_started
    environment:
      - ANON_KEY=${ANON_KEY}
      - SERVICE_KEY=${SERVICE_ROLE_KEY}
      - POSTGREST_URL=http://rest:3000
      - PGRST_JWT_SECRET=${JWT_JWKS}
      - DATABASE_URL=postgres://supabase_storage_admin:${POSTGRES_PASSWORD}@db:5432/postgres
      - FILE_SIZE_LIMIT=52428800
      - STORAGE_BACKEND=file
      - FILE_STORAGE_BACKEND_PATH=/var/lib/storage
      - TENANT_ID=stub
      - REGION=stub
      - GLOBAL_S3_BUCKET=stub
      - ENABLE_IMAGE_TRANSFORMATION=false
    volumes:
      - storage-data:/var/lib/storage

  kong:
    image: ${SB_KONG_IMAGE:?pinned in .env by supabase-stack-env.sh}
    container_name: supabase-kong
    restart: unless-stopped
    depends_on:
      - auth
      - rest
      - storage
    ports:
      # Loopback only — public access is cloudflared (sb.<host> -> :8000).
      - "127.0.0.1:8000:8000"
    environment:
      - KONG_DATABASE=off
      - KONG_DECLARATIVE_CONFIG=/home/kong/kong.yml
      - KONG_DNS_ORDER=LAST,A,CNAME
      - KONG_PLUGINS=request-transformer,cors,key-auth,acl
      # The template references the anon/service keys; render at container
      # start via KONG_NGINX-less env substitution is not available in kong
      # 2.8, so Task 4 renders kong.yml with the real keys before `up`.
    volumes:
      - ./kong.yml:/home/kong/kong.yml:ro

volumes:
  db-data:
  storage-data:
```

- [ ] **Step 4: Write `templates/supabase/kong.yml`**

`__ANON_KEY__` / `__SERVICE_ROLE_KEY__` are placeholders substituted by the deploy script (Task 4) when staging the file into `~/supabase-stack/` — Kong 2.8 declarative config cannot read env vars.

```yaml
_format_version: "2.1"

consumers:
  - username: anon
    keyauth_credentials:
      - key: __ANON_KEY__
  - username: service_role
    keyauth_credentials:
      - key: __SERVICE_ROLE_KEY__

acls:
  - consumer: anon
    group: anon
  - consumer: service_role
    group: admin

services:
  - name: auth-v1
    url: http://auth:9999/
    routes:
      - name: auth-v1
        strip_path: true
        paths: ["/auth/v1/"]
    plugins:
      - name: cors

  - name: rest-v1
    url: http://rest:3000/
    routes:
      - name: rest-v1
        strip_path: true
        paths: ["/rest/v1/"]
    plugins:
      - name: cors
      - name: key-auth
        config:
          key_names: ["apikey"]
          hide_credentials: true
      - name: acl
        config:
          hide_groups_header: true
          allow: ["admin", "anon"]

  - name: storage-v1
    url: http://storage:5000/
    routes:
      - name: storage-v1
        strip_path: true
        paths: ["/storage/v1/"]
    plugins:
      - name: cors
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/test-supabase-compose.sh`
Expected: both tests PASS. (`assert_file_exists` — add to `tests/lib/assert.sh` if absent, matching its style.)

- [ ] **Step 6: Sanity-check compose interpolation**

```bash
cd templates/supabase && cat > /tmp/sb-test.env <<'EOF'
POSTGRES_PASSWORD=x
JWT_SECRET=x
GOTRUE_JWT_KEYS=[]
JWT_JWKS={"keys":[]}
ANON_KEY=x
SERVICE_ROLE_KEY=x
SUPABASE_PUBLIC_URL=https://sb.example.jnow.io
GOOGLE_ENABLED=false
GOOGLE_CLIENT_ID=
GOOGLE_CLIENT_SECRET=
SB_DB_IMAGE=supabase/postgres:15.8.1.085
SB_AUTH_IMAGE=supabase/gotrue:v2.177.0
SB_REST_IMAGE=postgrest/postgrest:v12.2.12
SB_STORAGE_IMAGE=supabase/storage-api:v1.25.7
SB_KONG_IMAGE=kong:2.8.1
EOF
docker compose --env-file /tmp/sb-test.env config >/dev/null && echo OK
```

Expected: `OK` (run where docker is available; on the Windows dev machine use Docker Desktop, else defer to the sandbox verification in Task 5).

- [ ] **Step 7: Commit**

```bash
git add templates/supabase/ tests/test-supabase-compose.sh
git commit -m "feat(supabase): trimmed self-hosted stack templates (db/auth/rest/storage/kong)"
```

---

### Task 4: `11-install-supabase.sh --deploy` mode

Deploy the local stack end-to-end, then reuse the existing apply tail. Also add a pure `supabase_render_kong` helper to `supabase-env.sh` so the substitution is unit-tested.

**Files:**
- Modify: `scripts/11-install-supabase.sh` (mode dispatch at lines 39–58; keep apply/verify behavior byte-identical)
- Modify: `scripts/lib/supabase-env.sh` (add `supabase_render_kong`, `supabase_write_stack_dashboard_env`)
- Test: `tests/test-supabase-env.sh` (extend)

**Interfaces:**
- Consumes: `render_supabase_stack_env` + `supabase_stack_env_val` (Task 2); templates (Task 3); existing `supabase_validate_inputs`, `supabase_write_orch_env`, `supabase_schema_probe_url`.
- Produces: `bash 11-install-supabase.sh --deploy` with stdin `SUPABASE_PUBLIC_URL=...`, optional `GOOGLE_CLIENT_ID=...`, `GOOGLE_CLIENT_SECRET=...`. On success: stack up, migrations applied, orchestrator configured + healthy, `~/hermes-stack/.env` carries `SUPABASE_URL`/`SUPABASE_ANON_KEY`, dashboard recreated. Prints `ANON_KEY` + `SERVICE_ROLE_KEY` for Fleet to store (Plan 2 consumes this).

- [ ] **Step 1: Write failing tests for the new pure helpers**

Append to `tests/test-supabase-env.sh` (before the final `run_tests` line):

```bash
test_render_kong_substitutes_keys() {
  local d; d="$(mktemp -d)"
  printf 'key: __ANON_KEY__\nother: __SERVICE_ROLE_KEY__\n' > "$d/kong.tpl"
  supabase_render_kong "$d/kong.tpl" "$d/kong.yml" "anon-123" "svc-456"
  grep -q 'key: anon-123' "$d/kong.yml"; assert_eq "anon substituted" "$?" "0"
  grep -q 'other: svc-456' "$d/kong.yml"; assert_eq "service substituted" "$?" "0"
  ! grep -q '__' "$d/kong.yml"; assert_eq "no placeholders remain" "$?" "0"
}

test_write_stack_dashboard_env_idempotent() {
  local d; d="$(mktemp -d)"
  printf 'FRONTEND_IMAGE=x\nSUPABASE_URL=old\n' > "$d/stack.env"
  supabase_write_stack_dashboard_env "$d/stack.env" "https://sb.new.jnow.io" "anon-key"
  assert_count "one SUPABASE_URL line" "$d/stack.env" SUPABASE_URL 1
  grep -q '^SUPABASE_URL=https://sb.new.jnow.io$' "$d/stack.env"
  assert_eq "url updated" "$?" "0"
  grep -q '^SUPABASE_ANON_KEY=anon-key$' "$d/stack.env"
  assert_eq "anon key written" "$?" "0"
  grep -q '^FRONTEND_IMAGE=x$' "$d/stack.env"
  assert_eq "unrelated keys untouched" "$?" "0"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-supabase-env.sh`
Expected: new tests FAIL (`supabase_render_kong: command not found`).

- [ ] **Step 3: Add the helpers to `scripts/lib/supabase-env.sh`**

Append:

```bash
# Render kong.yml from template, substituting the generated API keys.
supabase_render_kong() { # TEMPLATE OUT ANON_KEY SERVICE_KEY
  sed -e "s|__ANON_KEY__|$3|" -e "s|__SERVICE_ROLE_KEY__|$4|" "$1" > "$2"
  chmod 600 "$2"
}

# Write the dashboard-facing Supabase vars into ~/hermes-stack/.env.
# SUPABASE_COOKIE_DOMAIN is deliberately untouched (Fleet/operator-managed).
supabase_write_stack_dashboard_env() { # STACK_ENV URL ANON_KEY
  local f="$1"
  [ -f "$f" ] || return 1
  _supabase_set_env_key "$f" SUPABASE_URL "${2%/}"
  _supabase_set_env_key "$f" SUPABASE_ANON_KEY "$3"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/test-supabase-env.sh`
Expected: all PASS (old + new).

- [ ] **Step 5: Add the `--deploy` mode to `scripts/11-install-supabase.sh`**

Replace the mode block (`MODE="apply"` / `[[ "${1:-}" == "--verify-only" ]] && MODE="verify"`) with:

```bash
MODE="apply"
case "${1:-}" in
  --verify-only) MODE="verify" ;;
  --deploy)      MODE="deploy" ;;
esac
```

Insert this block AFTER the mode/stdin resolution and BEFORE `echo "==> step 1: verify..."` (in deploy mode we produce the creds that the existing steps then consume):

```bash
if [[ "${MODE}" == "deploy" ]]; then
  . "${SCRIPT_DIR}/lib/supabase-stack-env.sh"
  SB_DIR="${SB_DIR:-$HOME/supabase-stack}"
  TEMPLATES="${SCRIPT_DIR}/../templates/supabase"

  # stdin: SUPABASE_PUBLIC_URL (required), GOOGLE_CLIENT_ID/SECRET (optional).
  SUPABASE_PUBLIC_URL="" ; GOOGLE_CLIENT_ID="" ; GOOGLE_CLIENT_SECRET=""
  while IFS='=' read -r k v || [[ -n "${k:-}" ]]; do
    case "${k}" in
      SUPABASE_PUBLIC_URL) SUPABASE_PUBLIC_URL="${v}" ;;
      GOOGLE_CLIENT_ID) GOOGLE_CLIENT_ID="${v}" ;;
      GOOGLE_CLIENT_SECRET) GOOGLE_CLIENT_SECRET="${v}" ;;
    esac
  done
  # Re-runs may omit the URL — carry it forward from the existing .env.
  [[ -z "${SUPABASE_PUBLIC_URL}" ]] && \
    SUPABASE_PUBLIC_URL="$(supabase_stack_env_val "${SB_DIR}/.env" SUPABASE_PUBLIC_URL)"
  supabase_validate_inputs "${SUPABASE_PUBLIC_URL}" "placeholder-key-not-validated-here" || exit 1

  echo "==> deploy 1: stage ${SB_DIR} (compose + env + kong)"
  mkdir -p "${SB_DIR}"
  cp "${TEMPLATES}/docker-compose.yml" "${SB_DIR}/docker-compose.yml"
  ENV_OLD=""
  if [[ -f "${SB_DIR}/.env" ]]; then ENV_OLD="$(mktemp)"; cp "${SB_DIR}/.env" "${ENV_OLD}"; fi
  export SUPABASE_PUBLIC_URL GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET
  render_supabase_stack_env "${SB_DIR}/.env" "${ENV_OLD}"
  [[ -n "${ENV_OLD}" ]] && rm -f "${ENV_OLD}"
  ANON_KEY="$(supabase_stack_env_val "${SB_DIR}/.env" ANON_KEY)"
  SERVICE_ROLE_KEY="$(supabase_stack_env_val "${SB_DIR}/.env" SERVICE_ROLE_KEY)"
  supabase_render_kong "${TEMPLATES}/kong.yml" "${SB_DIR}/kong.yml" \
    "${ANON_KEY}" "${SERVICE_ROLE_KEY}"

  echo "==> deploy 2: docker compose up -d"
  docker compose -f "${SB_DIR}/docker-compose.yml" --env-file "${SB_DIR}/.env" pull --quiet
  docker compose -f "${SB_DIR}/docker-compose.yml" --env-file "${SB_DIR}/.env" up -d

  echo "==> deploy 3: wait for auth healthy via kong"
  set +e
  for i in $(seq 1 30); do
    CODE="$(curl -s -o /dev/null -w '%{http_code}' -m 5 \
      -H "apikey: ${ANON_KEY}" http://127.0.0.1:8000/auth/v1/health)"
    [[ "${CODE}" == "200" ]] && break
    sleep 2
  done
  set -e
  if [[ "${CODE:-}" != "200" ]]; then
    echo "error: auth /health did not come up (last HTTP ${CODE:-none}) — check: docker compose -f ${SB_DIR}/docker-compose.yml logs auth kong" >&2
    exit 1
  fi
  echo "    auth /health → 200 ✓"

  echo "==> deploy 4: apply ollie-core migrations (idempotent)"
  for f in "${SCRIPT_DIR}/../supabase/ollie-core/"[0-9]*.sql; do
    echo "    psql < $(basename "$f")"
    docker compose -f "${SB_DIR}/docker-compose.yml" --env-file "${SB_DIR}/.env" \
      exec -T db psql -U postgres -d postgres -v ON_ERROR_STOP=1 < "$f"
  done

  echo "==> deploy 5: point the dashboard at the local stack"
  STACK_ENV="${STACK_ENV:-$HOME/hermes-stack/.env}"
  if supabase_write_stack_dashboard_env "${STACK_ENV}" "${SUPABASE_PUBLIC_URL}" "${ANON_KEY}"; then
    docker compose -f "$(dirname "${STACK_ENV}")/docker-compose.yml" up -d dashboard
  else
    echo "    note: ${STACK_ENV} missing — run 06-install-stack.sh, then re-run --deploy"
  fi

  # Fall through to the shared verify/apply tail with the local creds.
  SUPABASE_URL="${SUPABASE_PUBLIC_URL}"
  SUPABASE_SERVICE_ROLE_KEY="${SERVICE_ROLE_KEY}"
  MODE="apply"
  echo
  echo "    local stack deployed — keys for Fleet (store via provision flow):"
  echo "    SUPABASE_URL=${SUPABASE_URL}"
  echo "    SUPABASE_ANON_KEY=${ANON_KEY}"
fi
```

Two adjustments to the existing code:
1. The apply-mode stdin loop must not run in deploy mode — guard it with `if [[ "${MODE}" == "apply" && -z "${SUPABASE_URL:-}" ]]` style: change the outer `if [[ "${MODE}" == "apply" ]]; then` (stdin read) to only execute when `SUPABASE_URL` is still unset (deploy already consumed stdin and set the creds). Concretely, initialize `SUPABASE_URL=""; SUPABASE_SERVICE_ROLE_KEY=""` at the top of the file, move the deploy block above the apply stdin-read, and wrap the stdin-read as `if [[ "${MODE}" == "apply" && -z "${SUPABASE_URL}" ]]`.
2. **Schema-probe caveat:** the existing probe hits `/rest/v1/user_roles` through Kong with the service key in both `apikey` and `Authorization` headers — this works unchanged against the local Kong (key-auth reads `apikey`, PostgREST reads the Bearer). No probe changes needed.
3. Update the header comment block (lines 1–26) to document all three modes.

- [ ] **Step 6: Shellcheck + full local suites**

Run: `shellcheck scripts/11-install-supabase.sh scripts/lib/supabase-env.sh scripts/lib/supabase-stack-env.sh` (fix findings), then `bash tests/test-supabase-env.sh && bash tests/test-supabase-stack-env.sh && bash tests/test-supabase-compose.sh && python3 -m pytest tests/ -v`
Expected: all green, no regressions in the existing pytest suite.

- [ ] **Step 7: Commit**

```bash
git add scripts/11-install-supabase.sh scripts/lib/supabase-env.sh
git commit -m "feat(supabase): --deploy mode — local stack up, migrations, orchestrator+dashboard wiring"
```

---

### Task 5: Runbook + docs

**Files:**
- Create: `docs/runbooks/self-hosted-supabase.md`
- Modify: `docs/runbooks/supabase-ollie-core-provisioning.md` (add a pointer: self-hosted `--deploy` is now the default path; this runbook remains for hosted/manual projects)
- Modify: `README.md` (script list: document 11's three modes)

**Interfaces:**
- Consumes: everything above.
- Produces: the operator procedure Plans 2–3 reference.

- [ ] **Step 1: Write `docs/runbooks/self-hosted-supabase.md`**

Content must cover, concretely (full commands, no placeholders except operator-specific values marked `<like-this>`):

1. **Prereqs:** box provisioned through 06 (hermes-stack up); DNS + cloudflared.
2. **Cloudflared ingress:** add public hostname `sb.<instance-host>` → `http://localhost:8000` in the Zero Trust dashboard (same tunnel that serves the dashboard at `<instance-host>`), with the exact click-path and a `curl -s -o /dev/null -w '%{http_code}' https://sb.<instance-host>/auth/v1/health -H 'apikey: <anon>'` → `200` check.
3. **Google OAuth:** in the Google Cloud console OAuth client (existing per-instance client), add authorized redirect URI `https://sb.<instance-host>/auth/v1/callback`.
4. **Deploy:**
   ```bash
   printf 'SUPABASE_PUBLIC_URL=https://sb.<instance-host>\nGOOGLE_CLIENT_ID=<id>\nGOOGLE_CLIENT_SECRET=<secret>\n' \
     | bash ollie-hermes-install/scripts/11-install-supabase.sh --deploy
   ```
5. **Acceptance checklist** (copied from the spec, as commands):
   - `curl https://sb.<host>/auth/v1/.well-known/jwks.json` → contains an ES256 EC key
   - browser Google login round-trip on the dashboard; `whoami` shows the seeded role (run `scripts/lib/seed-operator-role.py` per the done-done flow first)
   - decode a session JWT (jwt.io or `python3 -c` snippet provided inline) → hook claims (tags/user_role) present
   - storage round-trip: `curl -X POST .../storage/v1/bucket` with service key, upload + fetch one object (exact curl pair provided)
   - foreign-user 403: session-list with a second account still fail-closed
   - exposure probe: `bash scripts/../check-box-config.sh` equivalent + external `nmap`-style check that only :22 answers
6. **Re-run/upgrade:** re-running `--deploy` is safe (secrets preserved, pins restamped); image bumps happen in `supabase-stack-env.sh`, sandbox-first, with rollback = revert the pin lines + re-run.
7. **Backups:** enable Hetzner server backups on the box (covers db + storage volumes); note that restore = restore whole-server snapshot.

- [ ] **Step 2: Update the provisioning runbook + README**

Add to the top of `supabase-ollie-core-provisioning.md`:

```markdown
> **Default path changed (2026-07-11):** new boxes self-host Supabase —
> see `self-hosted-supabase.md` (`11-install-supabase.sh --deploy`), which
> applies `supabase/ollie-core/` automatically. This runbook remains the
> manual procedure for hosted Supabase projects (legacy/grandfathered boxes).
```

README: extend the `11-install-supabase.sh` line to name the three modes (`--deploy` self-hosted default / stdin-apply hosted / `--verify-only` gate).

- [ ] **Step 3: Commit**

```bash
git add docs/runbooks/self-hosted-supabase.md docs/runbooks/supabase-ollie-core-provisioning.md README.md
git commit -m "docs(supabase): self-hosted runbook (cloudflared ingress, deploy, acceptance, upgrades)"
```

---

### Task 6: Live verification on the sandbox box (gate for Plans 2–3)

No code — this is the plan's end-to-end proof, run against `ollie@178.105.216.167` (SSH via 1Password key, `ssh -F NUL` from Windows). It deploys the LOCAL stack alongside the still-active hosted project; nothing is migrated yet (Plan 3 does cutover), so this is non-destructive.

- [ ] **Step 1:** Create the `sb.olliesandbox.jnow.io` cloudflared hostname + Google redirect URI per the runbook.
- [ ] **Step 2:** rsync/pull the repo on the box; run the runbook deploy command with the sandbox Google client creds.
- [ ] **Step 3:** Run the full acceptance checklist from the runbook. Record RAM before/after (`free -m`) — the spec needs the real footprint to size prod.
- [ ] **Step 4:** Confirm re-run idempotency: run `--deploy` a second time with empty stdin; verify keys unchanged (`diff` the `.env` against a pre-run copy) and all services still healthy.
- [ ] **Step 5:** Roll back the dashboard pointer for now (restore hosted `SUPABASE_URL`/`SUPABASE_ANON_KEY` in `~/hermes-stack/.env` from the pre-run copy + `docker compose up -d dashboard`) — cutover belongs to Plan 3. Leave the local stack running for soak.
- [ ] **Step 6:** Write results (RAM, gotchas, any env-var corrections against current supabase images) into the runbook; commit.

```bash
git add docs/runbooks/self-hosted-supabase.md
git commit -m "docs(supabase): sandbox verification results (RAM footprint, gotchas)"
```

---

## Self-Review Notes

- **Spec coverage:** trimmed stack ✓ (T3), keys/ES256/JWKS ✓ (T1), hook + Google via env ✓ (T3), idempotent deploy + preserve ✓ (T2/T4), provision integration ✓ (T4 emits creds; Fleet side deferred to Plan 2 per scope note), runbook + acceptance ✓ (T5), sandbox-first ✓ (T6). Apps VPS + migrations are Plan 3 (spec's migration section) — intentionally out of scope here.
- **Known verify-on-box risks (called out, not placeholders):** exact env-var names on current `storage-api`/`gotrue` images may have drifted from the pins listed — T3 Step 6 and T6 exist to catch this; the compose header says to re-diff against `supabase/docker` when bumping.
