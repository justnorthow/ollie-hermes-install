# Instance Title Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Admin-editable per-box instance title ("JNOW Prod") shown in the browser tab, sidebar header, and sign-in card, so multiple Ollie tenants/boxes are distinguishable.

**Architecture:** Title lives as `INSTANCE_TITLE` in `~/hermes-stack/.env`, flows into the served `config.js` (`window.__BACKEND__.instanceTitle`) via `generate-config.sh` at dashboard-container boot — same pattern as `VERTICAL`. A new admin-gated orchestrator endpoint `PUT /v1/instance/title` writes the `.env` key and bounces the dashboard container — same pattern as agent updates writing `AGENTS_JSON`.

**Tech Stack:** React 18 + TypeScript + vitest (frontend), FastAPI + pytest (orchestrator), bash + assert.sh harness (install).

**Spec:** `docs/superpowers/specs/2026-07-13-instance-title-design.md` (install repo).

## Global Constraints

- Empty/absent `INSTANCE_TITLE` = feature off; every surface renders exactly as today. Readers must never throw on a missing key.
- Title validation (orchestrator): trimmed, single line, max **80** chars, no control characters. Empty string clears (writes `INSTANCE_TITLE=`, key stays present).
- Admin gate = `account_admin` tier: `authz.admin_denied` server-side, `atLeast(tier, 'account_admin')` client-side.
- Tab title format: `"<title> — Ollie"` (em dash), plain `"Ollie"` when unset.
- Sidebar subtitle format: `"Agentic OS · <title>"` (middle dot), plain `"Agentic OS"` when unset.
- Repos: `D:\workspaces\jnow\ollie-hermes-frontend`, `D:\workspaces\jnow\ollie-hermes-orchestrator`, `D:\workspaces\jnow\ollie-hermes-install` — all on `master`, commit per task.
- Frontend tests: `npm run test:run` (vitest). Orchestrator tests: `.venv\Scripts\python.exe -m pytest tests -q`. Install tests: `bash tests/test-stack-env.sh`.

---

### Task 1: Frontend config plumbing (`instanceTitle` key, readers, tab title, config.js emission)

**Files:**
- Modify: `D:\workspaces\jnow\ollie-hermes-frontend\src\config.ts`
- Modify: `D:\workspaces\jnow\ollie-hermes-frontend\src\config.test.ts`
- Modify: `D:\workspaces\jnow\ollie-hermes-frontend\scripts\generate-config.sh`
- Modify: `D:\workspaces\jnow\ollie-hermes-frontend\tests\generate-config.test.ts`
- Modify: `D:\workspaces\jnow\ollie-hermes-frontend\src\main.tsx` (right after `const config = getBackendConfig();`, ~line 90)
- Modify: `D:\workspaces\jnow\ollie-hermes-frontend\docker-compose.yml` (dashboard service `environment:` block, next to `VERTICAL`)

**Interfaces:**
- Produces: `BackendConfig.instanceTitle?: string`; `getInstanceTitle(): string` (safe, '' when unset); `formatDocumentTitle(instanceTitle?: string): string`. Tasks 3 consumes `getInstanceTitle`/`formatDocumentTitle`.

- [ ] **Step 1: Write the failing tests** — append to `src/config.test.ts` (follow the file's existing `window.__BACKEND__` setup/teardown pattern; if it saves/restores `window.__BACKEND__` in beforeEach/afterEach, do the same):

```ts
import { getInstanceTitle, formatDocumentTitle } from './config';

describe('instance title', () => {
  it('getInstanceTitle returns the configured title', () => {
    window.__BACKEND__ = { type: 'hermes', instanceTitle: 'JNOW Prod' } as never;
    expect(getInstanceTitle()).toBe('JNOW Prod');
  });

  it('getInstanceTitle is empty and does not throw when key or config missing', () => {
    window.__BACKEND__ = { type: 'hermes' } as never;
    expect(getInstanceTitle()).toBe('');
    delete (window as { __BACKEND__?: unknown }).__BACKEND__;
    expect(getInstanceTitle()).toBe('');
  });

  it('formatDocumentTitle composes title-first with em dash', () => {
    expect(formatDocumentTitle('JNOW Prod')).toBe('JNOW Prod — Ollie');
    expect(formatDocumentTitle('  padded  ')).toBe('padded — Ollie');
    expect(formatDocumentTitle('')).toBe('Ollie');
    expect(formatDocumentTitle(undefined)).toBe('Ollie');
    expect(formatDocumentTitle('   ')).toBe('Ollie');
  });
});
```

And append to `tests/generate-config.test.ts` (inside the existing `describe`):

```ts
it('emits INSTANCE_TITLE as instanceTitle', () => {
  const js = run({ AGENTS_JSON: '[]', INSTANCE_TITLE: 'JNOW Prod' })
  expect(js).toContain('"instanceTitle": "JNOW Prod"')
})

it('emits empty instanceTitle when INSTANCE_TITLE unset', () => {
  const js = run({ AGENTS_JSON: '[]' })
  expect(js).toContain('"instanceTitle": ""')
})
```

- [ ] **Step 2: Run to verify they fail**

Run: `npm run test:run -- src/config.test.ts tests/generate-config.test.ts` (in the frontend repo)
Expected: FAIL — `getInstanceTitle`/`formatDocumentTitle` not exported; `"instanceTitle"` absent from generated config.js.

- [ ] **Step 3: Implement**

In `src/config.ts`, add to `BackendConfig` (after `vertical?: string;`):

```ts
  /** Instance display title (e.g. "JNOW Prod") — shows in the tab title,
   *  sidebar, and sign-in card so multiple boxes/tenants are tellable apart.
   *  Set per box via the INSTANCE_TITLE env var (admin-editable in the UI
   *  through the orchestrator). Empty/unset = generic "Ollie" branding. */
  instanceTitle?: string;
```

And add at the bottom of `src/config.ts` (same safe-read style as `getVertical`):

```ts
/** The instance display title, '' when unset. Reads window.__BACKEND__
 *  directly (no getBackendConfig throw) — a missing optional key must never
 *  take the app down. */
export function getInstanceTitle(): string {
  return window.__BACKEND__?.instanceTitle ?? '';
}

/** Browser tab title: "<instance title> — Ollie", or "Ollie" when unset. */
export function formatDocumentTitle(instanceTitle?: string): string {
  const t = instanceTitle?.trim();
  return t ? `${t} — Ollie` : 'Ollie';
}
```

In `scripts/generate-config.sh`, add to the `config = {...}` dict after the `"vertical"` line:

```python
    "instanceTitle": env("INSTANCE_TITLE"),
```

In `src/main.tsx`, immediately after `const config = getBackendConfig();`:

```ts
document.title = formatDocumentTitle(config.instanceTitle);
```

and add `formatDocumentTitle` to the existing import from `./config`.

In `docker-compose.yml` (frontend repo), add to the dashboard service `environment:` block next to `VERTICAL`:

```yaml
      - INSTANCE_TITLE=${INSTANCE_TITLE:-}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npm run test:run` (full suite — main.tsx isn't unit-covered; the whole suite guards regressions)
Expected: PASS, no failures.

- [ ] **Step 5: Commit**

```bash
git add src/config.ts src/config.test.ts scripts/generate-config.sh tests/generate-config.test.ts src/main.tsx docker-compose.yml
git commit -m "feat(config): instanceTitle key — env INSTANCE_TITLE -> config.js -> tab title"
```

---

### Task 2: `OrchestratorClient.setInstanceTitle`

**Files:**
- Modify: `D:\workspaces\jnow\ollie-hermes-frontend\src\adapters\orchestrator\OrchestratorClient.ts`
- Test: `D:\workspaces\jnow\ollie-hermes-frontend\src\adapters\orchestrator\__tests__\OrchestratorClient.test.ts`

**Interfaces:**
- Produces: `setInstanceTitle(title: string): Promise<void>` — PUT `/v1/instance/title` with `{title}`; throws on non-2xx or `{ok:false}`. Task 3 consumes it.

- [ ] **Step 1: Write the failing tests** — append to the existing describe in `__tests__/OrchestratorClient.test.ts`, following the file's `fetchMock` conventions (mirror how the `whoami`/`updateAgent` tests stub fetch):

```ts
it('setInstanceTitle PUTs the title', async () => {
  fetchMock.mockResolvedValueOnce({ ok: true, json: async () => ({ ok: true }) } as Response);
  await c.setInstanceTitle('JNOW Prod');
  expect(fetchMock).toHaveBeenCalledWith('/orchestrator-proxy/v1/instance/title', {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ title: 'JNOW Prod' }),
  });
});

it('setInstanceTitle throws on HTTP error', async () => {
  fetchMock.mockResolvedValueOnce({ ok: false, status: 403 } as Response);
  await expect(c.setInstanceTitle('x')).rejects.toThrow('403');
});

it('setInstanceTitle throws on ok:false body', async () => {
  fetchMock.mockResolvedValueOnce({ ok: true, json: async () => ({ ok: false, error: 'title too long' }) } as Response);
  await expect(c.setInstanceTitle('x')).rejects.toThrow('title too long');
});
```

(Adapt the two mock-shape lines to the file's existing helper if it builds responses differently — the assertions stay the same.)

- [ ] **Step 2: Run to verify they fail**

Run: `npm run test:run -- src/adapters/orchestrator/__tests__/OrchestratorClient.test.ts`
Expected: FAIL — `setInstanceTitle is not a function`.

- [ ] **Step 3: Implement** — add to `OrchestratorClient` (near `setIdentity`):

```ts
  async setInstanceTitle(title: string): Promise<void> {
    const r = await fetch(this.url('/v1/instance/title'), {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ title }),
    });
    if (!r.ok) throw new Error(`orchestrator ${r.status}: PUT /v1/instance/title`);
    const d = await r.json().catch(() => null) as { ok?: boolean; error?: string } | null;
    if (d && d.ok === false) throw new Error(d.error ?? 'set instance title failed');
  }
```

- [ ] **Step 4: Run to verify pass**

Run: `npm run test:run -- src/adapters/orchestrator/__tests__/OrchestratorClient.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/adapters/orchestrator/OrchestratorClient.ts src/adapters/orchestrator/__tests__/OrchestratorClient.test.ts
git commit -m "feat(orchestrator-client): setInstanceTitle"
```

---

### Task 3: Sidebar title line (admin click-to-edit) + sign-in card line

**Files:**
- Create: `D:\workspaces\jnow\ollie-hermes-frontend\src\components\InstanceTitleLine.tsx`
- Create: `D:\workspaces\jnow\ollie-hermes-frontend\src\components\__tests__\InstanceTitleLine.test.tsx`
- Modify: `D:\workspaces\jnow\ollie-hermes-frontend\src\components\Layout.tsx:445` (replace the static subtitle div)
- Modify: `D:\workspaces\jnow\ollie-hermes-frontend\src\pages\Login.tsx:45` (line under the h1)

**Interfaces:**
- Consumes: `getInstanceTitle`, `formatDocumentTitle` (Task 1); `OrchestratorClient.setInstanceTitle` (Task 2); existing `useOrchestrator` (BackendContext), `useIdentity`/`atLeast` (hooks/useIdentity).
- Produces: `<InstanceTitleLine />` (no props) — the sidebar subtitle line.

- [ ] **Step 1: Write the failing component test** — `src/components/__tests__/InstanceTitleLine.test.tsx`:

```tsx
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import InstanceTitleLine from '../InstanceTitleLine';

const setInstanceTitle = vi.fn().mockResolvedValue(undefined);
let tier: string | null = 'account_admin';

vi.mock('../../adapters/BackendContext', () => ({
  useOrchestrator: () => ({ setInstanceTitle }),
}));
vi.mock('../../hooks/useIdentity', async (importOriginal) => {
  const mod = await importOriginal<typeof import('../../hooks/useIdentity')>();
  return {
    ...mod,
    useIdentity: () => ({ userId: 'u1', tier, tags: [], reachableAgentIds: [], governanceView: false, loading: false }),
  };
});

beforeEach(() => {
  setInstanceTitle.mockClear();
  window.__BACKEND__ = { type: 'hermes', instanceTitle: 'JNOW Prod' } as never;
});

describe('InstanceTitleLine', () => {
  it('renders Agentic OS with the configured title', () => {
    render(<InstanceTitleLine />);
    expect(screen.getByText('Agentic OS · JNOW Prod')).toBeInTheDocument();
  });

  it('renders plain Agentic OS when no title configured', () => {
    window.__BACKEND__ = { type: 'hermes' } as never;
    render(<InstanceTitleLine />);
    expect(screen.getByText('Agentic OS')).toBeInTheDocument();
  });

  it('admin can edit: click, type, Enter saves via orchestrator and updates document.title', async () => {
    tier = 'account_admin';
    render(<InstanceTitleLine />);
    fireEvent.click(screen.getByText('Agentic OS · JNOW Prod'));
    const input = screen.getByRole('textbox');
    fireEvent.change(input, { target: { value: 'Sandbox' } });
    fireEvent.keyDown(input, { key: 'Enter' });
    await waitFor(() => expect(setInstanceTitle).toHaveBeenCalledWith('Sandbox'));
    expect(screen.getByText('Agentic OS · Sandbox')).toBeInTheDocument();
    expect(document.title).toBe('Sandbox — Ollie');
  });

  it('non-admin gets no edit affordance', () => {
    tier = 'member';
    render(<InstanceTitleLine />);
    fireEvent.click(screen.getByText('Agentic OS · JNOW Prod'));
    expect(screen.queryByRole('textbox')).not.toBeInTheDocument();
  });

  it('reverts and shows error when save fails', async () => {
    tier = 'account_admin';
    setInstanceTitle.mockRejectedValueOnce(new Error('boom'));
    render(<InstanceTitleLine />);
    fireEvent.click(screen.getByText('Agentic OS · JNOW Prod'));
    const input = screen.getByRole('textbox');
    fireEvent.change(input, { target: { value: 'Bad' } });
    fireEvent.keyDown(input, { key: 'Enter' });
    await waitFor(() => expect(screen.getByText('Agentic OS · JNOW Prod')).toBeInTheDocument());
    expect(screen.getByText(/boom/)).toBeInTheDocument();
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `npm run test:run -- src/components/__tests__/InstanceTitleLine.test.tsx`
Expected: FAIL — module `../InstanceTitleLine` not found.

- [ ] **Step 3: Implement** — `src/components/InstanceTitleLine.tsx`:

```tsx
import { useRef, useState } from 'react';
import { formatDocumentTitle, getInstanceTitle } from '../config';
import { useOrchestrator } from '../adapters/BackendContext';
import { atLeast, useIdentity } from '../hooks/useIdentity';

/** Sidebar subtitle: "Agentic OS · <instance title>". Click-to-edit for
 *  account_admin+ — saves via PUT /v1/instance/title (orchestrator), which
 *  persists INSTANCE_TITLE in the stack .env and bounces the dashboard so
 *  fresh page loads pick it up from config.js. Optimistic update; reverts
 *  on failure. */
export default function InstanceTitleLine() {
  const orchestrator = useOrchestrator();
  const identity = useIdentity();
  const canEdit = orchestrator != null && atLeast(identity.tier, 'account_admin');
  const [title, setTitle] = useState(() => getInstanceTitle());
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState('');
  const [error, setError] = useState<string | null>(null);
  const inputRef = useRef<HTMLInputElement>(null);

  function startEdit() {
    setDraft(title);
    setError(null);
    setEditing(true);
    setTimeout(() => inputRef.current?.select(), 0);
  }

  async function commit() {
    const trimmed = draft.trim();
    const prev = title;
    setEditing(false);
    if (trimmed === prev) return;
    setTitle(trimmed);
    document.title = formatDocumentTitle(trimmed);
    try {
      await orchestrator!.setInstanceTitle(trimmed);
    } catch (e) {
      setTitle(prev);
      document.title = formatDocumentTitle(prev);
      setError(e instanceof Error ? e.message : 'save failed');
    }
  }

  const label = title ? `Agentic OS · ${title}` : 'Agentic OS';
  return (
    <div className="text-xs mt-0.5" style={{ color: 'rgba(167,139,250,0.7)' }}>
      {editing ? (
        <input
          ref={inputRef}
          value={draft}
          maxLength={80}
          onChange={e => setDraft(e.target.value)}
          onBlur={() => void commit()}
          onKeyDown={e => {
            if (e.key === 'Enter') void commit();
            if (e.key === 'Escape') setEditing(false);
          }}
          className="bg-transparent border-b border-violet-400/40 outline-none w-full text-xs"
          style={{ color: 'rgba(167,139,250,0.9)' }}
        />
      ) : (
        <span
          onClick={canEdit ? startEdit : undefined}
          className={canEdit ? 'cursor-text hover:opacity-75 transition-opacity' : undefined}
          title={canEdit ? 'Click to set instance title' : undefined}
        >
          {label}
        </span>
      )}
      {error && <div className="text-red-400 mt-0.5 truncate" title={error}>{error}</div>}
    </div>
  );
}
```

In `Layout.tsx`, replace line 445:

```tsx
            <div className="text-xs mt-0.5" style={{ color: 'rgba(167,139,250,0.7)' }}>Agentic OS</div>
```

with:

```tsx
            <InstanceTitleLine />
```

and add the import near the other component imports at the top:

```tsx
import InstanceTitleLine from './InstanceTitleLine';
```

In `Login.tsx`, add directly under the `<h1 ...>Sign in to Ollie</h1>` line (line 45), plus `import { getInstanceTitle } from '../config'` at the top:

```tsx
        {getInstanceTitle() && (
          <p className="text-xs text-slate-400 -mt-2">{getInstanceTitle()}</p>
        )}
```

- [ ] **Step 4: Run the full frontend suite**

Run: `npm run test:run`
Expected: PASS (existing Layout/Login tests must stay green — if a Layout snapshot/test asserts the literal "Agentic OS" div, update it to expect the component's default rendering, which is identical text when no title is set).

- [ ] **Step 5: Commit**

```bash
git add src/components/InstanceTitleLine.tsx src/components/__tests__/InstanceTitleLine.test.tsx src/components/Layout.tsx src/pages/Login.tsx
git commit -m "feat(ui): instance title in sidebar (admin click-to-edit) and sign-in card"
```

---

### Task 4: Orchestrator `set_env_key` helper

**Files:**
- Modify: `D:\workspaces\jnow\ollie-hermes-orchestrator\src\agents_json.py` (env-file utilities live here; reuses `_write_env_atomic`)
- Test: `D:\workspaces\jnow\ollie-hermes-orchestrator\tests\test_agents_json.py` (append)

**Interfaces:**
- Produces: `set_env_key(env_path: Path, key: str, value: str) -> None` — atomically upsert one `KEY=value` line, collapsing duplicates to one. Task 5 consumes it.

- [ ] **Step 1: Write the failing tests** — append to `tests/test_agents_json.py`:

```python
def test_set_env_key_appends_when_absent(tmp_path):
    from src.agents_json import set_env_key
    env = tmp_path / ".env"
    env.write_text("HERMES_GATEWAY_KEY=k\n")
    set_env_key(env, "INSTANCE_TITLE", "JNOW Prod")
    text = env.read_text()
    assert "INSTANCE_TITLE=JNOW Prod\n" in text
    assert text.startswith("HERMES_GATEWAY_KEY=k\n")


def test_set_env_key_replaces_in_place_and_collapses_duplicates(tmp_path):
    from src.agents_json import set_env_key
    env = tmp_path / ".env"
    env.write_text("A=1\nINSTANCE_TITLE=Old\nB=2\nINSTANCE_TITLE=Older\n")
    set_env_key(env, "INSTANCE_TITLE", "New")
    lines = env.read_text().splitlines()
    assert lines.count("INSTANCE_TITLE=New") == 1
    assert "INSTANCE_TITLE=Old" not in lines and "INSTANCE_TITLE=Older" not in lines
    assert "A=1" in lines and "B=2" in lines


def test_set_env_key_empty_value_keeps_key(tmp_path):
    from src.agents_json import set_env_key
    env = tmp_path / ".env"
    env.write_text("INSTANCE_TITLE=Old\n")
    set_env_key(env, "INSTANCE_TITLE", "")
    assert "INSTANCE_TITLE=\n" in env.read_text()


def test_set_env_key_value_with_backslashes_survives(tmp_path):
    # Same re.sub backslash-escape trap _replace_agents_line guards against.
    from src.agents_json import set_env_key
    env = tmp_path / ".env"
    env.write_text("INSTANCE_TITLE=Old\n")
    set_env_key(env, "INSTANCE_TITLE", r"C:\Users\weird ሴ")
    assert r"INSTANCE_TITLE=C:\Users\weird ሴ" in env.read_text()
```

- [ ] **Step 2: Run to verify they fail**

Run: `.venv\Scripts\python.exe -m pytest tests/test_agents_json.py -q` (in the orchestrator repo)
Expected: FAIL — `ImportError: cannot import name 'set_env_key'`.

- [ ] **Step 3: Implement** — add to `src/agents_json.py` (after `remove_agent`):

```python
def set_env_key(env_path: Path, key: str, value: str) -> None:
    """Atomically upsert one KEY=value line in a stack .env. Replaces the
    first occurrence in place, drops any duplicates, appends when absent.
    Replacement uses a function (not a string) for the same backslash-escape
    reason as _replace_agents_line."""
    if "\n" in value or "\r" in value:
        raise ValueError(f"{key} must be a single-line value")
    text = env_path.read_text()
    line = f"{key}={value}"
    pattern = re.compile(rf"^{re.escape(key)}=.*$", re.MULTILINE)
    if pattern.search(text):
        first_done = [False]

        def _sub(m):
            if not first_done[0]:
                first_done[0] = True
                return line
            return "\x00DROP\x00"

        text = pattern.sub(_sub, text)
        text = "\n".join(l for l in text.split("\n") if l != "\x00DROP\x00")
    else:
        sep = "" if text.endswith("\n") or not text else "\n"
        text = f"{text}{sep}{line}\n"
    _write_env_atomic(env_path, text)
```

- [ ] **Step 4: Run to verify pass**

Run: `.venv\Scripts\python.exe -m pytest tests/test_agents_json.py -q`
Expected: PASS (all, including pre-existing tests).

- [ ] **Step 5: Commit**

```bash
git add src/agents_json.py tests/test_agents_json.py
git commit -m "feat(env): set_env_key atomic single-key upsert for the stack .env"
```

---

### Task 5: Orchestrator `PUT /v1/instance/title`

**Files:**
- Create: `D:\workspaces\jnow\ollie-hermes-orchestrator\src\api\instance.py`
- Modify: `D:\workspaces\jnow\ollie-hermes-orchestrator\src\api\main.py` (import + `include_router`)
- Test: `D:\workspaces\jnow\ollie-hermes-orchestrator\tests\test_api_instance.py`

**Interfaces:**
- Consumes: `set_env_key` (Task 4), `authz.admin_denied`, `docker_ops.bounce_dashboard`, `audit`, `require_bearer`.
- Produces: `PUT /v1/instance/title` body `{"title": str}` → `{"ok": true}` | 400 `{"ok": false, "error": str}` | 403. Task 2's client calls it.

- [ ] **Step 1: Write the failing tests** — `tests/test_api_instance.py`:

```python
import pytest
from fastapi.testclient import TestClient


@pytest.fixture
def client(fake_env, monkeypatch):
    import src.api.instance as instance_mod
    calls = []
    monkeypatch.setattr(instance_mod, "bounce_dashboard", lambda: calls.append("bounce"))
    from src.api.main import create_app
    app = create_app()
    c = TestClient(app)
    c.bounce_calls = calls  # type: ignore[attr-defined]
    return c


def _auth():
    return {"Authorization": "Bearer topsecret"}


def _env_text(fake_env):
    return (fake_env["stack"] / ".env").read_text()


def test_set_title_writes_env_and_bounces(client, fake_env):
    r = client.put("/v1/instance/title", json={"title": "JNOW Prod"}, headers=_auth())
    assert r.status_code == 200
    assert r.json() == {"ok": True}
    assert "INSTANCE_TITLE=JNOW Prod\n" in _env_text(fake_env)
    assert client.bounce_calls == ["bounce"]


def test_set_title_trims_and_empty_clears(client, fake_env):
    client.put("/v1/instance/title", json={"title": "  Sandbox  "}, headers=_auth())
    assert "INSTANCE_TITLE=Sandbox\n" in _env_text(fake_env)
    client.put("/v1/instance/title", json={"title": ""}, headers=_auth())
    assert "INSTANCE_TITLE=\n" in _env_text(fake_env)


def test_set_title_rejects_too_long_and_control_chars(client, fake_env):
    r = client.put("/v1/instance/title", json={"title": "x" * 81}, headers=_auth())
    assert r.status_code == 400
    assert r.json()["ok"] is False
    r2 = client.put("/v1/instance/title", json={"title": "a\tb"}, headers=_auth())
    assert r2.status_code == 400
    assert "INSTANCE_TITLE" not in _env_text(fake_env)
    assert client.bounce_calls == []


def test_set_title_requires_admin(client, fake_env, monkeypatch):
    from src.api import authz
    monkeypatch.setattr(authz.roles, "resolve_tier", lambda instance_id, user_id: "member")
    r = client.put("/v1/instance/title", json={"title": "Nope"},
                   headers={**_auth(), "X-Auth-User-Id": "user-123"})
    assert r.status_code == 403
    assert "INSTANCE_TITLE" not in _env_text(fake_env)


def test_set_title_unauthenticated_401(client):
    assert client.put("/v1/instance/title", json={"title": "x"}).status_code == 401


def test_set_title_reports_bounce_failure_but_persists(client, fake_env, monkeypatch):
    import src.api.instance as instance_mod
    def boom():
        raise RuntimeError("docker down")
    monkeypatch.setattr(instance_mod, "bounce_dashboard", boom)
    r = client.put("/v1/instance/title", json={"title": "Durable"}, headers=_auth())
    assert r.status_code == 200
    body = r.json()
    assert body["ok"] is False and "bounce" in body["error"]
    assert "INSTANCE_TITLE=Durable\n" in _env_text(fake_env)
```

- [ ] **Step 2: Run to verify they fail**

Run: `.venv\Scripts\python.exe -m pytest tests/test_api_instance.py -q`
Expected: FAIL — `ModuleNotFoundError: src.api.instance` (fixture import).

- [ ] **Step 3: Implement** — `src/api/instance.py`:

```python
import logging
import re
import time

from fastapi import APIRouter, Depends, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from src.agents_json import set_env_key
from src.api import authz
from src.audit import audit
from src.auth import require_bearer
from src.docker_ops import bounce_dashboard

_logger = logging.getLogger(__name__)

router = APIRouter(prefix="/v1/instance", tags=["instance"], dependencies=[Depends(require_bearer)])

MAX_TITLE_LEN = 80
_CONTROL_RE = re.compile(r"[\x00-\x1f\x7f]")


class SetTitle(BaseModel):
    title: str


@router.put("/title")
async def set_title(body: SetTitle, request: Request):
    """Persist the instance display title: INSTANCE_TITLE in the stack .env,
    then bounce the dashboard so generate-config.sh re-emits config.js.
    Empty title clears (key stays present, blank value)."""
    denied = authz.admin_denied(request)
    if denied:
        return denied
    title = body.title.strip()
    if len(title) > MAX_TITLE_LEN:
        return JSONResponse({"ok": False, "error": f"title too long (max {MAX_TITLE_LEN} chars)"}, status_code=400)
    if _CONTROL_RE.search(title):
        return JSONResponse({"ok": False, "error": "title must not contain control characters"}, status_code=400)

    cfg = request.app.state.config
    started = time.monotonic()
    set_env_key(cfg.hermes_stack_dir / ".env", "INSTANCE_TITLE", title)
    error = None
    try:
        bounce_dashboard()
    except Exception as e:
        _logger.warning("instance title: dashboard bounce failed", exc_info=True)
        error = f"saved, but dashboard bounce failed: {e}"

    actor_ip = request.client.host if request.client else "unknown"
    audit(cfg.audit_log_path, op="set_instance_title", agent_id="-", actor_ip=actor_ip,
          result="ok" if error is None else "error",
          duration_ms=int((time.monotonic() - started) * 1000),
          error=error, title=title)
    if error:
        return {"ok": False, "error": error}
    return {"ok": True}
```

In `src/api/main.py`, add with the other router imports:

```python
from src.api.instance import router as instance_router
```

and with the other `include_router` calls:

```python
    app.include_router(instance_router)
```

- [ ] **Step 4: Run the full orchestrator suite**

Run: `.venv\Scripts\python.exe -m pytest tests -q`
Expected: PASS (359+ tests, zero failures).

- [ ] **Step 5: Commit**

```bash
git add src/api/instance.py src/api/main.py tests/test_api_instance.py
git commit -m "feat(api): PUT /v1/instance/title — admin-gated instance display title"
```

---

### Task 6: Install repo — compose env decl + preserve `INSTANCE_TITLE`

**Files:**
- Modify: `D:\workspaces\jnow\ollie-hermes-install\templates\docker-compose.yml` (dashboard `environment:` block, after the `VERTICAL` line ~153)
- Modify: `D:\workspaces\jnow\ollie-hermes-install\scripts\lib\stack-env.sh`
- Modify: `D:\workspaces\jnow\ollie-hermes-install\tests\test-stack-env.sh`

**Interfaces:**
- Consumes: nothing new. Produces: `INSTANCE_TITLE` as a managed, forwarded stack-.env key reaching the dashboard container env.

- [ ] **Step 1: Write the failing test** — in `tests/test-stack-env.sh`:

(a) Add `INSTANCE_TITLE` to the `unset` list inside EVERY existing test's subshell (they enumerate the managed keys — `test_baseline`, `test_pins_single_and_new`, `test_cortex_api_key_forwarded` (both subshells), `test_operator_tunables_preserved`, `test_golden_full_env`), e.g.:

```bash
  ( unset FIRECRAWL_API_KEY HERMES_UI_URL VERTICAL INSTANCE_TITLE \
          CORTEX_API_KEY HERMES_UI_HOSTNAME DASHBOARD_BIND HIA_BASE_URL
```

(b) In `test_golden_full_env`: add `INSTANCE_TITLE=JNOW Prod` to the `$old` heredoc, add `INSTANCE_TITLE` to the exactly-one `for k in ...` list, and add:

```bash
  assert_eq "instance title preserved" "$(grep -E '^INSTANCE_TITLE=' "$new" | cut -d= -f2-)" "JNOW Prod"
```

(c) Add a dedicated forward test after `test_operator_tunables_preserved`:

```bash
# INSTANCE_TITLE (set from the Ollie UI via the orchestrator) must survive a
# stack re-render, and default to an empty (but present) line when never set.
test_instance_title_forwarded() {
  local old new; old="$(mktemp)"; new="$(mktemp)"
  printf 'INSTANCE_TITLE=JNOW Prod\n' > "$old"
  ( unset INSTANCE_TITLE FIRECRAWL_API_KEY HERMES_UI_URL VERTICAL \
          CORTEX_API_KEY HERMES_UI_HOSTNAME DASHBOARD_BIND HIA_BASE_URL
    render_stack_env "$new" "$old" )
  assert_eq "INSTANCE_TITLE preserved" "$(grep -E '^INSTANCE_TITLE=' "$new" | cut -d= -f2-)" "JNOW Prod"

  local old2 new2; old2="$(mktemp)"; new2="$(mktemp)"
  : > "$old2"
  ( unset INSTANCE_TITLE FIRECRAWL_API_KEY HERMES_UI_URL VERTICAL \
          CORTEX_API_KEY HERMES_UI_HOSTNAME DASHBOARD_BIND HIA_BASE_URL
    render_stack_env "$new2" "$old2" )
  assert_count "INSTANCE_TITLE line present (empty ok)" "$new2" "INSTANCE_TITLE" 1
  rm -f "$old" "$new" "$old2" "$new2"
}

test_instance_title_forwarded
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test-stack-env.sh` (in the install repo; use Git Bash / the Bash tool)
Expected: FAIL — no `INSTANCE_TITLE` line rendered.

- [ ] **Step 3: Implement** — in `scripts/lib/stack-env.sh`, inside `render_stack_env`:

Add to the locals (next to `vertical`):

```bash
  local instance_title; instance_title="$(_forward INSTANCE_TITLE "$old")"
```

Add to the heredoc after the `VERTICAL=${vertical}` line:

```bash
# Instance display title (tab/sidebar/login) — set from the Ollie UI (admin);
# the orchestrator writes it here. Empty = generic "Ollie" branding.
INSTANCE_TITLE=${instance_title}
```

In `templates/docker-compose.yml`, add to the dashboard service environment after the `VERTICAL` entry:

```yaml
      # Instance display title (e.g. "JNOW Prod") — generate-config.sh writes it
      # into config.js; shows in the tab title, sidebar, and sign-in card.
      # Admin-editable in the Ollie UI via the orchestrator; empty = generic.
      - INSTANCE_TITLE=${INSTANCE_TITLE:-}
```

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/test-stack-env.sh` — Expected: all assertions pass, `finish` reports 0 failures.
Also run: `.venv/Scripts/python.exe -m pytest tests -q` if the repo has a venv, else `python -m pytest tests -q` — Expected: PASS (fleetctl tests untouched).

- [ ] **Step 5: Commit**

```bash
git add templates/docker-compose.yml scripts/lib/stack-env.sh tests/test-stack-env.sh
git commit -m "feat(stack): INSTANCE_TITLE managed .env key + dashboard compose env"
```

---

### Task 7: Deploy + end-to-end verification (jnow prod first, then sandbox + getbilled)

**Files:** none (operational). Uses the base64-piped remote-script pattern; `ssh ollie` may need `-i ~/.ssh/ollie_jnow_new -o IdentitiesOnly=yes` (1Password agent flake).

- [ ] **Step 1: Push all three repos**

```bash
git -C D:/workspaces/jnow/ollie-hermes-frontend push origin master
git -C D:/workspaces/jnow/ollie-hermes-orchestrator push origin master
git -C D:/workspaces/jnow/ollie-hermes-install push origin master
```

- [ ] **Step 2: Build + push the frontend image, bump the pin**

In the frontend repo, follow the existing image build flow (same as the favicon/Usage deploys): `docker build` → push to `justnorthow/frontend` → note the new `sha256:` digest. Then in the install repo, update the `FRONTEND_IMAGE` digest in `scripts/06-install-stack.sh` (the authoritative pin), commit `chore: bump FRONTEND_IMAGE for instance-title`, push, and run `bash scripts/check-install-pin.sh` if a Fleet pin bump is planned.

- [ ] **Step 3: Deploy to jnow prod**

On the box (via base64-piped script): `git -C ~/ollie-hermes-orchestrator fetch && git merge --ff-only origin/master && systemctl --user restart ollie-orchestrator`. Then add the compose env line + new FRONTEND_IMAGE (re-run 06 per its runbook, or hand-add `- INSTANCE_TITLE=${INSTANCE_TITLE:-}` to the dashboard service + update the pin) and `docker compose -f ~/hermes-stack/docker-compose.yml up -d dashboard`.

- [ ] **Step 4: Verify end-to-end in the browser (jnow prod)**

1. Load ollie.jnow.io as an admin — sidebar shows "Agentic OS", tab shows "Ollie" (no title set yet).
2. Click the subtitle, type `JNOW Prod`, Enter — subtitle becomes "Agentic OS · JNOW Prod", tab becomes "JNOW Prod — Ollie".
3. `ssh` check: `grep INSTANCE_TITLE ~/hermes-stack/.env` → `INSTANCE_TITLE=JNOW Prod`; `docker exec ollie-dashboard grep instanceTitle /usr/share/nginx/html/config.js` → `"instanceTitle": "JNOW Prod"`.
4. Hard-refresh + sign out: the sign-in card shows "JNOW Prod" under "Sign in to Ollie"; tab title still "JNOW Prod — Ollie".
5. (If a non-admin login is handy) confirm no edit affordance for a member-tier user.

- [ ] **Step 5: Repeat deploy on sandbox + getbilled, set their titles** (e.g. `Ollie Sandbox`, `GetBilled`), verify step 4.1–4.3 on each.

- [ ] **Step 6: Update STATE.md + OB1 capture, commit session-context**

---

## Self-Review (done at write time)

- **Spec coverage:** storage/flow → Tasks 1+6; API → Tasks 4+5; display (tab/sidebar/login) → Tasks 1+3; edit UI + admin gate → Task 3 (client) + Task 5 (server); testing → per-task; deploy → Task 7. No gaps.
- **Placeholders:** none — every code step carries complete code. Task 2 Step 1 notes mock-shape adaptation to the file's existing fetch helper; assertions are fully specified.
- **Type consistency:** `instanceTitle` (config key), `getInstanceTitle()`, `formatDocumentTitle()`, `setInstanceTitle(title)`, `set_env_key(env_path, key, value)`, `PUT /v1/instance/title` — names match across tasks.
