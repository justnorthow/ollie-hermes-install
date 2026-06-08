# ollie-set-identity — deterministic identity save + display-name sync

Status: approved (design) — 2026-06-08
Scope: new `templates/bin/ollie-set-identity` + `scripts/09-install-identity-sync.sh` + an edit to `templates/souls/default-onboarding.md` + a README line. No changes to `01–07`.

## Problem

Two issues, one fix.

1. **Onboarding persistence is unreliable.** The first-run flow tells the agent to
   overwrite its own `~/.hermes/SOUL.md` and strip the bootstrap marker. Across
   three prompt iterations it still fails to *stick*: the agent gathers answers,
   even calls `write_file` successfully (verified: the tool resolves
   `/home/ubuntu/.hermes/SOUL.md` and reports `files_modified`), but doesn't
   reliably complete *gather-all-five → write the full persona → remove the
   marker → not re-loop* across turns/sessions. Because the bootstrap directive
   lives in `SOUL.md` (re-injected every message), any failure to self-clear
   re-triggers the interview. Per the debugging discipline, 3+ failed iterations
   means the *approach* (soft, LLM-driven self-edit) is the problem, not the
   wording. (Note: quotes and path were **ruled out** — `write_file` is a
   structured tool that handles quoted content and resolves the absolute path.)

2. **The display name doesn't track renames.** The dashboard's agent chip and the
   upper-left selected-agent name both come from `GET /v1/agents` on the
   orchestrator (live; "Agentic OS" beneath is a static brand subtitle). When the
   agent renames itself in `SOUL.md`, nothing updates the orchestrator, so the
   label stays stale. (Verified: a `displayName`-only `PATCH /v1/agents/{id}`
   rewrites `AGENTS_JSON`, does **not** restart the gateway or bounce the
   dashboard, and reflects live on the next frontend fetch — that's how the manual
   Edit-Agent rename worked.)

The fix for both: replace the agent's fragile self-edit with **one deterministic
command** that atomically saves the persona **and** updates the display name.

## Verified facts (Hermes v0.16.0 install on the box)

- `write_file` resolves absolute paths correctly (`resolved_path:
  /home/ubuntu/.hermes/SOUL.md`) and is quote-safe (content is a structured arg).
- Orchestrator `PATCH /v1/agents/{id}` with `{displayName}` updates `AGENTS_JSON`
  via `write_agent`; displayName is **not** in `_RESTART_REQUIRED`, and update
  does **not** bounce the dashboard → live, no restart. Bearer auth via
  `ORCHESTRATOR_KEY`.
- Frontend `OrchestratorClient.listAgents()` → `GET /v1/agents` drives both the
  agent-list chip and the upper-left selected-agent name.
- Orchestrator listens on `localhost:9123`; `ORCHESTRATOR_KEY` lives in
  `~/.config/ollie-orchestrator/.env`.
- The agent (default profile) runs as the service user with `~/.local/bin` on its
  PATH; it has `write_file`, `read_file`, `patch`, `terminal`, `execute_code`.
- `approvals.mode: manual`, `command_allowlist: []` — an un-allowlisted command
  the agent runs would prompt for approval.

## Goals

- Onboarding persists the persona **deterministically** (the loop cannot recur
  from a failed self-clear).
- Setting/confirming the name **updates both dashboard labels** automatically.
- No upstream Hermes patch; survives `hermes update`.
- The agent's responsibility shrinks to a single reliable call.

## Non-goals

- Forcing label sync on *every* future rename without the agent invoking the
  command (would require a Hermes patch — escalation path only if v1 proves
  insufficient).
- Auto-wiring preset agents (paige/karl) — the command supports `--id` but presets
  are repo-managed.
- Eliminating the LLM from the loop entirely (it still must *call* the command —
  but that's one deterministic step, not a multi-step self-edit).

## Design

### Component 1 — `ollie-set-identity` (host command)

Vendored at `templates/bin/ollie-set-identity`; installed to
`~/.local/bin/ollie-set-identity` with a `/usr/local/bin` symlink.

```
ollie-set-identity --name "<name>" --soul-file <path> [--id <agent_id>]
```

- `--name` (required): display name (single value — no quoting trap).
- `--soul-file` (required): path to a file holding the finalized persona prose.
- `--id` (optional, default `default`): which agent.

Behavior (deterministic, ordered):
1. Validate args; `--soul-file` exists and is non-empty.
2. Resolve SOUL path: `default` → `$HOME/.hermes/SOUL.md`; else
   `$HOME/.hermes/profiles/<id>/SOUL.md`. Error if a non-default profile dir is
   absent.
3. **Atomically install the persona** as the SOUL.md (write to `SOUL.md.tmp`,
   `mv` into place; `chmod 644`). Content is exactly the `--soul-file` bytes — so
   the bootstrap marker is guaranteed absent. This is the critical step; if it
   fails, exit non-zero (the agent should know).
4. **Update display name** (best-effort): read `ORCHESTRATOR_KEY` from
   `~/.config/ollie-orchestrator/.env`; `curl -fsS -X PATCH
   http://localhost:9123/v1/agents/<id> -H "Authorization: Bearer $KEY" -H
   "Content-Type: application/json" -d '{"displayName":"<name>"}'`. On any failure
   (no key, orchestrator down, non-2xx), print a WARNING and continue. Do **not**
   fail the command — the persona is saved; the label is cosmetic and can be set
   later from the dashboard.
5. Print a one-line summary (`✓ identity saved: <id> → "<name>" (SOUL: <path>)`,
   plus the rename result).

Exit codes: `0` on persona-saved (even if rename warned); non-zero only if the
persona write itself failed or args are invalid.

### Component 2 — onboarding directive change (`default-onboarding.md`)

Replace the "draft → write SOUL.md yourself → strip the marker" steps with:

- Gather the five answers (one at a time, with examples — unchanged).
- Write the finalized persona prose to a temp file with `write_file`
  (e.g. `/tmp/ollie-persona.md`).
- Run **once**: `ollie-set-identity --name "<chosen name>" --soul-file
  /tmp/ollie-persona.md`.
- Emphasize: **do NOT hand-edit `SOUL.md`**; running this command is what ends
  setup; until you run it, this prompt repeats.
- Decline path: run `ollie-set-identity --name Ollie --soul-file <temp with a
  sensible default Ollie persona>`.

### Component 3 — `scripts/09-install-identity-sync.sh`

Run as the service user; idempotent. It:
1. Installs `templates/bin/ollie-set-identity` → `~/.local/bin/ollie-set-identity`
   (`chmod 755`) and `sudo ln -sfn … /usr/local/bin/ollie-set-identity`.
2. Allowlists the command so the agent runs it without an approval prompt: ensure
   `ollie-set-identity` is in `command_allowlist` via
   `hermes config` (read-modify-write the list; idempotent — don't duplicate).
3. Prints what it did + a note that the rename half needs the orchestrator (`05`).

README: add as a step after `08` (persona provisioning), before first use.

## Edge cases

- **Orchestrator down / no key** → persona still saved, rename warns, exit 0.
- **Re-run / later rename** → command is idempotent; rewrites SOUL + re-PATCHes.
- **`--id` for a missing profile** → clear error, exit non-zero.
- **Empty `--soul-file`** → error (don't wipe a persona to empty).
- **Marker guarantee** → because the command writes exactly the persona file's
  bytes, the bootstrap marker cannot survive → `08`'s gate sees a real persona and
  leaves it alone; the runtime bootstrap directive is gone → no re-loop.

## Testing

**Automated (on-box, non-LLM):**
1. `ollie-set-identity --name "Testy" --soul-file /tmp/p.md` (p.md = a sample
   persona) → `~/.hermes/SOUL.md` byte-equals p.md; no `OLLIE-SOUL-BOOTSTRAP`
   marker; `GET /v1/agents` (via orchestrator, bearer) shows `displayName: Testy`.
2. Re-run with a different name/persona → both update (idempotent).
3. Orchestrator-unreachable simulation (bad key) → persona still written, warning
   printed, exit 0.
4. Empty `--soul-file` and missing `--id` profile → non-zero, SOUL untouched.
5. After (1), `08-install-souls.sh` leaves the SOUL untouched (real persona).

**Manual (one fresh-chat re-onboard):** agent asks one-at-a-time, writes a temp
file, runs `ollie-set-identity` once → persona persists (no loop) and the
dashboard chip + upper-left name update to the chosen name.

**Process:** do NOT run `08`/reset on the box while the user is mid-test; only
mutate box state between tests and announce when it's clean.

## Files

- New: `templates/bin/ollie-set-identity`
- New: `scripts/09-install-identity-sync.sh`
- Edit: `templates/souls/default-onboarding.md` (steps 4–5 → temp-file + command)
- Edit: `README.md` (add step 11)

## Rollout

- Branch `feat/ollie-set-identity`; subagent-driven implementation; on-box
  validation; merge to master.
- Deploy to the live box: run `09`, then reset the live default `SOUL.md` to the
  v-next bootstrap once (between user tests) so a fresh onboarding exercises the
  new command end-to-end.
