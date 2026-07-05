# Idempotency Phase 8 — Provider-Firewall Codification + Exposure Check — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use `- [ ]`.

**Goal:** Make "is this box firewalled?" a runnable, un-tribal check instead of an assumption. The Hermes gateway binds `0.0.0.0` and RELIES on the box's cloud/edge firewall (accepted posture, S70) — so if the firewall is missing or detached, internal ports are silently exposed. Provide an exposure-check script + codify the cloud-firewall requirement as a post-provision gate.

**Decision context (D4, John, 2026-07-05):** downscoped — NO gateway rebind, and NO host `ufw` in the default install. Rely on the provider/cloud firewall as the primary control (more durable than host ufw — survives OS rebuild), made non-tribal by a committed checklist + a runnable exposure check. Host `ufw` stays only a documented fallback for a no-cloud-firewall box.

## Global Constraints

- **Commits LOCAL + UNPUSHED** on `ollie-fleet` master (base = the Phase-7 tip `de46cc5`). Do not push.
- **No behavior change to provisioning/binding** — this phase is a check script + docs only. Do NOT add host `ufw` to the default install, do NOT rebind the gateway.
- The exposure check runs from an EXTERNAL vantage (a Linux admin/Fleet box), probing the target box's public IP. Portable TCP-connect (prefer `nc -z`, fall back to bash `/dev/tcp`).
- Internal ports that must NOT be publicly reachable: **8642** (default Hermes gateway), **9119** (native Hermes dashboard), **9120** (cortex), **9123** (orchestrator), **3000** (dashboard container). Per-profile ports (gateway 8643+, dashboard 9121+) vary — accept an optional extra-ports arg.

## File Structure

- **Create `scripts/check-box-exposure.sh`** — probes a box IP; reports OK (only SSH reachable) or EXPOSED (internal ports reachable → firewall missing), exit 1 on exposure.
- **Modify `deploy/DEPLOY.md`** — reframe the firewall section to cloud-firewall-first; add the exposure check as a post-provision gate; document the internal-ports rationale + the S70 accepted-posture note; keep host `ufw` only as a documented fallback.

---

### Task 1: Exposure-check script + cloud-firewall-first DEPLOY.md gate (#19 Phase 8)

**Files:**
- Create: `scripts/check-box-exposure.sh`
- Modify: `deploy/DEPLOY.md`

- [ ] **Step 1: Write the exposure-check script**

Create `scripts/check-box-exposure.sh`:
```bash
#!/usr/bin/env bash
# Exposure health-check: verify a box exposes ONLY SSH publicly, and that the
# internal Ollie/Hermes ports are blocked by its cloud/edge firewall. The gateway
# binds 0.0.0.0 and relies on that firewall (accepted posture — see the S70 note in
# DEPLOY.md). This turns "did someone attach the firewall?" into a runnable check.
# Run from an EXTERNAL vantage (NOT on the box). Usage: check-box-exposure.sh <box-ip> [extra-ports...]
set -uo pipefail
IP="${1:-}"
if [ -z "$IP" ]; then echo "usage: $0 <box-ip> [extra-ports...]" >&2; exit 2; fi
shift || true
TIMEOUT="${EXPOSURE_TIMEOUT:-3}"
INTERNAL_PORTS=(8642 9119 9120 9123 3000 "$@")

port_open() {  # ip port -> 0 if reachable, non-zero if closed/filtered
  local ip="$1" port="$2"
  if command -v nc >/dev/null 2>&1; then
    nc -z -w "$TIMEOUT" "$ip" "$port" >/dev/null 2>&1
  else
    timeout "$TIMEOUT" bash -c "exec 3<>/dev/tcp/$ip/$port" >/dev/null 2>&1
  fi
}

if ! port_open "$IP" 22; then
  echo "WARN: :22 (SSH) not reachable on $IP — wrong IP, box down, or an unusually strict firewall?" >&2
fi

exposed=()
for p in "${INTERNAL_PORTS[@]}"; do
  if port_open "$IP" "$p"; then exposed+=("$p"); fi
done

if [ "${#exposed[@]}" -eq 0 ]; then
  echo "OK: no internal ports publicly reachable on $IP (SSH only). Firewall looks correct."
  exit 0
fi
echo "EXPOSED: internal ports reachable on $IP: ${exposed[*]}" >&2
echo "  These MUST be blocked by the box's cloud/edge firewall (the gateway binds 0.0.0.0)." >&2
echo "  Attach/fix the provider firewall (inbound = SSH/22 + ICMP only) before trusting this box." >&2
exit 1
```

- [ ] **Step 2: Syntax + smoke check**

Run: `bash -n scripts/check-box-exposure.sh` → clean.
Run (smoke — localhost should have no internal Ollie ports listening publicly): `bash scripts/check-box-exposure.sh 127.0.0.1` → expect `OK:` (exit 0) on a machine not running the stack; if any of those ports happen to be open locally it will print `EXPOSED:` — that's the check working, not a bug. Also verify usage: `bash scripts/check-box-exposure.sh` (no arg) → prints usage, exit 2. (`shellcheck` if available — advisory.)

- [ ] **Step 3: Reframe DEPLOY.md firewall guidance + add the gate**

In `deploy/DEPLOY.md`, update the firewall section (the "§9 Firewall — ufw" block) so it is **cloud-firewall-first**:
- **Primary:** each box (including the Fleet box) MUST sit behind a provider/cloud firewall with inbound restricted to **SSH/22 + ICMP** only (e.g. a Hetzner Cloud Firewall). This is the durable control (survives OS rebuild); it is why `ufw inactive` on these boxes is expected, not a finding (S70).
- **Why it matters:** the Hermes gateway binds `0.0.0.0`; the internal ports (8642/9119/9120/9123/3000) are reachable on the raw box IP unless the firewall blocks them. The gateway still requires `HERMES_GATEWAY_KEY`, but exposure should be blocked at the firewall regardless.
- **Post-provision gate (verify, don't assume):** after provisioning a box, run `bash scripts/check-box-exposure.sh <box-public-ip>` from an external host; it must report `OK` (SSH only). If it reports `EXPOSED`, attach/fix the cloud firewall before the box is trusted. Re-run after any firewall change.
- **Fallback only:** host `ufw` is a fallback ONLY for a box on a provider with no attachable firewall (keep the existing ufw commands under a clearly-labeled "Fallback" subheading; note the SSH-lockout risk).
Keep any existing commands; restructure the prose to the above.

- [ ] **Step 4: Commit**

```bash
git add scripts/check-box-exposure.sh deploy/DEPLOY.md
git commit -m "feat(fleet): box exposure-check + cloud-firewall-first DEPLOY gate (#19 Phase 8)

The gateway binds 0.0.0.0 and relies on the box's cloud firewall (accepted posture,
S70). Adds scripts/check-box-exposure.sh — a runnable check that the box exposes only
SSH publicly (internal ports 8642/9119/9120/9123/3000 must be firewall-blocked) — and
reframes DEPLOY.md to cloud-firewall-first with a post-provision verify gate. No
gateway rebind, no default host ufw (per the downscoped D4 decision).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Out of Scope (per D4)
- **Gateway rebind to loopback** — dropped (breaks the dashboard→gateway path; the firewall already covers exposure; re-opens the S70 call).
- **Host `ufw` in the default install** — not added (cloud-firewall-first; ufw is a documented fallback only).
- **Automating cloud-firewall attachment via the provider API at provision** — the higher-lift option; deferred. The checklist + exposure gate is the minimum durable win (turns a tribal assumption into a verified step).

## Self-Review
- **Coverage:** "codify the provider firewall" → DEPLOY.md cloud-firewall-first section; "exposure health-check" → `check-box-exposure.sh` (runnable, un-tribal). ✓
- **Placeholders:** exact script + a concrete DEPLOY gate. Testing is a syntax + smoke check (a network-probe script can't be meaningfully unit-tested offline — noted honestly). ✓
- **Risk:** docs + a read-only external probe script; zero change to provisioning/binding behavior. ✓
