# First-Run Identity Wizard — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. This plan spans THREE repos — each task names its repo explicitly.

**Goal:** Replace the unreliable agent-conducted onboarding with a deterministic first-run identity wizard: the orchestrator persists identity (SOUL + dashboard name) and reports a `needsIdentity` flag; the frontend shows a 5-field wizard after provider setup.

**Architecture:** Orchestrator (FastAPI) gains a write endpoint + detection flag. Frontend (React/Tailwind) gains a wizard mirroring the existing `SetupWizard`, composing the persona (one-shot gateway polish, template fallback) and POSTing it. Install repo drops the abandoned injection patch; the box reverts its overrides.

**Tech Stack:** Python/FastAPI/pydantic (orchestrator), React 19 + react-router 7 + Tailwind + Vite (frontend), Bash (install). Repos: `ollie-hermes-orchestrator`, `ollie-hermes-frontend`, `ollie-hermes-install`.

**Spec:** `ollie-hermes-install/docs/superpowers/specs/2026-06-08-identity-wizard-design.md`

**Branches:** create `feat/identity-wizard` in `ollie-hermes-orchestrator` and `ollie-hermes-frontend`; continue on `feat/ollie-set-identity` in `ollie-hermes-install` (already active).

---

## Phase A — Orchestrator (repo: ollie-hermes-orchestrator)

Reference files: `src/api/main.py`, `src/api/agents.py`, `src/models.py`,
`src/lifecycle.py`, `src/agents_json.py`, `src/config.py`, `src/auth.py`,
`tests/test_api_agents.py`. The `/v1/agents` router already enforces
`Depends(require_bearer)`. `displayName` is stored as `AgentEntry.name` in `AGENTS_JSON`
inside `{HERMES_STACK_DIR}/.env`, updated via `write_agent`. SOUL paths: default →
`{HERMES_HOME}/SOUL.md`; others → `{HERMES_PROFILES_DIR}/{id}/SOUL.md`.

### Task A1: `SetIdentityRequest` model + `needsIdentity` on `Agent`

**Files:** Modify `src/models.py`; Test `tests/test_models.py` (create if absent).

- [ ] **Step 1: Add the request model and response field**

In `src/models.py` add:
```python
class SetIdentityRequest(BaseModel):
    displayName: str
    soulContent: str
```
And add to the existing `Agent` response model:
```python
    needsIdentity: bool = False
```

- [ ] **Step 2: Verify import + schema**

Run (repo root): `python -c "from src.models import SetIdentityRequest, Agent; SetIdentityRequest(displayName='x', soulContent='y'); print(Agent.model_fields['needsIdentity'].default)"`
Expected: prints `False`.

- [ ] **Step 3: Commit**

`git add src/models.py && git commit -m "feat: SetIdentityRequest model + Agent.needsIdentity"`

### Task A2: identity persistence helper (write SOUL + detect marker)

**Files:** Create `src/identity.py`; Test `tests/test_identity.py`.

- [ ] **Step 1: Write the failing test**

`tests/test_identity.py`:
```python
from pathlib import Path
from src.identity import write_soul, soul_needs_identity

def test_write_soul_atomic(tmp_path):
    p = tmp_path / "SOUL.md"
    write_soul(p, "You are Billie.")
    assert p.read_text() == "You are Billie."

def test_needs_identity_marker(tmp_path):
    p = tmp_path / "SOUL.md"
    assert soul_needs_identity(p) is True          # missing
    p.write_text("<!-- OLLIE-SOUL-DEFAULT -->\n# stub")
    assert soul_needs_identity(p) is True           # marker present
    p.write_text("You are Billie.")
    assert soul_needs_identity(p) is False           # real persona
```

- [ ] **Step 2: Run it — expect failure** (`pytest tests/test_identity.py -v` → ImportError).

- [ ] **Step 3: Implement `src/identity.py`**

```python
"""Identity persistence: write an agent's SOUL.md and detect the first-run marker."""
from __future__ import annotations
import os
import tempfile
from pathlib import Path

DEFAULT_MARKER = "OLLIE-SOUL-DEFAULT"


def write_soul(soul_path: Path, content: str) -> None:
    """Atomically write SOUL.md (temp file + os.replace), mode 0644."""
    soul_path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(soul_path.parent), prefix=".soul_", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(content)
        os.chmod(tmp, 0o644)
        os.replace(tmp, soul_path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def soul_needs_identity(soul_path: Path) -> bool:
    """True if the agent still needs first-run identity setup: SOUL is missing or still
    carries the OLLIE-SOUL-DEFAULT marker. Best-effort: unreadable -> False (don't nag)."""
    try:
        if not soul_path.exists():
            return True
        return DEFAULT_MARKER in soul_path.read_text(encoding="utf-8")
    except OSError:
        return False
```

- [ ] **Step 4: Run tests — expect pass** (`pytest tests/test_identity.py -v`).

- [ ] **Step 5: Commit** (`git add src/identity.py tests/test_identity.py && git commit -m "feat: identity persistence helper (atomic SOUL write + marker detection)"`)

### Task A3: SOUL-path resolution from config

**Files:** Modify `src/identity.py`; Test `tests/test_identity.py`.

The implementer must inspect `src/config.py` to find the real attribute names for the
Hermes home and profiles dirs (the Explore map referenced `HERMES_PROFILES_DIR`/
`hermes_profiles_dir` and a default `~/.hermes`). Add:

- [ ] **Step 1: Add a resolver test** (append to `tests/test_identity.py`)

```python
from src.identity import resolve_soul_path

def test_resolve_soul_path(tmp_path):
    home = tmp_path / "hermes"
    profiles = home / "profiles"
    assert resolve_soul_path("default", home, profiles) == home / "SOUL.md"
    assert resolve_soul_path("paige", home, profiles) == profiles / "paige" / "SOUL.md"
```

- [ ] **Step 2: Implement `resolve_soul_path`**

```python
def resolve_soul_path(agent_id: str, hermes_home: Path, profiles_dir: Path) -> Path:
    """default -> {hermes_home}/SOUL.md ; others -> {profiles_dir}/{id}/SOUL.md."""
    if agent_id == "default":
        return Path(hermes_home) / "SOUL.md"
    return Path(profiles_dir) / agent_id / "SOUL.md"
```

- [ ] **Step 3: Run tests — pass.** **Step 4: Commit.**

### Task A4: `POST /v1/agents/{id}/identity` endpoint + `needsIdentity` in responses

**Files:** Modify `src/api/agents.py`; Test `tests/test_api_agents.py`.

The implementer must read `src/api/agents.py` for: the `_entry_to_agent` builder (to set
`needsIdentity` there using `soul_needs_identity` + `resolve_soul_path` with config dirs
from `request.app.state.config`), the `update_agent`/`write_agent` call used by `PATCH`,
and the `audit(...)` pattern. Config dir attribute names come from `src/config.py`.

- [ ] **Step 1: Write failing endpoint tests** (mirror `tests/test_api_agents.py` auth + SSE-drain helpers)

```python
def test_set_identity_writes_soul_and_renames(client, tmp_hermes):
    # default agent exists in the test fixture's AGENTS_JSON
    body = {"displayName": "Billie", "soulContent": "You are Billie."}
    r = client.post("/v1/agents/default/identity", json=body, headers=_auth())
    assert r.status_code == 200
    assert r.json()["displayName"] == "Billie"
    assert r.json()["needsIdentity"] is False
    # SOUL written
    assert (tmp_hermes / "SOUL.md").read_text() == "You are Billie."

def test_set_identity_unknown_agent_404(client):
    r = client.post("/v1/agents/nope/identity",
                    json={"displayName": "X", "soulContent": "Y"}, headers=_auth())
    assert r.status_code == 404

def test_set_identity_empty_soul_400(client):
    r = client.post("/v1/agents/default/identity",
                    json={"displayName": "X", "soulContent": ""}, headers=_auth())
    assert r.status_code == 400
```
(The implementer adapts fixtures to the existing test setup — e.g. a tmp HERMES_HOME and an
AGENTS_JSON containing a `default` entry. If the existing suite lacks a tmp-hermes fixture,
add one.)

- [ ] **Step 2: Run — expect failure.**

- [ ] **Step 3: Implement the endpoint** in `src/api/agents.py`

```python
@router.post("/{agent_id}/identity")
async def set_identity(agent_id: str, body: SetIdentityRequest, request: Request) -> Agent:
    if not body.soulContent.strip():
        raise HTTPException(status_code=400, detail="soulContent must be non-empty")
    cfg = request.app.state.config
    # locate the agent (404 if unknown) — reuse the existing lookup used by get_agent/PATCH
    entry = _find_agent_entry(cfg, agent_id)            # implementer: use existing helper
    if entry is None:
        raise HTTPException(status_code=404, detail="agent not found")
    soul_path = resolve_soul_path(agent_id, cfg.hermes_home, cfg.hermes_profiles_dir)
    write_soul(soul_path, body.soulContent)
    update_agent(cfg, agent_id, UpdateAgent(displayName=body.displayName))  # existing rename path
    audit(cfg.audit_log_path, op="set_identity", agent_id=agent_id,
          actor_ip=(request.client.host if request.client else "unknown"),
          result="ok", duration_ms=0)
    return await get_agent(agent_id, request)            # reuse — now reports needsIdentity=False
```
And in the `Agent`-response builder (`_entry_to_agent` or equivalent), set
`needsIdentity=soul_needs_identity(resolve_soul_path(entry.id, cfg.hermes_home, cfg.hermes_profiles_dir))`.
Add imports: `from src.identity import write_soul, resolve_soul_path, soul_needs_identity`,
`from src.models import SetIdentityRequest, UpdateAgent`, `HTTPException`, `status`.

- [ ] **Step 4: Run tests — pass.** Run the full suite: `pytest -q`. Expected: all pass.

- [ ] **Step 5: Commit** (`git commit -m "feat: POST /v1/agents/{id}/identity + needsIdentity flag"`)

---

## Phase B — Frontend (repo: ollie-hermes-frontend)

Reference: `src/App.tsx` (wizard mount ~L105), `src/components/setup/SetupWizard.tsx`
(pattern), `src/components/agents/shared.tsx` (`Modal`/`Field`),
`src/adapters/orchestrator/OrchestratorClient.ts` + `OrchestratorTypes.ts`,
`src/hooks/useSetupCheck.ts`, `src/components/Layout.tsx` (upper-left name ~L181),
`src/adapters/BackendContext.tsx` (`useOrchestrator`, `useBackend`). The gateway chat
client used for the one-shot polish: implementer locates it (e.g. `HermesGatewayClient` /
the backend chat method) — if a one-shot call is awkward, the template path is acceptable
for v1 and the polish can be a follow-up.

### Task B1: client + types

**Files:** Modify `src/adapters/orchestrator/OrchestratorTypes.ts`,
`src/adapters/orchestrator/OrchestratorClient.ts`.

- [ ] **Step 1:** Add `needsIdentity?: boolean;` to the `Agent` interface in `OrchestratorTypes.ts`.
- [ ] **Step 2:** Add to `OrchestratorClient` (mirror `updateAgent`):
```typescript
async setIdentity(id: string, body: { displayName: string; soulContent: string }): Promise<Agent> {
  const r = await fetch(this.url(`/v1/agents/${encodeURIComponent(id)}/identity`), {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  if (!r.ok) throw new Error(`orchestrator ${r.status}: POST /v1/agents/${id}/identity`);
  return r.json();
}
```
(Use the same `this.url(...)` / header pattern the existing methods use.)
- [ ] **Step 3:** `npm run build` (tsc) — expect no type errors. **Commit.**

### Task B2: persona compose helper

**Files:** Create `src/components/setup/persona.ts`; Test `src/components/setup/persona.test.ts` (if vitest/jest is configured; else a `tsc`-checked pure function).

- [ ] **Step 1:** Implement the deterministic template + the field type:
```typescript
export interface IdentityAnswers {
  name: string; personality: string; mission: string; communication: string; rules: string;
}

export function personaTemplate(a: IdentityAnswers): string {
  return [
    `You are ${a.name}.`,
    ``,
    `**Personality:** ${a.personality}`,
    ``,
    `**Mission:** ${a.mission}`,
    ``,
    `**Communication style:** ${a.communication}`,
    ``,
    `**Hard rules:** ${a.rules}`,
    ``,
  ].join('\n');
}

/** Compose persona prose. Tries a one-shot gateway polish; on ANY failure returns the
 *  deterministic template. `polish` is injected so the wizard can pass the gateway call. */
export async function composePersona(
  a: IdentityAnswers,
  polish?: (prompt: string) => Promise<string>,
): Promise<string> {
  const fallback = personaTemplate(a);
  if (!polish) return fallback;
  try {
    const prompt =
      `Write a concise second-person agent persona ("You are ${a.name}, …") from these, ` +
      `as Markdown, no preamble:\n` +
      `Name: ${a.name}\nPersonality: ${a.personality}\nMission: ${a.mission}\n` +
      `Communication: ${a.communication}\nHard rules: ${a.rules}`;
    const out = (await polish(prompt)).trim();
    return out.length > 20 ? out : fallback;
  } catch {
    return fallback;
  }
}
```
- [ ] **Step 2:** If a test runner exists, assert `personaTemplate` contains `You are Billie.` and `composePersona(a)` (no polish) equals the template. Run it. **Commit.**

### Task B3: `useIdentityCheck` hook

**Files:** Create `src/hooks/useIdentityCheck.ts`.

- [ ] **Step 1:** Implement (mirror `useSetupCheck`, use `useOrchestrator`):
```typescript
import { useState, useEffect, useCallback } from 'react';
import { useOrchestrator } from '../adapters/BackendContext';
import type { Agent } from '../adapters/orchestrator/OrchestratorTypes';

export function useIdentityCheck(enabled: boolean) {
  const orchestrator = useOrchestrator();
  const [needsIdentity, setNeedsIdentity] = useState(false);
  const [defaultAgent, setDefaultAgent] = useState<Agent | null>(null);
  const [loading, setLoading] = useState(true);

  const refresh = useCallback(() => {
    if (!orchestrator) { setLoading(false); return; }
    orchestrator.listAgents()
      .then(agents => {
        const a = agents.find(x => x.id === 'default') ?? agents[0] ?? null;
        setDefaultAgent(a);
        setNeedsIdentity(!!a?.needsIdentity);
      })
      .catch(() => {})
      .finally(() => setLoading(false));
  }, [orchestrator]);

  useEffect(() => {
    if (!enabled) { setLoading(false); return; }
    setLoading(true); refresh();
  }, [enabled, refresh]);

  return { needsIdentity, defaultAgent, loading, refresh };
}
```
(Implementer: confirm `useOrchestrator` is exported from `BackendContext`; if its shape
differs, adapt.)
- [ ] **Step 2:** `npm run build`. **Commit.**

### Task B4: `IdentityWizard` component

**Files:** Create `src/components/setup/IdentityWizard.tsx`.

- [ ] **Step 1:** Build a multi-step modal mirroring `SetupWizard.tsx` (same outer
`fixed inset-0 z-50 …` shell, `zoom:1.5` wrapper). Steps `intro → name → personality →
mission → communication → rules → review`. Each collects one field into an
`IdentityAnswers` state (name pre-filled `"Ollie"`). Use `Field` + the Tailwind input
classes from `shared.tsx`/`EditAgentModal.tsx`. Provide Back/Next; on the name step note
"you can change this anytime". A **Skip setup** link jumps to review with current (default)
values.

On **Save** (review step):
```typescript
const polish = async (prompt: string) => {
  // implementer: call the gateway one-shot via the existing chat/backend client;
  // return assistant text. If unavailable, pass `undefined` to composePersona.
};
const soulContent = await composePersona(answers, polish);
const updated = await orchestrator.setIdentity('default', { displayName: answers.name, soulContent });
onComplete(); // parent refreshes
```
Show a saving spinner + error toast (retry) on failure. Props: `{ onComplete: () => void }`.

- [ ] **Step 2:** `npm run build` — no type errors. **Commit.**

### Task B5: mount in `App.tsx` (chain after provider wizard)

**Files:** Modify `src/App.tsx`.

- [ ] **Step 1:** Add `providerDone` state (set when `SetupWizard.onComplete` fires) and
`useIdentityCheck(enabled = !setupLoading && (!needsSetup || providerDone))`. Mount:
```tsx
{!setupLoading && needsSetup && !providerDone && (
  <SetupWizard onComplete={() => setProviderDone(true)} />
)}
{!setupLoading && (!needsSetup || providerDone) && !idLoading && needsIdentity && !idDone && (
  <IdentityWizard onComplete={() => { setIdDone(true); refresh(); }} />
)}
```
(Adapt to the existing `App.tsx` structure around L105; keep existing wizard behavior intact.)
- [ ] **Step 2:** `npm run build`. **Commit.**

### Task B6: upper-left name from orchestrator

**Files:** Modify `src/components/Layout.tsx`.

- [ ] **Step 1:** Replace the `localStorage('ollie-agent-name')` source for the upper-left
name with the default agent's `displayName` from `orchestrator.listAgents()` (find
`id==='default'`), falling back to localStorage/"Ollie" when the orchestrator is
unavailable. Keep inline-edit if present, but seed from the orchestrator. Re-fetch on mount.
- [ ] **Step 2:** `npm run build`. **Commit.**

---

## Phase C — Install cleanup (repo: ollie-hermes-install, branch feat/ollie-set-identity)

### Task C1: remove the abandoned injection patch

**Files:** Delete `scripts/10-patch-onboarding.sh`,
`templates/onboarding/profile-build-directive.md`; Modify `README.md`.

- [ ] **Step 1:** `git rm scripts/10-patch-onboarding.sh templates/onboarding/profile-build-directive.md`
- [ ] **Step 2:** Remove the step-12 `10-patch-onboarding.sh` block from `README.md`.
- [ ] **Step 3:** `grep -rn "10-patch-onboarding\|profile-build-directive" .` → expect no
matches outside `docs/superpowers/` history. **Commit.**

---

## Phase D — Deploy & validate (controller, not subagents)

### Task D1: revert box overrides
- [ ] Restore `~/.hermes/hermes-agent/agent/onboarding.py` and
`gateway/platforms/api_server.py` from their `.bak.onboard` backups; remove
`~/.hermes/ollie-onboarding-directive.txt`; restart gateways. Confirm both files compile and
no `OLLIE-IDENTITY-ONBOARDING*` markers remain.

### Task D2: deploy orchestrator
- [ ] Push `feat/identity-wizard` (orchestrator) and pull/deploy on the box (the box clones
to `~/ollie-hermes-orchestrator`; `05` resets to `origin/master`, so either merge to master
or point the box at the branch). Restart `ollie-orchestrator`; verify `GET /v1/agents`
returns `needsIdentity: true` for the default agent (SOUL is the stub).

### Task D3: rebuild + redeploy frontend image
- [ ] Build the frontend Docker image (`justnorthow/ollie-hermes-frontend`), push, and
redeploy the dashboard container on the box (per the existing deploy path / `06`). Add
`Cache-Control: no-cache` for `index.html` in `nginx.conf` if not already present (so the
new bundle isn't stale-cached — a known prior issue).

### Task D4: on-box end-to-end
- [ ] Reset `~/.hermes/SOUL.md` to the `OLLIE-SOUL-DEFAULT` stub; hard-reload the dashboard;
confirm the IdentityWizard appears, complete it choosing "Billie"; confirm `SOUL.md` is
personalized (no marker), the upper-left name + agent chip show "Billie", and the wizard does
not reappear on reload. Confirm a preset agent (paige) is unaffected. Report the result with
evidence (the written SOUL.md + the orchestrator `GET /v1/agents`).
