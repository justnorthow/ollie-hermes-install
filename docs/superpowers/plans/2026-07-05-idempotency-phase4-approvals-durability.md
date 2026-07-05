# Idempotency Phase 4 — `approvals.mode` Durability — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use `- [ ]`.

**Goal:** Make the prospecting agent's `approvals.mode: "off"` durable — set by its installer so a reprovision restores it, instead of a manual box edit that, when missing, makes the agent "narrate but never act" (every `execute_code` call hangs 300s on an un-renderable approval prompt).

**Architecture:** Add an idempotent step to `ollie-prospecting-agent/install.sh` that sets `approvals.mode off` for the agent's Hermes profile, robust across the two attested invocation forms and VISIBLE (not silently swallowed) on failure.

**Tech Stack:** Bash. The agent installer is manually smoke-tested (no full harness); verification here is `bash -n` + a focused stub test of the new block.

## Global Constraints

- **Commit LOCAL + UNPUSHED** in `ollie-prospecting-agent` on its **current branch `fix/plugin-loading`** (HEAD `7d0ab10` — where the live install.sh is; `master` is behind). Do NOT push. (Cross-repo note: this is a 6th repo, on a feature branch, unlike the local-on-master others — flagged for John's deploy.)
- The `config set` must be **idempotent** (it is — setting the same value twice is a no-op) and **non-fatal but LOGGED**: on failure it must print a clear WARNING (never silently `|| true`), because a silent failure reintroduces the exact 300s-hang regression this fixes.
- Must be **`set -euo pipefail`-safe**: put the attempts in `if/elif/else` conditions so a failing `config set` doesn't abort the installer.
- Do not change any other install.sh step.

## File Structure

- **Modify `ollie-prospecting-agent/install.sh`** — add "Step 4b" after Step 4 (SOUL.md, the `fi` at ~line 90) and before Step 5 (Brain comment).
- **Create `ollie-prospecting-agent/tests/test-approvals.sh`** — a focused bash test with a fake `hermes` on PATH asserting the block issues the right command and is non-fatal on failure.

---

### Task 1: Installer sets `approvals.mode off` idempotently (#6) — repo: `ollie-prospecting-agent` (branch `fix/plugin-loading`)

**Files:**
- Modify: `install.sh` (insert Step 4b after the Step-4 SOUL `fi`, ~line 90)
- Create: `tests/test-approvals.sh`

- [ ] **Step 1: Write the failing/again focused test**

Create `tests/test-approvals.sh`. It should: make a temp dir, drop a fake `hermes` executable there that appends its args to `$LOG` and exits 0, `PATH="$tmp:$PATH"`, then run the approvals block (source an extracted helper — see Step 3 — or copy the block) with `AGENT_NAME=prospecting-expert`, and assert `$LOG` contains `-p prospecting-expert config set approvals.mode off`. Add a second case: a fake `hermes` that exits 1 AND a fake profile-shim `prospecting-expert` that also exits 1 → assert the block prints a `WARNING` and returns success (non-fatal). Use the Phase-1 `assert`-style (or plain `[ ] || { echo FAIL; exit 1; }`).
```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/approvals.sh"   # extracted helper (Step 3)
tmp="$(mktemp -d)"; log="$tmp/calls.log"
# fake hermes that records args
cat > "$tmp/hermes" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$log"
EOF
chmod +x "$tmp/hermes"
PATH="$tmp:$PATH" AGENT_NAME=prospecting-expert
( PATH="$tmp:$PATH"; set_approvals_off prospecting-expert )
grep -q -- '-p prospecting-expert config set approvals.mode off' "$log" || { echo "FAIL: wrong/no command"; exit 1; }
# failure path: hermes + shim both fail → WARNING, non-fatal
cat > "$tmp/hermes" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$tmp/hermes"
out="$( PATH="$tmp:$PATH"; set_approvals_off prospecting-expert 2>&1 )"; rc=$?
echo "$out" | grep -qi WARNING || { echo "FAIL: no WARNING on failure"; exit 1; }
[ "$rc" -eq 0 ] || { echo "FAIL: not non-fatal (rc=$rc)"; exit 1; }
echo "OK: approvals helper"
rm -rf "$tmp"
```

- [ ] **Step 2: Run — verify it fails**

Run (in `ollie-prospecting-agent`): `bash tests/test-approvals.sh`
Expected: FAIL — `lib/approvals.sh` / `set_approvals_off` doesn't exist yet.

- [ ] **Step 3: Extract the helper + wire it into install.sh**

Create `lib/approvals.sh`:
```bash
#!/usr/bin/env bash
# Idempotent, non-fatal, LOGGED approvals.mode=off setter for a Hermes profile.
# Tries `hermes -p NAME config set` then the per-profile shim `NAME config set`.
set_approvals_off() {
  local agent="$1"
  if hermes -p "$agent" config set approvals.mode off >/dev/null 2>&1; then
    echo "    approvals.mode=off set for '$agent'."
  elif "$agent" config set approvals.mode off >/dev/null 2>&1; then
    echo "    approvals.mode=off set for '$agent' (via profile shim)."
  else
    echo "    WARNING: could not set approvals.mode=off for '$agent'. Set it by hand:"
    echo "      hermes -p $agent config set approvals.mode off"
    echo "      (otherwise execute_code calls hang ~300s on approval prompts)."
  fi
  return 0
}
```
In `install.sh`, after the Step-4 SOUL block's closing `fi` (~line 90) and before the Step-5 comment, add:
```bash
# ── Step 4b: Disable approval prompts for this agent's profile ────────────────
# The skills call execute_code; with the default approvals.mode "manual" every code
# call blocks on an approval prompt the dashboard can't render (agent narrates but
# never acts). Set approvals.mode=off idempotently so a reprovision restores it.
log "Setting approvals.mode=off for '$AGENT_NAME'..."
. "$INSTALL_DIR/lib/approvals.sh"
set_approvals_off "$AGENT_NAME"
```
(`INSTALL_DIR` is defined at install.sh line 13; `AGENT_NAME` at line 9. `log()` already exists.)

- [ ] **Step 4: Run — verify it passes + syntax**

Run: `bash tests/test-approvals.sh` → `OK`.
Run: `bash -n install.sh && bash -n lib/approvals.sh` → no output, exit 0. (If `shellcheck` is available: `shellcheck lib/approvals.sh install.sh` — advisory.)

- [ ] **Step 5: Commit (LOCAL, on `fix/plugin-loading`, do NOT push)**

```bash
git add install.sh lib/approvals.sh tests/test-approvals.sh
git commit -m "fix(install): set approvals.mode=off for the agent profile (idempotent) (#6)

The prospecting agent's execute_code calls hang ~300s on an un-renderable approval
prompt unless its profile has approvals.mode=off — previously a manual box edit.
The installer now sets it idempotently (robust across both config-set forms, warns
loudly but non-fatally on failure), so a reprovision restores it.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

**Live-box verification (rollout, not testable here):** confirm `hermes -p <profile> config set approvals.mode off` (or the shim form) actually takes on the box, and confirm the B-vs-E question — whether `hermes update` preserves the per-profile `config.yaml` (audit E said yes; if not, the setting would need re-applying and this installer step wouldn't cover a plain `update hermes`).

---

## Out of Scope — #9 Apollo-key via Fleet injection (DEFERRED, build-ready)

Deferred: it's a multi-repo feature disproportionate to its value (a convenience secret; re-typing one key on a rare rebuild causes no outage). Grounding captured so it can be built directly later:

- **Real gap:** passing `APOLLO_API_KEY` as an install-time env var only exposes it to the one-shot `install.sh` process, NOT the long-running agent. `install.sh` today never writes it durably. The agent reads `APOLLO_API_KEY` from its environment / `~/.claude/.env.global` (`ollie-prospecting-agent/README.md:49`, `skills/apollo-pull/SKILL.md:4-5,20`). So the injection needs `install.sh` to WRITE the received key into a durable file the agent reads.
- **Fleet side (mirror the Supabase pattern):** new `instance_agent_secrets (instance_id PK, apollo_api_key_enc, updated_at)` table (idempotent add in `db.ts` alongside `instance_supabase`); `src/server/lib/agent-secrets.ts` (`saveApolloApiKey`/`getApolloApiKeyPlaintext`) reusing `encryptSecret`/`decryptSecret` (`crypto.ts`); a `PATCH /:id/apollo-key` route (mirror `PATCH /:id/orchestrator-key` at `instances.ts:293-305`) + a password-style field in `AccessTab.tsx` (write-only convention like the service-role key); in the `add-prospecting-agent` route (`instances.ts:239-291`) decrypt it and pass `apolloApiKey` into `runInstallAgent`; add `apolloApiKey?` to `InstallAgentOpts` and one line to the env array in `install-agent.ts:91-96` (`APOLLO_API_KEY=${shellQuote(apolloApiKey ?? '')}`).
- **prospecting-agent side:** `install.sh` writes `APOLLO_API_KEY` (when provided in env) into `~/.claude/.env.global` (or a profile `.env`) so it persists to the agent runtime.

## Self-Review
- **Coverage:** #6 → Task 1. #9 → deferred with build-ready grounding. ✓
- **Placeholders:** exact snippet + test; insertion anchored to install.sh's real Step-4 `fi`. ✓
- **Risk:** the exact `config set` form is a live-box item — mitigated by trying both forms + a loud WARNING (never silent). The helper extraction makes the block unit-testable without running the curl-heavy full installer. ✓
