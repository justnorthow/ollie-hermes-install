# Fleet Self-Hosted Supabase Provisioning (Plan 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fleet provisioning deploys the box's own Supabase stack via `11-install-supabase.sh --deploy` and stores the box-emitted creds, instead of requiring the operator to create a hosted project and paste three values.

**Architecture:** A `supabaseMode` field ('self-hosted' default | 'external') threads from the Enroll form → route validation → `startProvision`. Self-hosted mode skips the pasted-creds requirement, derives `SUPABASE_PUBLIC_URL` (`sb-<host>` dash convention) and `SITE_URL` (= frontendUrl) on the form, runs `--deploy` over stdin, reads `ANON_KEY`/`SERVICE_ROLE_KEY` back from `~/supabase-stack/.env`, and persists them via the existing `saveSupabaseConfig`. External mode is byte-identical to today's flow (grandfathered hosted/self-managed projects).

**Tech Stack:** TypeScript (Hono server, React client), vitest, better-sqlite3; code repo is **`D:\workspaces\jnow\ollie-fleet`** (this plan file lives in the install repo beside its spec).

**Spec:** `ollie-hermes-install/docs/superpowers/specs/2026-07-11-self-hosted-supabase-design.md` §Provisioning integration.

**Prerequisite (John gate):** Tasks 1–6 build and test locally against the fleet repo. Task 7 (deploy + acceptance) requires `ollie-hermes-install` master (through `a07706ace860d2b80bed74a1961f23e3389f6629`) **pushed to GitHub** first — boxes clone the install repo by pinned ref. Do not push without John's go.

## Global Constraints

- External mode behavior must be byte-identical to today: same validation errors, same step sequence, same `saveSupabaseConfig` call.
- Service-role material and Google client secret travel ONLY via stdin to the box and are never interpolated into a command string or log line (existing repo rule, `src/server/provision.ts:109`).
- Fleet does NOT store the Google client secret — it is write-only pass-through to the box (`~/supabase-stack/.env` preserves it across re-runs).
- Hostname convention: `sb-<first-label-of-frontend-host>` — single-level dash form (Cloudflare Universal SSL covers one subdomain level only; dotted sub-subdomains fail TLS).
- Self-hosted mode requires `frontendUrl` (it is GoTrue's `SITE_URL`).
- The `--deploy` step gets a 600_000 ms timeout (first run pulls 5 images).
- All fleet suites green before every commit: `npx vitest run` (354+ tests) and `npx tsc --noEmit`.
- Commit to fleet master (local, unpushed until Task 7); conventional-commit messages.

---

### Task 1: Client validation — `supabaseMode` + `deriveSbUrl`

**Files:**
- Modify: `src/client/lib/provision-validate.ts` (17 lines today — full replacement below)
- Test: `tests/unit/provision-form-logic.test.ts` (extend)

**Interfaces:**
- Produces: `ProvisionFields` gains `supabaseMode: string`, `supabasePublicUrl: string`, `frontendUrl: string`, `googleClientId: string`, `googleClientSecret: string` (empty-string defaults; existing three supabase fields stay for external mode). `provisionReady(f)` unchanged signature. New export `deriveSbUrl(frontendUrl: string): string` — `'https://olliesandbox.jnow.io'` → `'https://sb-olliesandbox.jnow.io'`, `''`/unparseable → `''`. Task 5 (Enroll.tsx) consumes both.

- [ ] **Step 1: Write the failing tests** (append to `tests/unit/provision-form-logic.test.ts`, following its existing describe/it style)

```typescript
describe('deriveSbUrl', () => {
  it('prefixes the first host label with sb-', () => {
    expect(deriveSbUrl('https://olliesandbox.jnow.io')).toBe('https://sb-olliesandbox.jnow.io')
    expect(deriveSbUrl('https://ollie.jnow.io')).toBe('https://sb-ollie.jnow.io')
  })
  it('returns empty for empty or unparseable input', () => {
    expect(deriveSbUrl('')).toBe('')
    expect(deriveSbUrl('not a url')).toBe('')
  })
  it('drops port and path from the derivation', () => {
    expect(deriveSbUrl('https://box.jnow.io:3000/chat')).toBe('https://sb-box.jnow.io')
  })
})

describe('provisionReady — self-hosted mode', () => {
  const base = {
    name: 'Box', sshHost: '1.2.3.4', rootKey: 'k',
    supabaseUrl: '', supabaseAnonKey: '', supabaseServiceRoleKey: '',
    accessMode: 'tunnel',
    supabaseMode: 'self-hosted', frontendUrl: 'https://box.jnow.io',
    supabasePublicUrl: 'https://sb-box.jnow.io', googleClientId: '', googleClientSecret: '',
  }
  it('accepts self-hosted with no pasted creds', () => {
    expect(provisionReady(base)).toBeNull()
  })
  it('requires frontendUrl in self-hosted mode', () => {
    expect(provisionReady({ ...base, frontendUrl: '' })).toMatch(/frontend URL/i)
  })
  it('requires a valid https supabasePublicUrl', () => {
    expect(provisionReady({ ...base, supabasePublicUrl: 'http://x' })).toMatch(/https origin/i)
    expect(provisionReady({ ...base, supabasePublicUrl: '' })).toMatch(/https origin/i)
  })
  it('rejects a dotted sub-subdomain public URL', () => {
    expect(provisionReady({ ...base, supabasePublicUrl: 'https://sb.box.jnow.io' }))
      .toMatch(/single-level|dash/i)
  })
  it('google fields must come as a pair', () => {
    expect(provisionReady({ ...base, googleClientId: 'id-only' })).toMatch(/both/i)
    expect(provisionReady({ ...base, googleClientId: 'id', googleClientSecret: 's' })).toBeNull()
  })
  it('external mode still requires the pasted triple', () => {
    expect(provisionReady({ ...base, supabaseMode: 'external' })).toMatch(/all three/i)
  })
})
```

- [ ] **Step 2: Run to verify failure**

Run: `npx vitest run tests/unit/provision-form-logic.test.ts`
Expected: FAIL — `deriveSbUrl` not exported; self-hosted cases return the "all three" error.

- [ ] **Step 3: Replace `src/client/lib/provision-validate.ts`**

```typescript
export type ProvisionFields = {
  name: string; sshHost: string; rootKey?: string; rootPassword?: string
  supabaseUrl: string; supabaseAnonKey: string; supabaseServiceRoleKey: string
  accessMode: string
  supabaseMode: string          // 'self-hosted' | 'external'
  frontendUrl: string
  supabasePublicUrl: string
  googleClientId: string
  googleClientSecret: string
}

const HTTPS_ORIGIN = /^https:\/\/[A-Za-z0-9.-]+(:\d+)?\/?$/

/** sb-<first-label> derivation: https://olliesandbox.jnow.io -> https://sb-olliesandbox.jnow.io.
 *  Single-level dash form — Cloudflare Universal SSL covers one subdomain level only. */
export function deriveSbUrl(frontendUrl: string): string {
  try {
    const host = new URL(frontendUrl.trim()).hostname
    if (!host) return ''
    return `https://sb-${host}`
  } catch { return '' }
}

export function provisionReady(f: ProvisionFields): string | null {
  if (!f.name.trim() || !f.sshHost.trim()) return 'name and SSH host are required'
  if (!f.rootKey?.trim() && !f.rootPassword?.trim()) return 'a root credential is required'
  if (f.accessMode !== 'direct' && f.accessMode !== 'tunnel') return 'choose an access mode'

  if (f.supabaseMode === 'self-hosted') {
    if (!f.frontendUrl.trim()) return 'frontend URL is required in self-hosted mode (it becomes the auth Site URL)'
    const pub = f.supabasePublicUrl.trim()
    if (!HTTPS_ORIGIN.test(pub)) return 'Supabase public URL must be an https origin with no path'
    // sb.<x>.<zone> = two levels under the zone -> Universal SSL cannot cover it.
    if (/^https:\/\/sb\./.test(pub)) return 'use the single-level dash form (sb-<host>), not a dotted sub-subdomain'
    const gid = f.googleClientId.trim(), gsec = f.googleClientSecret.trim()
    if ((gid && !gsec) || (!gid && gsec)) return 'provide both Google client ID and secret, or neither'
    return null
  }

  if (!f.supabaseUrl.trim() || !f.supabaseAnonKey.trim() || !f.supabaseServiceRoleKey.trim())
    return 'all three Supabase values are required — create the project per the runbook first'
  if (!HTTPS_ORIGIN.test(f.supabaseUrl.trim()))
    return 'Supabase URL must be an https origin with no path (hosted <ref>.supabase.co or self-hosted)'
  return null
}
```

- [ ] **Step 4: Run to verify pass**

Run: `npx vitest run tests/unit/provision-form-logic.test.ts`
Expected: all PASS. Then `npx tsc --noEmit` — expect ERRORS in `Enroll.tsx` (missing new fields at the `provisionReady` call site). Add the five new fields to the call with placeholder state values ONLY if tsc fails the commit hook; otherwise leave Enroll.tsx to Task 5. If tsc must pass per repo hooks, extend the Enroll.tsx call minimally: `supabaseMode: 'external', frontendUrl, supabasePublicUrl: '', googleClientId: '', googleClientSecret: ''` (preserves current behavior; Task 5 replaces it).

- [ ] **Step 5: Commit**

```bash
git add src/client/lib/provision-validate.ts tests/unit/provision-form-logic.test.ts src/client/pages/Enroll.tsx
git commit -m "feat(provision): supabaseMode-aware form validation + deriveSbUrl"
```

---

### Task 2: Box-creds read-back parser — `stack-creds.ts`

**Files:**
- Create: `src/server/lib/stack-creds.ts`
- Test: `tests/unit/stack-creds.test.ts`

**Interfaces:**
- Produces: `parseStackCreds(stdout: string): { anonKey: string; serviceRoleKey: string }` — throws `Error('supabase stack .env missing ANON_KEY/SERVICE_ROLE_KEY')` when either is absent/empty. Task 4 consumes it. Also `STACK_CREDS_CMD` — the exact remote command string Task 4 runs: `grep -E '^(ANON_KEY|SERVICE_ROLE_KEY)=' ~/supabase-stack/.env`.

- [ ] **Step 1: Write the failing test** (`tests/unit/stack-creds.test.ts`)

```typescript
import { describe, it, expect } from 'vitest'
import { parseStackCreds, STACK_CREDS_CMD } from '../../src/server/lib/stack-creds.js'

describe('parseStackCreds', () => {
  it('extracts both keys from grep output', () => {
    const out = 'ANON_KEY=eyJh.anon.sig\nSERVICE_ROLE_KEY=eyJh.svc.sig\n'
    expect(parseStackCreds(out)).toEqual({ anonKey: 'eyJh.anon.sig', serviceRoleKey: 'eyJh.svc.sig' })
  })
  it('order-independent and tolerant of CRLF', () => {
    const out = 'SERVICE_ROLE_KEY=svc\r\nANON_KEY=anon\r\n'
    expect(parseStackCreds(out)).toEqual({ anonKey: 'anon', serviceRoleKey: 'svc' })
  })
  it('throws when a key is missing or empty', () => {
    expect(() => parseStackCreds('ANON_KEY=x\n')).toThrow(/SERVICE_ROLE_KEY/)
    expect(() => parseStackCreds('ANON_KEY=\nSERVICE_ROLE_KEY=y\n')).toThrow(/ANON_KEY/)
    expect(() => parseStackCreds('')).toThrow()
  })
  it('command targets the stack env read-only', () => {
    expect(STACK_CREDS_CMD).toBe("grep -E '^(ANON_KEY|SERVICE_ROLE_KEY)=' ~/supabase-stack/.env")
  })
})
```

- [ ] **Step 2: Run to verify failure**

Run: `npx vitest run tests/unit/stack-creds.test.ts`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement `src/server/lib/stack-creds.ts`**

```typescript
/** Read-back of the box-generated Supabase keys after 11-install-supabase.sh --deploy.
 *  The deploy renders ~/supabase-stack/.env (chmod 600, service user); Fleet reads the
 *  two public-ish keys back over SSH to persist them in instance_supabase. */
export const STACK_CREDS_CMD = "grep -E '^(ANON_KEY|SERVICE_ROLE_KEY)=' ~/supabase-stack/.env"

export function parseStackCreds(stdout: string): { anonKey: string; serviceRoleKey: string } {
  const vals: Record<string, string> = {}
  for (const line of stdout.split('\n')) {
    const m = line.trim().match(/^(ANON_KEY|SERVICE_ROLE_KEY)=(.*)$/)
    if (m) vals[m[1]] = m[2].trim()
  }
  if (!vals.ANON_KEY) throw new Error('supabase stack .env missing ANON_KEY — did --deploy succeed?')
  if (!vals.SERVICE_ROLE_KEY) throw new Error('supabase stack .env missing SERVICE_ROLE_KEY — did --deploy succeed?')
  return { anonKey: vals.ANON_KEY, serviceRoleKey: vals.SERVICE_ROLE_KEY }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `npx vitest run tests/unit/stack-creds.test.ts` — all PASS.

- [ ] **Step 5: Commit**

```bash
git add src/server/lib/stack-creds.ts tests/unit/stack-creds.test.ts
git commit -m "feat(provision): stack-creds read-back parser for self-hosted deploy"
```

---

### Task 3: Route — mode-aware validation

**Files:**
- Modify: `src/server/routes/provision.ts` (ProvisionBody type lines 8–24; validation block lines 51–67; startProvision call lines 81–94)
- Test: `tests/unit/provision-route.test.ts` (extend, following its existing request-helper style)

**Interfaces:**
- Consumes: nothing new (route-level only).
- Produces: `ProvisionBody` gains `supabaseMode?: string`, `supabasePublicUrl?: string`, `googleClientId?: string`, `googleClientSecret?: string`. The route passes to `startProvision` a `supabase` union field (see Task 4's `ProvisionArgs`): `{ mode: 'external', url, anonKey, serviceRoleKey }` or `{ mode: 'self-hosted', publicUrl, googleClientId, googleClientSecret }`.

- [ ] **Step 1: Write failing route tests** (append to `tests/unit/provision-route.test.ts`; reuse its existing app/request scaffolding and auth stubbing — read the file's first test for the exact helper names before writing)

```typescript
describe('provision route — supabaseMode', () => {
  it('self-hosted: accepts with no pasted creds when frontendUrl + publicUrl valid', async () => {
    const res = await postProvision({
      ...validBody(), supabaseMode: 'self-hosted',
      supabaseUrl: undefined, supabaseAnonKey: undefined, supabaseServiceRoleKey: undefined,
      frontendUrl: 'https://box.jnow.io', supabasePublicUrl: 'https://sb-box.jnow.io',
    })
    expect(res.status).toBe(202)
  })
  it('self-hosted: 400 without frontendUrl', async () => {
    const res = await postProvision({
      ...validBody(), supabaseMode: 'self-hosted',
      frontendUrl: undefined, supabasePublicUrl: 'https://sb-box.jnow.io',
    })
    expect(res.status).toBe(400)
    expect((await res.json()).error).toMatch(/frontendUrl/i)
  })
  it('self-hosted: 400 on dotted sub-subdomain publicUrl', async () => {
    const res = await postProvision({
      ...validBody(), supabaseMode: 'self-hosted',
      frontendUrl: 'https://box.jnow.io', supabasePublicUrl: 'https://sb.box.jnow.io',
    })
    expect(res.status).toBe(400)
    expect((await res.json()).error).toMatch(/single-level|dash/i)
  })
  it('self-hosted: 400 on google id without secret; multiline secret rejected', async () => {
    const base = { ...validBody(), supabaseMode: 'self-hosted',
      frontendUrl: 'https://box.jnow.io', supabasePublicUrl: 'https://sb-box.jnow.io' }
    expect((await postProvision({ ...base, googleClientId: 'id' })).status).toBe(400)
    expect((await postProvision({ ...base, googleClientId: 'id', googleClientSecret: 'a\nb' })).status).toBe(400)
  })
  it('external (default when supabaseMode omitted): still requires the pasted triple', async () => {
    const res = await postProvision({ ...validBody(), supabaseUrl: undefined })
    expect(res.status).toBe(400)
  })
  it('unknown supabaseMode → 400', async () => {
    const res = await postProvision({ ...validBody(), supabaseMode: 'weird' })
    expect(res.status).toBe(400)
  })
})
```

(`validBody()`/`postProvision()` = whatever the file's existing helpers are named; mirror them exactly. `startProvision` is already mocked in that file — also assert the self-hosted case passes `supabase: { mode: 'self-hosted', publicUrl: 'https://sb-box.jnow.io', googleClientId: '', googleClientSecret: '' }` to the mock.)

- [ ] **Step 2: Run to verify failure**

Run: `npx vitest run tests/unit/provision-route.test.ts` — new tests FAIL.

- [ ] **Step 3: Implement route changes**

In `ProvisionBody`, add:

```typescript
  supabaseMode?: string       // 'self-hosted' | 'external' (default external for back-compat)
  supabasePublicUrl?: string
  googleClientId?: string
  googleClientSecret?: string
```

Replace the Supabase validation block (current lines 51–67) with:

```typescript
  const cookieDomain = body.cookieDomain?.trim() || null
  if (cookieDomain !== null && !/^\S+$/.test(cookieDomain))
    return c.json({ error: 'cookieDomain must be a single-line value' }, 400)
  const accessMode = body.accessMode
  if (accessMode !== 'direct' && accessMode !== 'tunnel')
    return c.json({ error: "accessMode must be 'direct' or 'tunnel'" }, 400)

  const supabaseMode = (body.supabaseMode ?? 'external').trim()
  const HTTPS_ORIGIN = /^https:\/\/[A-Za-z0-9.-]+(:\d+)?\/?$/
  let supabase: ProvisionArgs['supabase']
  if (supabaseMode === 'self-hosted') {
    const frontendUrl = normalizeHttpUrl(body.frontendUrl)
    if (!frontendUrl)
      return c.json({ error: 'frontendUrl is required in self-hosted mode (it becomes the auth Site URL)' }, 400)
    const publicUrl = body.supabasePublicUrl?.trim() ?? ''
    if (!HTTPS_ORIGIN.test(publicUrl))
      return c.json({ error: 'supabasePublicUrl must be an https origin with no path (e.g. https://sb-box.jnow.io)' }, 400)
    // Universal SSL covers one subdomain level — dotted sub-subdomains fail TLS.
    if (/^https:\/\/sb\./.test(publicUrl))
      return c.json({ error: 'use the single-level dash form (sb-<host>), not a dotted sub-subdomain' }, 400)
    const googleClientId = body.googleClientId?.trim() ?? ''
    const googleClientSecret = body.googleClientSecret?.trim() ?? ''
    if ((googleClientId && !googleClientSecret) || (!googleClientId && googleClientSecret))
      return c.json({ error: 'provide both googleClientId and googleClientSecret, or neither' }, 400)
    if (googleClientSecret && !/^\S+$/.test(googleClientSecret))
      return c.json({ error: 'googleClientSecret must be a single-line value' }, 400)
    if (googleClientId && !/^\S+$/.test(googleClientId))
      return c.json({ error: 'googleClientId must be a single-line value' }, 400)
    supabase = { mode: 'self-hosted', publicUrl: publicUrl.replace(/\/$/, ''), googleClientId, googleClientSecret }
  } else if (supabaseMode === 'external') {
    const supabaseUrl = body.supabaseUrl?.trim() ?? ''
    const supabaseAnonKey = body.supabaseAnonKey?.trim() ?? ''
    const supabaseServiceRoleKey = body.supabaseServiceRoleKey?.trim() ?? ''
    if (!supabaseUrl || !supabaseAnonKey || !supabaseServiceRoleKey)
      return c.json({ error: 'supabaseUrl, supabaseAnonKey, and supabaseServiceRoleKey are required — create the project per the runbook first' }, 400)
    if (!HTTPS_ORIGIN.test(supabaseUrl))
      return c.json({ error: 'supabaseUrl must be an https URL with no path (e.g. https://<ref>.supabase.co or https://supabase.example.com:8000)' }, 400)
    if (!/^\S+$/.test(supabaseAnonKey) || !/^\S+$/.test(supabaseServiceRoleKey))
      return c.json({ error: 'supabase keys must be single-line values' }, 400)
    supabase = { mode: 'external', url: supabaseUrl, anonKey: supabaseAnonKey, serviceRoleKey: supabaseServiceRoleKey }
  } else {
    return c.json({ error: "supabaseMode must be 'self-hosted' or 'external'" }, 400)
  }
```

And in the `startProvision({...})` call replace `supabaseUrl, supabaseAnonKey, supabaseServiceRoleKey,` with `supabase,`. Import `type ProvisionArgs` from `../provision.js`. NOTE: this will not typecheck until Task 4 lands the `ProvisionArgs` change — implement Tasks 3 and 4 in the same working session if the repo hooks demand green tsc per commit; otherwise commit Task 3 first with the Task 4 type stub noted. Preferred: land Task 3's route code and Task 4's `ProvisionArgs` type change in Task 3's commit as a minimal type-only stub (`supabase: SupabaseProvision` union added to `ProvisionArgs`, flow still reading only the external branch), with Task 4 completing the flow.

- [ ] **Step 4: Run to verify pass**

Run: `npx vitest run tests/unit/provision-route.test.ts && npx tsc --noEmit` — PASS/clean (with the type stub if needed).

- [ ] **Step 5: Commit**

```bash
git add src/server/routes/provision.ts src/server/provision.ts tests/unit/provision-route.test.ts
git commit -m "feat(provision): supabaseMode route validation (self-hosted | external)"
```

---

### Task 4: Server flow — self-hosted deploy branch in `startProvision`

**Files:**
- Modify: `src/server/provision.ts` (ProvisionArgs lines 10–28; stack-env block lines 90–100; supabase-config block lines 109–112; saveSupabaseConfig block lines 126–134; tunnel-runbook block lines 158–165)
- Test: `tests/unit/provision.test.ts` (extend; it mocks `runCommand` and asserts call sequences — see its `baseArgs()`/`settle()` helpers)

**Interfaces:**
- Consumes: `parseStackCreds`, `STACK_CREDS_CMD` (Task 2); route-provided `supabase` union (Task 3).
- Produces: `ProvisionArgs.supabase: SupabaseProvision` where

```typescript
export type SupabaseProvision =
  | { mode: 'external'; url: string; anonKey: string; serviceRoleKey: string }
  | { mode: 'self-hosted'; publicUrl: string; googleClientId: string; googleClientSecret: string }
```

- [ ] **Step 1: Write failing flow tests** (append to `tests/unit/provision.test.ts`; `selfHostedArgs()` = `baseArgs()` with `frontendUrl: 'https://box.jnow.io'` and `supabase: { mode: 'self-hosted', publicUrl: 'https://sb-box.jnow.io', googleClientId: 'gid', googleClientSecret: 'gsec' }` replacing the three creds fields; update `baseArgs()` itself to `supabase: { mode: 'external', url: 'https://abc.supabase.co', anonKey: 'anon.key.x', serviceRoleKey: 'service.key.x' }`)

```typescript
it('self-hosted: runs 11 --deploy with public/site/google stdin, omits SUPABASE_URL from stack append', async () => {
  // grep read-back must return the box keys when the STACK_CREDS_CMD call happens
  mockRun.mockImplementation(async (_t, cmd) => {
    if (String(cmd).includes("grep -E '^(ANON_KEY|SERVICE_ROLE_KEY)='"))
      return { code: 0, stdout: 'ANON_KEY=box-anon\nSERVICE_ROLE_KEY=box-svc\n', stderr: '' }
    return { code: 0, stdout: '', stderr: '' }
  })
  const opId = startProvision(selfHostedArgs())
  await settle(opId)
  const calls = mockRun.mock.calls.map((c) => String(c[1]))
  const deployCall = mockRun.mock.calls.find((c) => String(c[1]).includes('11-install-supabase.sh --deploy'))
  expect(deployCall).toBeTruthy()
  const stdin = (deployCall![2] as { stdin?: string }).stdin ?? ''
  expect(stdin).toContain('SUPABASE_PUBLIC_URL=https://sb-box.jnow.io\n')
  expect(stdin).toContain('SITE_URL=https://box.jnow.io\n')
  expect(stdin).toContain('GOOGLE_CLIENT_ID=gid\n')
  expect(stdin).toContain('GOOGLE_CLIENT_SECRET=gsec\n')
  // deploy writes SUPABASE_URL/ANON itself — the early stack append must NOT
  const stackAppend = calls.find((c) => c.includes('>> ~/hermes-stack/.env'))
  expect(stackAppend).toBeTruthy()
  expect(stackAppend).not.toContain('SUPABASE_URL=')
  expect(stackAppend).not.toContain('SUPABASE_ANON_KEY=')
  expect(stackAppend).toContain('DASHBOARD_USER=')
  // read-back happened, and the row got the box creds + public URL
  const row = getDb().prepare('SELECT supabase_url, anon_key FROM instance_supabase').get() as
    { supabase_url: string; anon_key: string }
  expect(row.supabase_url).toBe('https://sb-box.jnow.io')
  expect(row.anon_key).toBe('box-anon')
  const op = getOperation(opId)!
  expect(op.status).toBe('succeeded')
})

it('self-hosted: no google creds -> stdin omits GOOGLE_ lines', async () => {
  mockRun.mockImplementation(async (_t, cmd) =>
    String(cmd).includes("grep -E '^(ANON_KEY|SERVICE_ROLE_KEY)='")
      ? { code: 0, stdout: 'ANON_KEY=a\nSERVICE_ROLE_KEY=s\n', stderr: '' }
      : { code: 0, stdout: '', stderr: '' })
  const args = selfHostedArgs()
  args.supabase = { mode: 'self-hosted', publicUrl: 'https://sb-box.jnow.io', googleClientId: '', googleClientSecret: '' }
  const opId = startProvision(args)
  await settle(opId)
  const deployCall = mockRun.mock.calls.find((c) => String(c[1]).includes('--deploy'))!
  const stdin = (deployCall[2] as { stdin?: string }).stdin ?? ''
  expect(stdin).not.toContain('GOOGLE_')
})

it('self-hosted: failed creds read-back fails the operation', async () => {
  mockRun.mockImplementation(async (_t, cmd) =>
    String(cmd).includes("grep -E '^(ANON_KEY|SERVICE_ROLE_KEY)='")
      ? { code: 0, stdout: '', stderr: '' }
      : { code: 0, stdout: '', stderr: '' })
  const opId = startProvision(selfHostedArgs())
  await settle(opId)
  expect(getOperation(opId)!.status).toBe('failed')
})

it('self-hosted tunnel mode: runbook includes the sb- hostname step', async () => {
  mockRun.mockImplementation(async (_t, cmd) =>
    String(cmd).includes("grep -E '^(ANON_KEY|SERVICE_ROLE_KEY)='")
      ? { code: 0, stdout: 'ANON_KEY=a\nSERVICE_ROLE_KEY=s\n', stderr: '' }
      : { code: 0, stdout: '', stderr: '' })
  const args = selfHostedArgs()
  args.accessMode = 'tunnel'
  const opId = startProvision(args)
  await settle(opId)
  const events = getOperation(opId)!.events as Array<Record<string, unknown>>
  const runbook = events.find((e) => e.event === 'tunnel-runbook')!
  expect(JSON.stringify(runbook.steps)).toContain('sb-box.jnow.io')
  expect(JSON.stringify(runbook.steps)).toContain('localhost:8000')
})

it('external mode: flow byte-identical — 11 runs WITHOUT --deploy, stdin carries pasted creds', async () => {
  const opId = startProvision(baseArgs())
  await settle(opId)
  const call11 = mockRun.mock.calls.find((c) => String(c[1]).includes('11-install-supabase.sh'))!
  expect(String(call11[1])).not.toContain('--deploy')
  const stdin = (call11[2] as { stdin?: string }).stdin ?? ''
  expect(stdin).toContain('SUPABASE_URL=https://abc.supabase.co\n')
  expect(stdin).toContain('SUPABASE_SERVICE_ROLE_KEY=service.key.x\n')
})
```

(If `getOperation(...).events` isn't the real accessor for emitted events, read `src/server/operations.ts` for the actual event-buffer accessor and adapt — the assertion target is the `tunnel-runbook` event's `steps` array.)

- [ ] **Step 2: Run to verify failure**

Run: `npx vitest run tests/unit/provision.test.ts` — new tests FAIL (type errors first: update `baseArgs()` to the union shape).

- [ ] **Step 3: Implement the flow**

In `src/server/provision.ts`:

1. Replace the three creds fields in `ProvisionArgs` with `supabase: SupabaseProvision` (export the union type shown above). Import `parseStackCreds`, `STACK_CREDS_CMD` from `./lib/stack-creds.js` and `runCommand` from `./ssh.js`.
2. Stack-env append block (lines 90–100) becomes:

```typescript
    emit({ event: 'progress', step: 'stack-env' })
    const stackAppendLines = [
      `DASHBOARD_USER=${dashboardUser}`,
      `DASHBOARD_PASS=${dashboardPass}`,
      // Self-hosted: 11 --deploy writes SUPABASE_URL/ANON_KEY itself (step 5) and
      // recreates the dashboard; until then the front door is basic-auth-guarded.
      ...(args.supabase.mode === 'external'
        ? [`SUPABASE_URL=${args.supabase.url.replace(/\/$/, '')}`, `SUPABASE_ANON_KEY=${args.supabase.anonKey}`]
        : []),
      ...(args.cookieDomain ? [`SUPABASE_COOKIE_DOMAIN=${args.cookieDomain}`] : []),
      `DASHBOARD_BIND=${args.accessMode === 'direct' ? '0.0.0.0' : '127.0.0.1'}`,
    ].join('\n') + '\n'
```

3. Supabase step (lines 109–112) becomes:

```typescript
    emit({ event: 'progress', step: 'supabase-config' })
    let boxAnonKey = ''
    let boxServiceRoleKey = ''
    if (args.supabase.mode === 'self-hosted') {
      // Secrets travel via stdin only. SITE_URL = the dashboard origin (GoTrue Site URL).
      const g = args.supabase
      const deployStdin =
        `SUPABASE_PUBLIC_URL=${g.publicUrl}\n` +
        `SITE_URL=${args.frontendUrl!.replace(/\/$/, '')}\n` +
        (g.googleClientId ? `GOOGLE_CLIENT_ID=${g.googleClientId}\nGOOGLE_CLIENT_SECRET=${g.googleClientSecret}\n` : '')
      await runStep(svc, script('11-install-supabase.sh --deploy'), '11-install-supabase --deploy', 600_000, deployStdin)
      const creds = await runCommand(svc, STACK_CREDS_CMD, { timeoutMs: 20_000 })
      if (creds.code !== 0) throw new Error(`stack creds read-back failed (exit ${creds.code}): ${creds.stderr.trim().slice(0, 200)}`)
      ;({ anonKey: boxAnonKey, serviceRoleKey: boxServiceRoleKey } = parseStackCreds(creds.stdout))
    } else {
      const supabaseStdin = `SUPABASE_URL=${args.supabase.url.replace(/\/$/, '')}\nSUPABASE_SERVICE_ROLE_KEY=${args.supabase.serviceRoleKey}\n`
      await runStep(svc, script('11-install-supabase.sh'), '11-install-supabase', 180_000, supabaseStdin)
    }
```

4. `saveSupabaseConfig` block (lines 126–134) becomes mode-aware:

```typescript
    try {
      const sb = args.supabase.mode === 'self-hosted'
        ? { enabled: true, supabaseUrl: args.supabase.publicUrl, anonKey: boxAnonKey,
            serviceRoleKey: boxServiceRoleKey, cookieDomain: args.cookieDomain ?? undefined }
        : { enabled: true, supabaseUrl: args.supabase.url, anonKey: args.supabase.anonKey,
            serviceRoleKey: args.supabase.serviceRoleKey, cookieDomain: args.cookieDomain ?? undefined }
      saveSupabaseConfig({ id: instanceId, name: args.name, frontend_url: args.frontendUrl ?? null }, sb)
    } catch (e) { console.warn(`[provision] supabase row save failed: ${(e as Error).message}`) }
```

5. Tunnel-runbook emit (lines 158–165): when `args.supabase.mode === 'self-hosted'`, append two steps to the existing array:

```typescript
        ...(args.supabase.mode === 'self-hosted' ? [
          `Add a cloudflared public hostname ${new URL(args.supabase.publicUrl).hostname} -> http://localhost:8000 (single-level dash form — Universal SSL)`,
          'Add the Google OAuth redirect URI <public-url>/auth/v1/callback in the Google console (if Google sign-in is enabled)',
        ] : []),
```

Also emit the same two steps as a `warning` event in DIRECT mode for self-hosted (direct boxes still need the sb- hostname reachable for browser auth): after the existing direct-mode probe block, add

```typescript
    if (args.supabase.mode === 'self-hosted' && args.accessMode === 'direct') {
      emit({ event: 'warning', message: `self-hosted Supabase: ensure ${new URL(args.supabase.publicUrl).hostname} resolves to this box's Kong (:8000) — browser auth needs it` })
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `npx vitest run tests/unit/provision.test.ts && npx vitest run && npx tsc --noEmit`
Expected: all green (full suite catches any external-mode regression elsewhere).

- [ ] **Step 5: Commit**

```bash
git add src/server/provision.ts tests/unit/provision.test.ts
git commit -m "feat(provision): self-hosted supabase deploy branch — --deploy stdin, creds read-back, runbook steps"
```

---

### Task 5: Enroll form UI — mode toggle + derived public URL

**Files:**
- Modify: `src/client/pages/Enroll.tsx` (state block ~lines 120–137; Supabase form section ~lines 233–241; `provisionReady` call ~line 146; `api.provision` call ~line 153)
- Modify: `src/client/lib/api.ts` (provision body type, ~line 144)
- Test: covered by Task 1's logic tests; UI is mechanical wiring (this repo does not snapshot-test pages).

**Interfaces:**
- Consumes: `deriveSbUrl`, updated `ProvisionFields` (Task 1); route fields (Task 3).

- [ ] **Step 1: Implement the form changes**

State additions (after the existing supabase state, ~line 131):

```typescript
  const [supabaseMode, setSupabaseMode] = useState<'self-hosted' | 'external'>('self-hosted')
  const [supabasePublicUrl, setSupabasePublicUrl] = useState('')
  const [sbUrlTouched, setSbUrlTouched] = useState(false)
  const [googleClientId, setGoogleClientId] = useState('')
  const [googleClientSecret, setGoogleClientSecret] = useState('')
```

Auto-derivation (below the state block):

```typescript
  // Track frontendUrl until the operator edits the sb- URL by hand.
  useEffect(() => {
    if (!sbUrlTouched) setSupabasePublicUrl(deriveSbUrl(frontendUrl))
  }, [frontendUrl, sbUrlTouched])
```

Replace the Supabase form section (current lines ~233–241) with a mode toggle + conditional fields, matching the file's existing `Field`/label markup style:

```tsx
          <div className="flex items-center gap-4">
            <span className="text-sm font-semibold text-foreground">Supabase</span>
            <label className="text-sm"><input type="radio" checked={supabaseMode === 'self-hosted'}
              onChange={() => setSupabaseMode('self-hosted')} /> Self-hosted on the box (default)</label>
            <label className="text-sm"><input type="radio" checked={supabaseMode === 'external'}
              onChange={() => setSupabaseMode('external')} /> External project (paste creds)</label>
          </div>
          {supabaseMode === 'self-hosted' ? (<>
            <Field label="Supabase public URL (sb-<host>, auto-derived from frontend URL)" id="psbpub"
              value={supabasePublicUrl} onChange={(v) => { setSbUrlTouched(true); setSupabasePublicUrl(v) }}
              required placeholder="https://sb-box.jnow.io" />
            <Field label="Google OAuth client ID (optional)" id="pgid" value={googleClientId} onChange={setGoogleClientId} />
            <Field label="Google OAuth client secret (optional)" id="pgsec" value={googleClientSecret}
              onChange={setGoogleClientSecret} type="password" />
          </>) : (<>
            <Field label="Supabase URL" id="psburl" value={supabaseUrl} onChange={setSupabaseUrl} required placeholder="https://abc.supabase.co" />
            <Field label="Supabase anon key" id="psbanon" value={supabaseAnonKey} onChange={setSupabaseAnonKey} required />
            <Field label="Supabase service-role key" id="psbservice" value={supabaseServiceRoleKey} onChange={setSupabaseServiceRoleKey} required type="password" />
          </>)}
```

Update the `provisionReady` call to pass `supabaseMode, frontendUrl, supabasePublicUrl, googleClientId, googleClientSecret`, and the `api.provision` body to include `supabaseMode, supabasePublicUrl: supabasePublicUrl || undefined, googleClientId: googleClientId || undefined, googleClientSecret: googleClientSecret || undefined` (keep the external triple as-is — the route ignores it in self-hosted mode). Extend `api.ts`'s provision body type with the four optional fields.

(Adapt the `Field` component usage to its actual props — read its definition in the file first; if it lacks an `onChange`-with-value signature, follow whatever the existing fields use.)

- [ ] **Step 2: Verify**

Run: `npx tsc --noEmit && npx vitest run`
Expected: clean + all green. Then `npm run build` (vite) — expect a successful client build.

- [ ] **Step 3: Commit**

```bash
git add src/client/pages/Enroll.tsx src/client/lib/api.ts
git commit -m "feat(provision): Enroll form self-hosted mode — derived sb- URL + optional Google creds"
```

---

### Task 6: Docs — runbooks + README cross-links

**Files:**
- Modify: `ollie-hermes-install/docs/runbooks/self-hosted-supabase.md` (add a "Fleet-provisioned boxes" note near the top)
- Modify: `ollie-hermes-install/docs/runbooks/supabase-ollie-core-provisioning.md` (update the pointer paragraph: Fleet's provision form now defaults to self-hosted; this runbook is external-mode only)
- Modify: `ollie-fleet/README.md` (provision section: describe the two Supabase modes, the sb- naming rule, and the post-provision cloudflared/Google runbook steps)

**Interfaces:** none — docs only. Commit each repo's file in its own repo.

- [ ] **Step 1: Write the docs.** Fleet README gets (adapt to its existing section style):

```markdown
### Supabase during provisioning

Provision defaults to **self-hosted** Supabase: the box deploys its own stack
(`11-install-supabase.sh --deploy`), Fleet stores the generated anon/service-role
keys, and the Access tab reflects them. The public hostname MUST be the
single-level dash form `sb-<host>` (e.g. `sb-box.jnow.io`) — Cloudflare Universal
SSL covers only one subdomain level. After provisioning: add the cloudflared
public hostname `sb-<host> -> http://localhost:8000`, and (if Google sign-in is
used) the redirect URI `https://sb-<host>/auth/v1/callback` in the Google console.
The provision output lists both steps. **External** mode preserves the old flow:
create a project per `ollie-hermes-install/docs/runbooks/supabase-ollie-core-provisioning.md`
and paste url/anon/service-role.
```

Install-repo runbook additions: self-hosted-supabase.md gets a two-sentence note that Fleet-provisioned boxes run `--deploy` automatically and only the cloudflared + Google console steps remain manual; the ollie-core provisioning runbook's pointer paragraph gains "Fleet's provision form defaults to self-hosted — this runbook now applies only to external-mode provisions and grandfathered boxes."

- [ ] **Step 2: Commit (both repos)**

```bash
cd /d/workspaces/jnow/ollie-fleet && git add README.md && git commit -m "docs(provision): self-hosted supabase provisioning modes"
cd /d/workspaces/jnow/ollie-hermes-install && git add docs/runbooks/ && git commit -m "docs(supabase): fleet-provision cross-links for self-hosted mode"
```

---

### Task 7: Push, pin bump, fleet-prod deploy, live acceptance — **JOHN GATE**

No new code. Do not start without John's explicit go (pushing publishes the workstream).

- [ ] **Step 1 (John):** approve pushing `ollie-hermes-install` master (`a07706ace860d2b80bed74a1961f23e3389f6629` + Plan 2's docs commit) and `ollie-fleet` master.
- [ ] **Step 2:** push both repos; bump `INSTALL_REPO_REF` in `ollie-fleet/src/server/enroll-core.ts:9` to the pushed install HEAD (full 40-char SHA); run `bash scripts/check-install-pin.sh` (expect OK) and the full fleet suites; commit `chore(pin): bump INSTALL_REPO_REF to install <sha7> (self-hosted supabase)`; push.
- [ ] **Step 3:** deploy fleet-prod (`root@167.233.35.141`): `git pull` + `provision-fleet-hetzner.sh` (idempotent, preserves .env/fleet.db/tunnel — the S75 procedure); verify service active + `https://fleet.jnow.io/health-check` = `{"ok":true}` + the Enroll page shows the Supabase mode toggle.
- [ ] **Step 4 (live acceptance, with John):** wipe + re-provision the GetBilled IONOS box through the new self-hosted flow (this doubles as the still-pending provision-done-done Task 14 acceptance). Success = provision operation completes green; `~/supabase-stack` up on the box; Access tab shows the sb- URL + keys; after John adds the cloudflared sb- hostname + Google redirect, login round-trip works per `self-hosted-supabase.md` §5.
- [ ] **Step 5:** record results in the SDD ledger + OB1.

---

## Self-Review Notes

- **Spec coverage:** deploy-mode provisioning ✓ (T4), Fleet stores box-emitted creds ✓ (T2/T4), form fields optional/derived ✓ (T1/T3/T5), manual create-project step disappears ✓ (T6 docs + default mode), verify/seed/gate reuse ✓ (untouched — seed + gate steps already probe the orch env, which `--deploy` writes with the loopback URL).
- **Type consistency check:** `SupabaseProvision` union defined in T4, consumed by T3 (route) and T4 tests; `deriveSbUrl`/`ProvisionFields` (T1) consumed by T5; `parseStackCreds`/`STACK_CREDS_CMD` (T2) consumed by T4. Names match across tasks.
- **Known cross-commit typecheck coupling:** T3's route references `ProvisionArgs['supabase']` before T4 completes the flow — T3 Step 3 carries the resolution (type stub lands with T3).
- **Deliberate scope-outs:** no Fleet-managed cloudflared automation (manual runbook step, as today for dashboards); Google creds not stored in Fleet DB (box `.env` is the durable home); Plan 3 (data migrations/cutover) untouched.
