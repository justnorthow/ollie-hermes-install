# Idempotency Phase 6 — Guarantee the Sessions Backfill — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use `- [ ]`.

**Goal:** Ensure the one-time sessions-ownership backfill can't silently regress or be skipped at the fail-closed cutover — if it's skipped, pre-existing Hermes chat sessions 403 their own creators.

**What grounding found (shapes this plan):** `scripts/backfill_sessions.py` is **already idempotent** — it POSTs to PostgREST `agent_sessions` with `on_conflict=agent_id,hermes_session_id` + `Prefer: resolution=ignore-duplicates,return=minimal` (= `INSERT ... ON CONFLICT DO NOTHING`, never overwrites an owner), and the rollout runbook already documents a verify-curl. It is invoked only as a manual runbook step. **Auto-invocation was considered and declined:** the backfill needs `BACKFILL_USER_ID` (the operator's Supabase UUID) which is not ambient on the box, and blindly re-claiming any ownerless session for the operator on every restart is unsafe on multi-user boxes. So the durable improvements are: (1) **test-lock** the idempotency guarantee, and (2) **harden the runbook** so the step is un-skippable and its "did it run?" verification is explicit.

**Non-goal:** No auto-run at startup or in `update orchestrator` (blocked on the non-ambient operator UUID + the perpetual-claim risk). No run backfill (runs are transient; Phase 5 persists them going forward — D6).

## Global Constraints

- **Commits LOCAL + UNPUSHED** on `ollie-hermes-orchestrator` master (base = the Phase-5 tip `535054a`). Do not push.
- Change ONLY tests + the runbook. Do NOT change `backfill_sessions.py`'s behavior (it's already idempotent and in use).
- `pytest -v tests/test_backfill_sessions.py`; no NEW full-suite failures beyond the ~16 pre-existing `pytest-asyncio`-missing async failures.

## File Structure

- **Modify `tests/test_backfill_sessions.py`** — add an idempotency-lock test asserting the POST's conflict-resolution headers/params.
- **Modify `docs/runbooks/agent-sessions-rollout.md`** — make the backfill an explicit REQUIRED gate before cutover, with the verify step called out as the "confirm it ran" check.

---

### Task 1: Lock the backfill idempotency guarantee + harden the runbook (#15 Phase 6)

**Files:**
- Modify: `tests/test_backfill_sessions.py`
- Modify: `docs/runbooks/agent-sessions-rollout.md`

- [ ] **Step 1: Write the failing idempotency-lock test**

Read `scripts/backfill_sessions.py` `main()` and the existing `tests/test_backfill_sessions.py` mock style (it monkeypatches `backfill.httpx.get`/`post` with a fake `_Resp`). Add a test that runs `main()` (with a fake `httpx.get` returning one session and a fake `httpx.post` capturing its `params`/`headers`/`json`, and the required env vars set) and asserts the **write is idempotent**:
```python
def test_backfill_post_is_idempotent_upsert(monkeypatch):
    monkeypatch.setenv("BACKFILL_USER_ID", "u-1")
    monkeypatch.setenv("SUPABASE_URL", "https://x.supabase.co")
    monkeypatch.setenv("SUPABASE_SERVICE_ROLE_KEY", "svc")
    monkeypatch.setenv("HERMES_DASHBOARD_URLS", '{"default":"http://localhost:9119"}')
    captured = {}
    class _Resp:
        def json(self): return [{"id": "s-1", "title": "t"}]
        def raise_for_status(self): pass
    def fake_get(url, params=None, headers=None, timeout=None): return _Resp()
    def fake_post(url, params=None, headers=None, json=None, timeout=None):
        captured.update(params=params, headers=headers, json=json); return _Resp()
    monkeypatch.setattr(backfill.httpx, "get", fake_get)
    monkeypatch.setattr(backfill.httpx, "post", fake_post)
    assert backfill.main() == 0
    # The idempotency guarantee: never double-insert, never overwrite an owner.
    assert captured["params"]["on_conflict"] == "agent_id,hermes_session_id"
    assert captured["headers"]["Prefer"] == "resolution=ignore-duplicates,return=minimal"
```
(Match the actual module import name / fixture helpers already in the file — if it imports the module as `backfill`, reuse that; if it uses a different `_Resp` shape, mirror it.)

- [ ] **Step 2: Run — verify it passes (regression-lock, already-green)**

Run: `pytest -v tests/test_backfill_sessions.py -k idempotent`
Expected: **PASS** — the backfill already uses these headers. This test is a **regression lock**: it fails only if a future edit removes/changes the conflict-resolution semantics (which would reintroduce double-insert / owner-overwrite). If it FAILS now, the idempotency has already regressed — STOP and report.

- [ ] **Step 3: Harden the runbook**

In `docs/runbooks/agent-sessions-rollout.md`, in the "Backfill existing sessions" section (~lines 109-137): (a) label it a **REQUIRED gate** — "Do NOT proceed to the frontend cutover (next step) until this completes; skipping it makes every pre-existing session 403 its own creator"; (b) promote the existing re-run-the-curl check to an explicit **"Confirm it ran"** sub-step (the pre-existing sessions must appear in `agent_sessions` with the operator as `user_id`); (c) add a one-line note that the script is idempotent (safe to re-run) and this is now asserted by `tests/test_backfill_sessions.py::test_backfill_post_is_idempotent_upsert`. Keep the existing commands; only add the gating/labelling prose.

- [ ] **Step 4: Run — full suite sanity**

Run: `pytest -v tests/test_backfill_sessions.py` → all pass. Then `pytest -q` → no NEW failures vs the ~16-async baseline.

- [ ] **Step 5: Commit**

```bash
git add tests/test_backfill_sessions.py docs/runbooks/agent-sessions-rollout.md
git commit -m "test+docs(orchestrator): lock sessions-backfill idempotency + gate the cutover (#15 Phase 6)

The sessions backfill is already idempotent (on_conflict + ignore-duplicates). Adds
a regression-lock test on that guarantee (a future edit can't silently reintroduce
double-insert/owner-overwrite), and hardens the rollout runbook so the backfill is a
REQUIRED, verified gate before the fail-closed frontend cutover — skipping it 403s
pre-existing sessions for their own creators. Auto-invocation intentionally NOT added
(needs the non-ambient operator UUID; blind re-claim is unsafe on multi-user boxes).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review
- **Coverage:** "confirm it ran" → runbook verify gate; "guaranteed idempotent step" → the idempotency is now test-locked + the runbook gates the cutover on it. Runs: no backfill (D6), documented in the non-goal. ✓
- **Placeholders:** exact test; the runbook edit is prose-hardening of an existing section. ✓
- **Risk:** minimal — tests + docs only, no behavior change to a script already in production use. The one judgement (declining auto-invocation) is documented with its rationale. ✓
