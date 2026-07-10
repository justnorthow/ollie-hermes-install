#!/usr/bin/env python3
"""seed-operator-role.py — resolve-or-create the operator's Supabase auth user
by email and upsert their platform_operator row for this instance.

Fleet's user ids are Fleet-local, so identity is keyed on EMAIL. Creating the
auth user with email_confirm=true lets a later Google sign-in auto-link (the
proven sandbox pattern). Idempotent: merge-duplicates upsert.

Usage: seed-operator-role.py --email <email> --instance-id <id> [--print-uid]
Env:   ORCH_ENV (default ~/.config/ollie-orchestrator/.env)
"""
import argparse, json, os, sys, urllib.error, urllib.request

ORCH_ENV = os.environ.get("ORCH_ENV", os.path.expanduser("~/.config/ollie-orchestrator/.env"))


def load_supabase_env(path):
    url = key = ""
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                if line.startswith("SUPABASE_URL="):
                    url = line.split("=", 1)[1].strip().rstrip("/")
                elif line.startswith("SUPABASE_SERVICE_ROLE_KEY="):
                    key = line.split("=", 1)[1].strip()
    except FileNotFoundError:
        pass
    if not url or not key:
        sys.exit("error: SUPABASE_URL/SUPABASE_SERVICE_ROLE_KEY missing from %s — run 11-install-supabase.sh first" % path)
    return url, key


def find_user(users, email):
    want = email.strip().lower()
    for u in users:
        if (u.get("email") or "").strip().lower() == want:
            return u["id"]
    return None


def build_role_payload(instance_id, user_id):
    return [{"instance_id": instance_id, "user_id": user_id, "tier": "platform_operator"}]


def extract_users(data):
    """Extract users list from data dict or pass through if already a list.

    Handles three cases:
    - dict with "users" key: return users if it's a list, else []
    - list: return as-is
    - other: return []
    """
    if isinstance(data, dict):
        users = data.get("users", [])
        return users if isinstance(users, list) else []
    return data if isinstance(data, list) else []


def _req(url, key, method="GET", body=None, extra_headers=None):
    headers = {"apikey": key, "Authorization": "Bearer " + key, "Content-Type": "application/json"}
    headers.update(extra_headers or {})
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    with urllib.request.urlopen(req, timeout=15) as resp:
        raw = resp.read().decode() or "null"
        return resp.status, json.loads(raw)


def resolve_or_create_uid(base, key, email):
    for page in range(1, 11):
        _, data = _req(f"{base}/auth/v1/admin/users?page={page}&per_page=200", key)
        users = extract_users(data)
        uid = find_user(users, email)
        if uid:
            return uid
        if not users:
            break
    _, created = _req(f"{base}/auth/v1/admin/users", key, method="POST",
                      body={"email": email, "email_confirm": True})
    return created["id"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--email", required=True)
    ap.add_argument("--instance-id", required=True)
    ap.add_argument("--print-uid", action="store_true")
    args = ap.parse_args()

    base, key = load_supabase_env(ORCH_ENV)
    try:
        uid = resolve_or_create_uid(base, key, args.email)
        if args.print_uid:
            print(uid)
            return
        _req(f"{base}/rest/v1/user_roles", key, method="POST",
             body=build_role_payload(args.instance_id, uid),
             extra_headers={"Prefer": "resolution=merge-duplicates"})
    except urllib.error.HTTPError as e:
        sys.exit(f"error: Supabase API {e.code} on {e.url}: {e.read().decode()[:400]}")
    print(f"seeded platform_operator for {args.email} (uid {uid}) @ instance {args.instance_id}")


if __name__ == "__main__":
    main()
