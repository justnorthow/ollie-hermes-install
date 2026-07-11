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
