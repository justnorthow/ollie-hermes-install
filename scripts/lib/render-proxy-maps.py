#!/usr/bin/env python3
"""render-proxy-maps.py — write HERMES_GATEWAY_URLS / HERMES_DASHBOARD_URLS
into the orchestrator .env from the detect-agents JSON on stdin.

An existing value is kept only if it is valid JSON covering every detected
agent id (operators may add extra entries); a stale/partial/invalid value is
regenerated — a partial map is exactly the chat-503 failure mode.
"""
import json, os, sys, tempfile

ORCH_ENV = os.environ.get("ORCH_ENV", os.path.expanduser("~/.config/ollie-orchestrator/.env"))


def read_lines(path):
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as f:
        return f.read().splitlines()


def current_value(lines, key):
    val = None
    for line in lines:
        if line.startswith(key + "="):
            val = line[len(key) + 1:]
    return val


def set_key(lines, key, value):
    out, replaced = [], False
    for line in lines:
        if line.startswith(key + "="):
            if not replaced:
                out.append(f"{key}={value}")
                replaced = True
            # drop duplicate occurrences
        else:
            out.append(line)
    if not replaced:
        out.append(f"{key}={value}")
    return out


def covers(existing, ids):
    try:
        parsed = json.loads(existing)
    except (TypeError, ValueError):
        return False
    return isinstance(parsed, dict) and set(ids) <= set(parsed.keys())


def main():
    agents = json.loads(sys.stdin.read())
    ids = [a["id"] for a in agents]
    maps = {
        "HERMES_GATEWAY_URLS": json.dumps({a["id"]: f"http://127.0.0.1:{a['gw']}" for a in agents}),
        "HERMES_DASHBOARD_URLS": json.dumps({a["id"]: f"http://127.0.0.1:{a['dash']}" for a in agents}),
    }
    lines = read_lines(ORCH_ENV)
    for key, rendered in maps.items():
        label = "gateway-urls" if "GATEWAY" in key else "dashboard-urls"
        if covers(current_value(lines, key), ids):
            lines = set_key(lines, key, current_value(lines, key))
            print(f"{label}: kept")
            continue
        lines = set_key(lines, key, rendered)
        print(f"{label}: written")
    os.makedirs(os.path.dirname(ORCH_ENV), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(ORCH_ENV))
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    os.replace(tmp, ORCH_ENV)


if __name__ == "__main__":
    main()
