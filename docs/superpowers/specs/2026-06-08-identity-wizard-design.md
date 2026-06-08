# First-Run Identity Wizard — Design

**Date:** 2026-06-08
**Status:** Approved (frontend-wizard direction + key choices decided 2026-06-08)
**Supersedes:** the agent-conducted onboarding approach in
`2026-06-07-soul-onboarding-design.md` and `2026-06-08-onboarding-injection-patch-design.md`.
Those are abandoned (see Background); this is the chosen mechanism.

## Background — why a wizard, not an agent interview

The first-run identity onboarding was attempted as an **agent-conducted interview**: a
directive injected into the default agent's prompt that makes it ask the operator five
questions (name, personality, mission, communication style, hard rules) and then save the
result via `ollie-set-identity`. Across eight variations (SOUL.md v1–v6, plus once-only and
every-message injection through the api_server `ephemeral_system_prompt` hook) this proved
fundamentally unreliable:

- **Inject the directive every turn** → the model re-anchors and **restarts** the interview
  (re-asks the name, reverts the chosen name).
- **Inject once** → the model **forgets the save step** by the fifth answer and never runs
  `ollie-set-identity`.

An LLM conducting a stateful multi-turn interview via a re-injected system prompt cannot
reliably do both. The state must live in code, not the prompt. A deterministic **frontend
wizard** removes the LLM from the control flow entirely: a first-run setup screen collects
the five answers as form fields and saves them. The LLM is used only for an optional,
one-shot persona-prose polish, with a deterministic fallback.

## Overview

On first launch, after the existing provider-key `SetupWizard`, a new **`IdentityWizard`**
(full-screen modal, mirroring `SetupWizard`) collects the operator's choices for the default
agent's name, personality, mission, communication style, and hard rules. It composes a SOUL
persona (one-shot gateway call to polish the prose, deterministic template on any failure)
and POSTs it to a new orchestrator endpoint that atomically writes the agent's `SOUL.md` and
updates its dashboard `displayName`. The wizard then closes and the dashboard reflects the
new name immediately.

## Components

### 1. Orchestrator — persistence endpoint + detection flag

Repo: `ollie-hermes-orchestrator` (FastAPI; `src/api/agents.py`, `src/models.py`,
`src/lifecycle.py`, `src/agents_json.py`). Auth: existing `Depends(require_bearer)` on the
`/v1/agents` router.

**a. `POST /v1/agents/{id}/identity`** — request `{ displayName: str, soulContent: str }`:
1. Resolve the agent's SOUL path: default (`id == "default"`) → `{HERMES_HOME}/SOUL.md`;
   otherwise → `{HERMES_PROFILES_DIR}/{id}/SOUL.md`. (Config already exposes these dirs.)
2. Atomically write `soulContent` to that path (temp file + `os.replace`), `0644`. The
   content is a real persona, so it carries no `OLLIE-SOUL-DEFAULT` marker.
3. Update the agent's `displayName` in `AGENTS_JSON` via the existing `write_agent` /
   `update_agent` path (same as `PATCH /v1/agents/{id}`).
4. Audit-log (existing `audit(...)` pattern) and return the updated `Agent` (so the client
   gets the new `displayName`).
5. 404 if the agent id is unknown; 400 on write failure. `soulContent` must be non-empty.

**b. `needsIdentity` on the `Agent` response.** Add a boolean to the `Agent` model, set in
`_entry_to_agent` (or where the response is built) by reading the agent's `SOUL.md`:
`needsIdentity = (SOUL is missing) or ("OLLIE-SOUL-DEFAULT" in SOUL)`. This is the
first-run signal the frontend reads. Reading is best-effort: on any error, default to
`False` (don't nag if we can't tell).

**Request/response models** live in `src/models.py` (pydantic): add `SetIdentityRequest`
and the `needsIdentity` field on `Agent`.

### 2. Frontend — the wizard

Repo: `ollie-hermes-frontend` (React 19 + react-router 7 + Tailwind). Mirrors the existing
`src/components/setup/SetupWizard.tsx` modal pattern and reuses `Modal`/`Field` from
`src/components/agents/shared.tsx`.

**a. Detection — `useIdentityCheck` hook.** After provider setup is resolved
(`useSetupCheck().needsSetup === false`), call `orchestrator.listAgents()`; the default
agent is the one with `id === "default"` (fallback: first agent). `needsIdentity = that
agent's needsIdentity`. Returns `{ needsIdentity, defaultAgent, loading, refresh }`.

**b. `OrchestratorClient.setIdentity(id, { displayName, soulContent })`** — `POST
/v1/agents/{id}/identity` (mirror the existing `updateAgent` method;
`src/adapters/orchestrator/OrchestratorClient.ts`). Add `needsIdentity?: boolean` to the
`Agent` type in `OrchestratorTypes.ts`.

**c. `IdentityWizard` component** (`src/components/setup/IdentityWizard.tsx`),
`onComplete: () => void`. Steps: `intro → name → personality → mission → communication →
rules → review`. Each step is one field with the example/help text from the existing
interview wording. The `name` step pre-fills "Ollie" and notes it can be changed. A
**Skip** affordance writes a sensible default persona (named "Ollie" or whatever was
entered) so the wizard never nags again.

On the review step's **Save**:
1. Compose the persona. Try a one-shot polish via the gateway (the dashboard already has a
   gateway client): ask it to turn the five fields into second-person persona prose.
   On **any** error/timeout (short, e.g. 20s) fall back to the deterministic template:
   ```
   You are {name}.

   **Personality:** {personality}

   **Mission:** {mission}

   **Communication style:** {communication}

   **Hard rules:** {rules}
   ```
   (Both forms begin "You are {name}" and contain no `OLLIE-SOUL-DEFAULT` marker.)
2. `await orchestrator.setIdentity("default", { displayName: name, soulContent })`.
3. Call `onComplete()`; the parent refreshes `listAgents()` so the new name shows.

**d. Mount** at the `App.tsx` root, chained after the provider wizard:
```tsx
{!setupLoading && needsSetup && !providerDone && <SetupWizard onComplete={...} />}
{!setupLoading && (!needsSetup || providerDone) && !idLoading && needsIdentity && !idDone &&
  <IdentityWizard onComplete={() => { setIdDone(true); refresh(); }} />}
```

**e. Upper-left name → orchestrator.** `Layout.tsx` currently reads the name from
`localStorage('ollie-agent-name')`. Wire it to the default agent's `displayName` from
`orchestrator.listAgents()` (falling back to localStorage/"Ollie" when the orchestrator is
unavailable), so the name updates automatically after the wizard. This also closes the
prior auto-rename requirement. The agent chip already reads `displayName`.

### 3. Install repo — cleanup

Repo: `ollie-hermes-install`.
- **Remove** `scripts/10-patch-onboarding.sh` and `templates/onboarding/profile-build-directive.md`
  (the abandoned agent-interview injection). Remove its README step.
- **Revert on the box**: restore `agent/onboarding.py` and `gateway/platforms/api_server.py`
  from their `.bak.onboard` backups (undo the overrides); remove
  `~/.hermes/ollie-onboarding-directive.txt`.
- **Keep** `templates/souls/default.md` (the minimal `OLLIE-SOUL-DEFAULT` stub — it is the
  `needsIdentity` signal) and the `08` changes that install it.
- **Keep** `ollie-set-identity` (script `09`, the CLI) as a manual/secondary tool; it is
  independent of the wizard path.

## Data flow (fresh install, happy path)

1. Install scripts run; `08` seeds the default `OLLIE-SOUL-DEFAULT` stub; orchestrator
   reports the default agent with `needsIdentity: true`.
2. Operator opens the dashboard. Provider `SetupWizard` runs if no key is configured, then
   `IdentityWizard` appears.
3. Operator answers five fields, clicks Save. Frontend composes the persona (gateway polish
   or template), POSTs to `/v1/agents/default/identity`.
4. Orchestrator writes `~/.hermes/SOUL.md` (real persona, marker gone) and sets
   `displayName`. `needsIdentity` is now false.
5. Wizard closes; the upper-left name and agent chip show the chosen name. The next chat
   uses the new persona (Hermes injects the new `SOUL.md`). The wizard never reappears.

## Testing

- **Orchestrator (pytest, mirrors `tests/test_api_agents.py`):** `POST .../identity` writes
  the SOUL file and updates `displayName`; `GET /v1/agents` reflects it; `needsIdentity`
  flips from true (marker stub) to false (real persona); 404 on unknown id; empty
  `soulContent` → 400.
- **Frontend:** component/unit test that the template fallback produces valid `soulContent`
  and that Save calls `setIdentity` with the right body; manual on-box test that the wizard
  appears when `needsIdentity` is true, saves, and the name updates.
- **On-box end-to-end:** reset the default `SOUL.md` to the stub, open the dashboard, run
  the wizard, confirm `SOUL.md` is personalized, the dashboard name updates, and the wizard
  does not reappear on reload. Confirm a preset agent (paige) is unaffected.

## Out of scope (YAGNI)

- Editing identity after first run (already covered by the existing Edit-Agent modal +
  `ollie-set-identity`).
- Per-field validation beyond non-empty name.
- Re-onboarding flow / "reset identity" button.

## Files

**orchestrator:** `src/models.py` (+`SetIdentityRequest`, +`Agent.needsIdentity`),
`src/api/agents.py` (+endpoint, +`needsIdentity` in response build), `src/lifecycle.py` or
a new `src/identity.py` (write-SOUL + rename), `tests/test_api_agents.py` (+tests).

**frontend:** `src/adapters/orchestrator/OrchestratorClient.ts` (+`setIdentity`),
`src/adapters/orchestrator/OrchestratorTypes.ts` (+`needsIdentity`),
`src/hooks/useIdentityCheck.ts` (new), `src/components/setup/IdentityWizard.tsx` (new),
`src/components/setup/persona.ts` (new — compose/template helper), `src/App.tsx` (mount),
`src/components/Layout.tsx` (name from orchestrator).

**install:** delete `scripts/10-patch-onboarding.sh`,
`templates/onboarding/profile-build-directive.md`; edit `README.md`; on-box revert.
