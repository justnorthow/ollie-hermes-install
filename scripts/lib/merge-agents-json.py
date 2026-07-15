#!/usr/bin/env python3
# Merge detected agents with the EXISTING AGENTS_JSON so operator/wizard-set fields
# survive a re-run of 06. Reads EXISTING_AGENTS + DETECTED (both JSON) from the env,
# prints the merged AGENTS_JSON (compact) to stdout. Ports/URLs are always refreshed
# from DETECTED; an agent whose profile is gone (not in DETECTED) is dropped.
import json, os

try:
    prev = {a["id"]: a for a in json.loads(os.environ.get("EXISTING_AGENTS") or "[]")}
except Exception:
    prev = {}

out = []
for d in json.loads(os.environ["DETECTED"]):
    p = prev.get(d["id"], {})
    entry = {
        "id": d["id"],
        # Preserve a wizard-set displayName; else default (capitalized id; "Ollie" for default).
        "name": p.get("name") or ("Ollie" if d["id"] == "default" else d["id"].capitalize()),
        "gatewayUrl": f'http://host.docker.internal:{d["gw"]}',
        "dashboardUrl": f'http://host.docker.internal:{d["dash"]}',
    }
    if p.get("color"):
        entry["color"] = p["color"]
    if p.get("model"):
        entry["model"] = p["model"]
    # RBAC fields — preserve so a re-run of 06 never drops the scope:"user" tag on
    # Ollie (which fail-closes members out of their own assistant) or a company
    # agent's manager_visible flag.
    if p.get("scope"):
        entry["scope"] = p["scope"]
    if p.get("manager_visible"):
        entry["manager_visible"] = p["manager_visible"]
    # Display-only agent subtitle (set via orchestrator/UI) — preserve so a
    # re-run of 06 never wipes it (same class as the scope-drop bug).
    if p.get("subtitle"):
        entry["subtitle"] = p["subtitle"]
    out.append(entry)

print(json.dumps(out, separators=(",", ":")))
