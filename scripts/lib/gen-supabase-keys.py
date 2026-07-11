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
