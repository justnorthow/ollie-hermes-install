# Idempotency Phase 3 — Fleet Supabase Durability (S72 fix) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Make Supabase auth durable so the S72 login-outage class can't recur: the cookie domain becomes Fleet-managed (not a box hand-edit), and a re-enroll auto-restores Supabase from Fleet's stored config.

**Architecture:** Two coordinated changes across two repos. (1) `SUPABASE_COOKIE_DOMAIN` flows end-to-end — Fleet's SQLite `instance_supabase` gains a `cookie_domain` column; the config model, Access-tab UI, and apply-payload carry it (camelCase `cookieDomain` in TS, snake_case `cookie_domain` on the wire); the on-box `ollie-fleetctl` writer writes it into the stack `.env`. (2) `finalizeEnrollment` auto-applies the instance's stored Supabase config (if enabled) so a rebuild/re-enroll restores the box `.env` from Fleet's source of truth — non-fatally.

**Tech Stack:** Python 3 stdlib (`ollie-fleetctl`, pytest). TypeScript + better-sqlite3 + Hono + React (`ollie-fleet`, vitest).

## Global Constraints

- **Commits are LOCAL + UNPUSHED** in BOTH repos. `ollie-hermes-install` commits on its master (Task 1); `ollie-fleet` commits on its master (Tasks 2-4, base = security commit `39550f0`; its 2 untracked docs are harmless). Do not push either.
- **Disable semantics are PRESERVED (decision, John 2026-07-05):** a deliberate disable (`enabled=false`) still blanks the Supabase keys — including `cookie_domain` — so the dashboard falls through to OAuth/basic. We are NOT doing "skip-write-when-empty" (#4a dropped — it would make the disable toggle a no-op). Durability comes from #5 + Phase 1's `.env` preserve.
- **Payload contract (wire):** the JSON payload sent to `ollie-fleetctl set-dashboard-auth` uses **snake_case** keys: `supabase_url`, `anon_key`, `service_role_key`, and the new `cookie_domain`. Fleet's internal TS uses camelCase `cookieDomain`, mapped to `cookie_domain` only in `buildSupabaseApplyPayload`.
- **`cookie_domain` follows the exact same `enabled ? value : ""` pattern** as `supabase_url`/`anon_key` in the writer, and the same optional-string handling as the other fields in the TS model.
- **Migration is idempotent** via the repo's established `try/catch ALTER TABLE ADD COLUMN` pattern (see `db.ts:117-128` "Mail columns").
- **#5 auto-apply is NON-FATAL:** enrollment must never fail because a Supabase apply failed (or no config exists) — guard + catch + continue.
- fleetctl-touching tasks run BOTH `python -m pytest tests/test_fleetctl.py -q` AND `bash tests/test-fleetctl-update.sh`. `ollie-fleet` tasks run `npm test` (vitest).

---

## File Structure

- **`ollie-hermes-install/templates/bin/ollie-fleetctl`** — `set_dashboard_auth_supabase`: read `cookie_domain` from the payload, validate, write `SUPABASE_COOKIE_DOMAIN` to the stack `.env`.
- **`ollie-fleet/src/server/db.ts`** — add the idempotent `cookie_domain` column migration.
- **`ollie-fleet/src/server/lib/supabase-config.ts`** — `SaveSupabaseInput` + `saveSupabaseConfig` + `getSupabaseConfigView` + `buildSupabaseApplyPayload` carry `cookieDomain`/`cookie_domain`.
- **`ollie-fleet/src/server/routes/instance-supabase.ts`** — the save route passes `cookieDomain` through to `saveSupabaseConfig`.
- **`ollie-fleet/src/client/tabs/supabase-tab-logic.ts`** + **`AccessTab.tsx`** — the form + body-builder + component gain a `cookieDomain` field.
- **`ollie-fleet/src/server/enroll-core.ts`** — `finalizeEnrollment` auto-applies stored Supabase config (guarded, non-fatal).
- Tests: `ollie-hermes-install/tests/test_fleetctl.py`; `ollie-fleet/tests/unit/{supabase-config,supabase-tab-logic,provision}.test.ts`.

---

### Task 1: fleetctl writer writes `SUPABASE_COOKIE_DOMAIN` (#4b, box side)  — repo: `ollie-hermes-install`

**Files:**
- Modify: `templates/bin/ollie-fleetctl` (`set_dashboard_auth_supabase`, ~lines 1124-1140)
- Modify: `tests/test_fleetctl.py` (`TestSetDashboardAuth`)

**Interfaces:**
- Produces (wire contract): the writer now reads `payload["cookie_domain"]` and writes `SUPABASE_COOKIE_DOMAIN` into `~/hermes-stack/.env`, following the same `enabled ? value : ""` rule as `supabase_url`.

- [ ] **Step 1: Write the failing test**

In `tests/test_fleetctl.py`, extend `TestSetDashboardAuth` with a test that sends a supabase payload including `cookie_domain` and asserts the stack `.env` gets `SUPABASE_COOKIE_DOMAIN=<value>` (enabled), and a second assertion that a disabled payload writes `SUPABASE_COOKIE_DOMAIN=` (empty). Follow the existing `test_supabase_mode_writes_both_envs_and_recreates_without_oauth` pattern (stdin `io.StringIO(json.dumps(payload))` + `run_main(self.mod, ["set-dashboard-auth"])`, then read the written stack `.env`). Add `cookie_domain` to that fixture payload too. Concretely:
```python
def test_supabase_mode_writes_cookie_domain(self):
    payload = {
        "mode": "supabase", "enabled": True,
        "supabase_url": "https://x.supabase.co", "anon_key": "anon",
        "service_role_key": "svc", "cookie_domain": ".jnow.io",
    }
    self.mod.sys.stdin = io.StringIO(json.dumps(payload))
    run_main(self.mod, ["set-dashboard-auth"])
    env = read_env(self.stack_env_path)   # use the same stack-.env read helper the class already uses
    self.assertEqual(env.get("SUPABASE_COOKIE_DOMAIN"), ".jnow.io")

def test_supabase_disabled_blanks_cookie_domain(self):
    payload = {"mode": "supabase", "enabled": False}
    self.mod.sys.stdin = io.StringIO(json.dumps(payload))
    run_main(self.mod, ["set-dashboard-auth"])
    env = read_env(self.stack_env_path)
    self.assertEqual(env.get("SUPABASE_COOKIE_DOMAIN"), "")
```
(Match the class's actual fixture/helper names — read `TestSetDashboardAuth`'s `setUp` and the existing supabase test to use the same stack-`.env` path variable and env-reading helper. If the class has no `read_env` helper, read the file and parse the `SUPABASE_COOKIE_DOMAIN=` line the same way the existing test checks its keys.)

- [ ] **Step 2: Run to verify it fails**

Run: `python -m pytest tests/test_fleetctl.py -k cookie_domain -q`
Expected: FAIL — `SUPABASE_COOKIE_DOMAIN` is never written (KeyError/None).

- [ ] **Step 3: Add the writer logic**

In `set_dashboard_auth_supabase` (`templates/bin/ollie-fleetctl`): after the `service_role_key = payload.get(...)` line (~1127), add:
```python
    cookie_domain = payload.get("cookie_domain", "") if enabled else ""
```
Add `"SUPABASE_COOKIE_DOMAIN": cookie_domain,` to the dict passed through the `require_single_line_env` validation loop (~1128-1132). Then, right after the `write_stack_env_key("SUPABASE_ANON_KEY", anon_key)` line (~1140), add:
```python
    write_stack_env_key("SUPABASE_COOKIE_DOMAIN", cookie_domain)
```
Update the function docstring (and `cmd_set_dashboard_auth`'s) to mention `SUPABASE_COOKIE_DOMAIN` alongside URL/anon.

- [ ] **Step 4: Run to verify it passes + full suites**

Run: `python -m pytest tests/test_fleetctl.py -q` → expect all pass (78/78: 76 prior + 2 new).
Run: `bash tests/test-fleetctl-update.sh` → expect 14/14 (unaffected).

- [ ] **Step 5: Commit**

```bash
git add templates/bin/ollie-fleetctl tests/test_fleetctl.py
git commit -m "fix(fleetctl): write SUPABASE_COOKIE_DOMAIN from the supabase payload (#4b)

The cookie domain was a box-only hand-edit (no writer). set-dashboard-auth now
writes SUPABASE_COOKIE_DOMAIN into the stack .env from the payload's cookie_domain,
following the same enabled?value:'' rule as the URL/anon keys.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: `cookie_domain` in Fleet's DB + config model (#4b, server side) — repo: `ollie-fleet`

**Files:**
- Modify: `src/server/db.ts` (idempotent column migration)
- Modify: `src/server/lib/supabase-config.ts` (`SaveSupabaseInput`, `saveSupabaseConfig`, `getSupabaseConfigView`, `buildSupabaseApplyPayload`)
- Modify: `src/server/routes/instance-supabase.ts` (save route passes `cookieDomain`)
- Modify: `tests/unit/supabase-config.test.ts`

**Interfaces:**
- Consumes: Task 1's wire contract (`cookie_domain` in the apply payload).
- Produces: `SaveSupabaseInput` gains `cookieDomain?: string`; `getSupabaseConfigView` returns `cookieDomain`; `buildSupabaseApplyPayload` includes `cookie_domain` in the payload object.

- [ ] **Step 1: Write the failing tests**

In `tests/unit/supabase-config.test.ts`, add tests: (a) `saveSupabaseConfig({...,cookieDomain:'.jnow.io'})` then `getSupabaseConfigView(id)` returns `cookieDomain: '.jnow.io'`; (b) `buildSupabaseApplyPayload(inst)` for an enabled config includes `cookie_domain: '.jnow.io'`. Follow the file's existing in-memory-DB pattern (`setDb(new Database(':memory:'))`).

- [ ] **Step 2: Run to verify it fails**

Run (in `ollie-fleet`): `npx vitest run tests/unit/supabase-config.test.ts`
Expected: FAIL — `cookieDomain`/`cookie_domain` not persisted or returned.

- [ ] **Step 3: Migration + model**

In `src/server/db.ts` `initSchema`, add an idempotent column migration following the existing "Mail columns" `try/catch` pattern (lines ~117-128):
```ts
  for (const stmt of [
    `ALTER TABLE instance_supabase ADD COLUMN cookie_domain TEXT`,
  ]) {
    try { db.exec(stmt) } catch { /* column already exists — safe to ignore */ }
  }
```
In `src/server/lib/supabase-config.ts`:
- Add `cookieDomain?: string` to `SaveSupabaseInput`.
- In `saveSupabaseConfig`: persist `cookie_domain` (trim/normalize like `supabase_url`; it is NOT a secret, store plaintext). Add it to both the INSERT column list and the `ON CONFLICT DO UPDATE` set.
- In `getSupabaseConfigView`: return `cookieDomain` from the row.
- In `buildSupabaseApplyPayload`: add `cookie_domain: row.cookie_domain ?? ''` to the returned payload object.

In `src/server/routes/instance-supabase.ts`: find the save route (the one that calls `saveSupabaseConfig` from the request body) and pass `cookieDomain: body.cookieDomain` through (trace the body → `saveSupabaseConfig` call and thread the field).

- [ ] **Step 4: Run to verify it passes + full suite**

Run: `npx vitest run tests/unit/supabase-config.test.ts` → pass.
Run: `npm test` → full vitest suite green (no regressions).

- [ ] **Step 5: Commit**

```bash
git add src/server/db.ts src/server/lib/supabase-config.ts src/server/routes/instance-supabase.ts tests/unit/supabase-config.test.ts
git commit -m "feat(fleet): make SUPABASE_COOKIE_DOMAIN Fleet-managed (#4b)

Adds an idempotent cookie_domain column to instance_supabase and threads
cookieDomain through the config model + apply payload (as snake_case
cookie_domain on the wire), so the cookie domain is no longer a box hand-edit.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Access-tab UI gains a cookie-domain field (#4b, UI) — repo: `ollie-fleet`

**Files:**
- Modify: `src/client/tabs/supabase-tab-logic.ts` (`SupabaseForm`, `buildSupabaseBody`)
- Modify: `src/client/tabs/AccessTab.tsx` (state + input + `applyView` + `handleSave` + `SupabaseView`)
- Modify: `tests/unit/supabase-tab-logic.test.ts`

**Interfaces:**
- Consumes: Task 2's `getSupabaseConfigView` now returns `cookieDomain`, and the save API accepts `cookieDomain`.

- [ ] **Step 1: Write the failing test**

In `tests/unit/supabase-tab-logic.test.ts`, add a test: `buildSupabaseBody({enabled:true, supabaseUrl:'https://x', anonKey:'a', serviceRoleKey:'', cookieDomain:' .jnow.io '})` returns an object with `cookieDomain: '.jnow.io'` (trimmed). Follow the file's existing `buildSupabaseBody` test style.

- [ ] **Step 2: Run to verify it fails**

Run: `npx vitest run tests/unit/supabase-tab-logic.test.ts`
Expected: FAIL — `cookieDomain` not in the built body.

- [ ] **Step 3: Add the field**

In `src/client/tabs/supabase-tab-logic.ts`: add `cookieDomain: string` to `SupabaseForm`, and in `buildSupabaseBody` add `cookieDomain: form.cookieDomain.trim()` to the returned body (always included, like `supabaseUrl`).
In `src/client/tabs/AccessTab.tsx`: add `const [cookieDomain, setCookieDomain] = useState('')`; add it to the `SupabaseView` type; hydrate it in `applyView`; include it in the `buildSupabaseBody({...})` call in `handleSave`; and add a labeled text input (e.g. `id="supabase-cookie-domain"`, placeholder like `.jnow.io`) right after the Supabase URL input, using the same `labelCls`/`inputCls` pattern. Add a one-line helper caption (e.g. "Cookie domain for shared login across the dashboard hostname — e.g. `.jnow.io`").

- [ ] **Step 4: Run to verify it passes + full suite**

Run: `npx vitest run tests/unit/supabase-tab-logic.test.ts` → pass.
Run: `npm test` → full suite green. (If the repo type-checks in CI, also run `npx tsc --noEmit` and confirm clean.)

- [ ] **Step 5: Commit**

```bash
git add src/client/tabs/supabase-tab-logic.ts src/client/tabs/AccessTab.tsx tests/unit/supabase-tab-logic.test.ts
git commit -m "feat(fleet): Access-tab cookie-domain field (#4b)

Operators can now set the Supabase cookie domain in the UI instead of hand-editing
the box .env; it flows through buildSupabaseBody -> save -> apply payload.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Auto-apply stored Supabase config on enroll (#5) — repo: `ollie-fleet`

**Files:**
- Modify: `src/server/enroll-core.ts` (`finalizeEnrollment` tail)
- Modify: `tests/unit/provision.test.ts` (or a new `enroll` test file following its mock pattern)

**Interfaces:**
- Consumes: `buildSupabaseApplyPayload` + `setDashboardAuth` (importable), `getSupabaseConfigView`.

- [ ] **Step 1: Write the failing test**

Following `tests/unit/provision.test.ts`'s mock pattern (`vi.mock('../../src/server/fleetctl.js', importOriginal → setDashboardAuth: vi.fn())`, in-memory DB), add a test that: seeds an enabled `instance_supabase` row for an instance id, runs the enroll/finalize path for that id, and asserts `setDashboardAuth` was called once with a payload containing `mode:'supabase'` and the seeded `cookie_domain`. Add a second test: with NO stored config, `setDashboardAuth` is NOT called and enrollment still succeeds.

- [ ] **Step 2: Run to verify it fails**

Run: `npx vitest run tests/unit/provision.test.ts` (or your new test file)
Expected: FAIL — `finalizeEnrollment` never calls `setDashboardAuth`.

- [ ] **Step 3: Add the guarded, non-fatal auto-apply**

In `src/server/enroll-core.ts` `finalizeEnrollment`, after the `INSERT INTO instances` + `audit_log` inserts and before `return { instanceId }`, add:
```ts
  // Auto-restore Supabase auth from Fleet's stored config so a rebuild/re-enroll
  // brings the box .env back without a manual re-apply (#5). Non-fatal: never fail
  // enrollment on a Supabase apply error.
  try {
    const sb = getSupabaseConfigView(instanceId)
    if (sb?.enabled) {
      const payload = buildSupabaseApplyPayload({ id: instanceId, name: p.name, frontend_url: p.frontendUrl ?? null })
      await setDashboardAuth(p.target, payload)
    }
  } catch (e) {
    // log and continue — enrollment succeeds regardless of Supabase apply outcome
    console.warn(`[enroll] supabase auto-apply skipped/failed for ${instanceId}: ${(e as Error).message}`)
  }
```
Adjust the exact arg names (`p.name`, `p.frontendUrl`, `p.target`) to `finalizeEnrollment`'s actual param shape — read the function signature. Import `getSupabaseConfigView`/`buildSupabaseApplyPayload` from `./lib/supabase-config.js` and `setDashboardAuth` from `./fleetctl.js`.

- [ ] **Step 4: Run to verify it passes + full suite**

Run: `npx vitest run tests/unit/provision.test.ts` (+ your new file) → pass.
Run: `npm test` → full suite green.

- [ ] **Step 5: Commit**

```bash
git add src/server/enroll-core.ts tests/unit/provision.test.ts
git commit -m "feat(fleet): auto-apply stored Supabase config on enroll (#5)

finalizeEnrollment now re-applies an instance's stored (enabled) Supabase config
after the instance row exists, so a rebuild/re-enroll restores the box's Supabase
auth from Fleet's source of truth. Non-fatal: enrollment never fails on it.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Out of Scope

- **#4a skip-write-when-empty — DROPPED** (John, 2026-07-05): it would break the deliberate-disable workflow. Disable still blanks the keys (correct); S72 durability comes from #5 + Phase 1 preserve instead.

## Self-Review

**1. Spec coverage:** #4b writer → Task 1; #4b model → Task 2; #4b UI → Task 3; #5 → Task 4. #4a dropped (documented). ✓
**2. Placeholders:** exact code for the writer, migration, and auto-apply; the "trace the wiring" instructions (save route field threading in Task 2; `finalizeEnrollment` param names in Task 4) are bounded reads within one file, not hand-waving. ✓
**3. Contract consistency:** wire key is `cookie_domain` (snake) everywhere it crosses the boundary — Task 1 reads `payload["cookie_domain"]`, Task 2's `buildSupabaseApplyPayload` emits `cookie_domain`. Internal TS is `cookieDomain` (camel). ✓
**4. Risk notes:** the migration is idempotent (try/catch ALTER, matching the mail-columns precedent); #5 is guarded + non-fatal (enrollment can't be broken by it); disable semantics unchanged (cookie_domain blanks on disable like the others). Cross-repo: Task 1 lands in `ollie-hermes-install`, Tasks 2-4 in `ollie-fleet` — both local + unpushed.
