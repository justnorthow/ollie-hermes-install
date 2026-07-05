# Idempotency Phase 5 — Orchestrator Run-Owner Persistence — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use `- [ ]`.

**Goal:** Persist run→owner to Supabase so a member keeps access to their own in-flight runs across an orchestrator restart. Today `_RUN_OWNERS` is an in-memory dict lost on restart, and the access gate is fail-closed — so after `update orchestrator`/any restart a member is 403'd out of stop/approve/events on runs they started.

**Architecture:** Mirror the existing `sessions.py` ownership persistence exactly. Add a `run_owners` Supabase table + `record_run_owner`/`get_run_owner` functions (same best-effort httpx pattern, keyed by `run_id` alone since Hermes run_ids are globally-unique UUIDs — matching the current in-memory dict's keying). `_remember_run_owner` also persists; `_run_owner_gate` falls back to Supabase on a memory miss and repopulates the cache. No route/signature changes. Degrades identically to sessions when Supabase is unset (memory-only + fail-closed-deny).

**Tech Stack:** Python 3 / FastAPI, synchronous `httpx`, pytest. Supabase REST (PostgREST) via the service-role key. Migrations applied manually via the Supabase dashboard.

## Global Constraints

- **Commits LOCAL + UNPUSHED** on `ollie-hermes-orchestrator` master (base = the security commit `828b2ee`). Do not push.
- **Mirror `sessions.py` verbatim in shape:** reuse its `_sb()` / `_sb_headers()` helpers; every new function checks `_sb()` first (no-op / `None` when Supabase unset), wraps httpx in `try/except Exception: log+degrade`, and NEVER raises to the caller.
- **Fail-closed preserved:** an unknown run (owner resolves to `None` even after the Supabase read) still denies a member. Identity-less internal callers (no `X-Auth-User-Id`) still pass.
- **No signature or route changes** — `_remember_run_owner(run_id, user_id)` and `_run_owner_gate(request, run_id)` keep their signatures; we only add a persist call + a fallback read.
- Migration number **0017** (governance used 0012–0016; verify against the live Supabase project before applying). Migrations are applied by hand via the Supabase dashboard (project `kpdqhntsvjzhqjeupzsj`).
- Run the suite with `pytest -v` (or scoped: `pytest -v tests/test_runs_ownership.py tests/test_runs_passthrough.py tests/test_sessions_api.py`).

## File Structure

- **Create `docs/migrations/0017_run_owners.sql`** — the `run_owners` table + RLS, mirroring `0011_agent_sessions.sql`. Applied manually.
- **Modify `src/api/sessions.py`** — add `record_run_owner(run_id, user_id)` + `get_run_owner(run_id)` (reuse `_sb`/`_sb_headers`).
- **Modify `src/api/runs.py`** — `_remember_run_owner` also persists; `_run_owner_gate` adds a Supabase fallback + cache repopulate; fix the stale fail-open docstring.
- Tests: `tests/test_sessions_api.py` (store funcs), `tests/test_runs_ownership.py` (survive-restart).

---

### Task 1: `run_owners` migration + persistence functions

**Files:**
- Create: `docs/migrations/0017_run_owners.sql`
- Modify: `src/api/sessions.py` (add two functions)
- Modify: `tests/test_sessions_api.py` (add store tests)

- [ ] **Step 1: Write the failing store tests**

In `tests/test_sessions_api.py`, add tests mirroring the existing session-store tests: (a) `record_run_owner` POSTs to `/rest/v1/run_owners` with `on_conflict=run_id` + the `Prefer: resolution=ignore-duplicates,return=minimal` header and body `{"run_id":..., "user_id":...}` (monkeypatch `sessions.httpx.post` with a fake resp capturing the call, set `SUPABASE_URL`+`SUPABASE_SERVICE_ROLE_KEY`); (b) `get_run_owner` GETs with `params={"run_id":"eq.<id>","select":"user_id"}` and returns `rows[0]["user_id"]` (monkeypatch `sessions.httpx.get`); (c) both no-op/`None` when Supabase env is unset (`monkeypatch.delenv`), asserting httpx is NOT called — mirror `test_touch_session_noop_without_supabase_config`.

- [ ] **Step 2: Run — verify FAIL**

Run: `pytest -v tests/test_sessions_api.py -k run_owner`
Expected: FAIL — `record_run_owner`/`get_run_owner` don't exist.

- [ ] **Step 3: Add the two functions to `sessions.py`**

Append (after `touch_session`, reusing `_sb`/`_sb_headers`):
```python
def get_run_owner(run_id: str) -> str | None:
    """user_id owning run_id, or None if unowned/unknown/store unavailable."""
    sb = _sb()
    if not sb:
        return None
    url, key = sb
    try:
        resp = httpx.get(
            f"{url}/rest/v1/run_owners",
            params={"run_id": f"eq.{run_id}", "select": "user_id"},
            headers=_sb_headers(key), timeout=10.0,
        )
        resp.raise_for_status()
        rows = resp.json()
        return rows[0]["user_id"] if rows else None
    except Exception:
        _logger.warning("get_run_owner failed", exc_info=True)
        return None


def record_run_owner(run_id: str, user_id: str) -> None:
    """Insert a run-ownership row if absent. Best-effort: never raises, never overwrites."""
    sb = _sb()
    if not sb:
        return
    url, key = sb
    try:
        resp = httpx.post(
            f"{url}/rest/v1/run_owners",
            params={"on_conflict": "run_id"},
            headers={**_sb_headers(key),
                     "Prefer": "resolution=ignore-duplicates,return=minimal"},
            json={"run_id": run_id, "user_id": user_id},
            timeout=10.0,
        )
        resp.raise_for_status()
    except Exception:
        _logger.warning("record_run_owner failed", exc_info=True)
```

- [ ] **Step 4: Create the migration**

Create `docs/migrations/0017_run_owners.sql` (mirror `0011_agent_sessions.sql`):
```sql
-- 0017_run_owners.sql — per-user ownership of Hermes runs, so a member keeps
-- access to their own in-flight runs across an orchestrator restart (idempotency
-- Phase 5). Mirrors 0011_agent_sessions.sql. Apply via the Supabase dashboard
-- (project kpdqhntsvjzhqjeupzsj, SQL Editor); mirror into
-- jnow-workspace/development/core/supabase/migrations/ for the canonical record.
-- NOTE: confirm 0017 is the next free number against the live project before applying.

create table if not exists public.run_owners (
  run_id      text primary key,          -- Hermes run id (globally-unique uuid)
  user_id     uuid not null,             -- Supabase auth.users id (JWT `sub`)
  created_at  timestamptz not null default now()
);

create index if not exists run_owners_user_idx on public.run_owners (user_id);

alter table public.run_owners enable row level security;

-- SELECT own rows only (defense in depth; the orchestrator reads via the service
-- role, which bypasses RLS). No write policies -> only the service role writes.
create policy run_owners_select_own on public.run_owners
  for select to authenticated
  using (user_id = auth.uid());

comment on table public.run_owners is
  'Idempotency Phase 5: maps Hermes run ids to owning users so the orchestrator run gate survives a restart; enforced fail-closed.';
```

- [ ] **Step 5: Run — verify PASS + full suite**

Run: `pytest -v tests/test_sessions_api.py -k run_owner` → pass. Then `pytest -v` → full suite green (the repo has a documented Windows baseline of a few skips/failures — confirm no NEW failures vs baseline).

- [ ] **Step 6: Commit**

```bash
git add docs/migrations/0017_run_owners.sql src/api/sessions.py tests/test_sessions_api.py
git commit -m "feat(orchestrator): run_owners persistence store + migration (#14 Phase 5)

Adds a run_owners Supabase table + record_run_owner/get_run_owner mirroring the
agent_sessions ownership store (best-effort httpx, degrades to no-op/None when
Supabase is unset). Wiring into the run gate follows.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Wire persistence into the run gate + fix the stale docstring

**Files:**
- Modify: `src/api/runs.py` (`_remember_run_owner`, `_run_owner_gate`, the `_RUN_OWNERS` docstring)
- Modify: `tests/test_runs_ownership.py` (survive-restart test)

**Interfaces:**
- Consumes: `_sessions_store.record_run_owner`, `_sessions_store.get_run_owner` from Task 1 (`_sessions_store` is the alias `runs.py` already uses for the sessions module).

- [ ] **Step 1: Write the failing survive-restart test**

In `tests/test_runs_ownership.py`, add a test: monkeypatch `runs._sessions_store.get_run_owner` to return a known `user_id` for a run_id (simulating the persisted row); populate then **clear** `runs._RUN_OWNERS` (simulating a restart); call the gate path (e.g. hit `stop_run`/`run_events` for that run with header `X-Auth-User-Id: <owner>`) and assert it is ALLOWED (not 403); and a second call with a DIFFERENT user is 403. Follow the file's existing client-fixture + monkeypatch style.

- [ ] **Step 2: Run — verify FAIL**

Run: `pytest -v tests/test_runs_ownership.py -k restart`
Expected: FAIL — after `_RUN_OWNERS.clear()` the gate denies the real owner (no Supabase fallback yet).

- [ ] **Step 3: Persist in `_remember_run_owner`**

In `src/api/runs.py`, change `_remember_run_owner` to also persist (best-effort; signature unchanged):
```python
def _remember_run_owner(run_id: str, user_id: str) -> None:
    if len(_RUN_OWNERS) >= _RUN_OWNERS_MAX:
        _RUN_OWNERS.pop(next(iter(_RUN_OWNERS)))
    _RUN_OWNERS[run_id] = user_id
    try:
        _sessions_store.record_run_owner(run_id, user_id)
    except Exception:
        pass
```

- [ ] **Step 4: Supabase fallback in `_run_owner_gate` + fix docstring**

Replace `_run_owner_gate` with a memory-first, Supabase-fallback version (signature unchanged):
```python
def _run_owner_gate(request: Request, run_id: str) -> JSONResponse | None:
    user_id = request.headers.get("X-Auth-User-Id", "").strip()
    if not user_id:
        return None  # identity-less internal callers hold the bearer key
    owner = _RUN_OWNERS.get(run_id)
    if owner is None:
        owner = _sessions_store.get_run_owner(run_id)  # survives restart when Supabase is set
        if owner is not None:
            _RUN_OWNERS[run_id] = owner  # repopulate the in-memory cache
    if owner != user_id:
        return JSONResponse({"detail": "Run not found"}, status_code=403)
    return None
```
And update the `_RUN_OWNERS` docstring (lines ~24-28) to state the truth:
```python
# run_id -> creating user's Supabase UUID. In-memory cache; also persisted to the
# run_owners table (see sessions.record_run_owner) so the fail-closed run gate
# survives a restart. When Supabase is unset the cache is memory-only and a restart
# drops it — the gate then fail-closed-denies a member's own in-flight runs until
# they start a new one (acceptable: run ids are unguessable and short-lived).
_RUN_OWNERS: dict[str, str] = {}
```

- [ ] **Step 5: Run — verify PASS + full suite**

Run: `pytest -v tests/test_runs_ownership.py` → pass (incl. the new restart test). Then `pytest -v` → no NEW failures vs the Windows baseline. Confirm the existing `test_runs_passthrough.py` gate tests still pass (the gate's deny behavior for a genuinely-unknown run is unchanged).

- [ ] **Step 6: Commit**

```bash
git add src/api/runs.py tests/test_runs_ownership.py
git commit -m "feat(orchestrator): run gate falls back to persisted run_owners on restart (#14 Phase 5)

_remember_run_owner now persists to run_owners; _run_owner_gate falls back to the
persisted owner on an in-memory miss (and repopulates the cache), so a member
keeps access to their own in-flight runs across an orchestrator restart. Fixed the
stale docstring that claimed the gate fails open. Fail-closed for unknown runs and
memory-only-degrade when Supabase is unset both preserved.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review
- **Coverage:** persistence store + migration → Task 1; gate wiring + docstring → Task 2. Both the "survive restart" property and the fail-closed/degrade behaviors are tested. ✓
- **Placeholders:** exact code mirrored from `sessions.py`; the only judgement is the migration number (0017 — flagged to verify). ✓
- **Risk:** keyed by `run_id` alone (matches the current in-memory dict + globally-unique UUIDs) — no signature/route changes, minimal blast radius. Fail-closed and Supabase-unset-degrade both preserved and tested. Migration is additive + manual. ✓
