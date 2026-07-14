# Instance Title — Design (2026-07-13)

## Problem

Every Ollie deployment shows the same browser tab title ("Ollie") and identical
chrome. With several boxes open at once (sandbox, jnow prod, GetBilled, future
tenants) there is no way to tell the tabs — or the login screens — apart.

## Decision summary (John, 2026-07-13)

- Title is **editable in the Ollie UI**, by **admins only**.
- Displays in **three places**: browser tab title, sidebar header, sign-in card.
- **Approach A**: title stored as `INSTANCE_TITLE` in `~/hermes-stack/.env`,
  served to the browser via `config.js` (`window.__BACKEND__.instanceTitle`),
  written by a new admin-gated orchestrator endpoint that bounces the dashboard
  container — the same pattern agent create/update uses for `AGENTS_JSON`.
  Rejected alternative: an orchestrator-side store with a new unauthenticated
  read endpoint (instant saves, but a deliberate hole in the nginx auth gate,
  a title flash on load, and a second source of per-box config).

## Storage & data flow

```
~/hermes-stack/.env            INSTANCE_TITLE=JNOW Prod        (source of truth)
        │  docker compose (dashboard service env: INSTANCE_TITLE: ${INSTANCE_TITLE:-})
        ▼
generate-config.sh             emits "instanceTitle": env("INSTANCE_TITLE")
        ▼
config.js  →  window.__BACKEND__.instanceTitle                 (public: config.js
        ▼                                                       is already on the
frontend                                                        auth-gate allowlist)
```

- Empty/absent `INSTANCE_TITLE` = feature off; every surface renders exactly as
  today. No migration needed.
- `INSTANCE_TITLE` joins the install repo's preserve list in
  `scripts/lib/stack-env.sh` (+ the golden-key regression test) so `update
  stack` re-renders keep it.
- **Known limitation (accepted):** a full box rebuild loses the title — there is
  no Fleet writer for it. Cosmetic setting; re-set it in the UI after a rebuild.
  A `fleetctl set-title` verb mirroring `set-vertical` is explicitly out of
  scope (YAGNI; add later if Fleet should manage it).

## Orchestrator API

`PUT /v1/instance/title` — body `{"title": "JNOW Prod"}`.

- **Auth:** bearer (like every /v1 route) + the same `authz` admin guard agent
  create/update uses (`authz.admin_denied`).
- **Validation:** single line, trimmed, max 80 chars. Empty string clears the
  title by writing `INSTANCE_TITLE=` (blank value — the key stays present).
  Reject control characters/newlines.
- **Effect:** atomically rewrite the `INSTANCE_TITLE` line in
  `hermes_stack_dir/.env` (same tempfile + `os.replace` pattern as
  `agents_json.py`; new small helper — do NOT widen `write_agent`), holding
  the same `.agents.lock` the agent flows use (shared-file race). The
  dashboard bounce is **deferred until after the response is sent**
  (BackgroundTasks): the PUT transits the dashboard's own nginx, so a
  synchronous bounce would sever the in-flight response and the UI would
  see every real title change as a failure (same trap lifecycle.py documents
  for agent create). Write an audit-log entry (`op="set_instance_title"`,
  `bounce="deferred"`).
- **Response:** `{"ok": true}` after a successful write (validation errors →
  400 `{"ok": false, "error": ...}`). A deferred-bounce failure cannot be
  reported in the response by construction — it is swallowed, logged, and
  audited (`result="error"`); the title persists and applies on the next
  dashboard recreate. *(Amended 2026-07-13 during final review — the original
  "bounce failure → ok:false response" contract was unsatisfiable.)*
- No GET endpoint: the read path is `config.js`.

## Frontend

- `config.ts`: add `instanceTitle?: string` to `BackendConfig` and a safe
  reader `getInstanceTitle(): string` modeled on `getVertical()` (never throws
  on missing key).
- **Tab title:** on boot (App-level effect), `document.title` becomes
  `"<title> — Ollie"` when set, `"Ollie"` otherwise. Title first so it survives
  browser tab truncation. `index.html` keeps `<title>Ollie</title>` as the
  pre-JS fallback.
- **Sidebar (Layout.tsx):** the subtitle line under the agent name becomes
  `Agentic OS · <title>` when set, `Agentic OS` otherwise.
- **Sign-in card:** a small instance-title line under "Sign in to Ollie" when
  set, so tenants are distinguishable pre-auth.
- **Edit UI:** the sidebar subtitle is click-to-edit for admins only — the same
  affordance as the agent-name rename directly above it. Admin = the same
  `useIdentity` tier gate the Users nav item uses (`atLeast(tier,
  'account_admin')`). Save: optimistic update of the subtitle and
  `document.title`, then `PUT /v1/instance/title` via a new
  `OrchestratorClient.setInstanceTitle(title)`. On failure, revert and surface
  the error. The server-side dashboard bounce is invisible to the loaded SPA;
  new page loads pick up the regenerated `config.js`.

## Repos touched

| Repo | Change |
|---|---|
| ollie-hermes-frontend | `config.ts` key + reader; title effect; Layout subtitle + admin edit; sign-in card line; `generate-config.sh` emission; `OrchestratorClient.setInstanceTitle` |
| ollie-hermes-orchestrator | `PUT /v1/instance/title` (new `src/api/instance.py`), env-key writer helper, audit |
| ollie-hermes-install | `templates/docker-compose.yml` dashboard env decl; `INSTANCE_TITLE` in preserve list + golden test |

## Error handling

- Missing/malformed `instanceTitle` in config.js → all surfaces fall back to
  today's generic rendering (reader never throws).
- PUT with non-admin user → 403 from the authz guard; edit control is hidden
  for non-admins anyway (defense in depth).
- Bounce failure after a successful .env write → `{"ok": false}` with error;
  title is durable and applies on the next dashboard recreate.

## Testing

- **Frontend (vitest):** config reader (set/missing/empty), document.title
  effect, Layout subtitle render + admin-gated edit visibility, sign-in card
  line, `generate-config` test extended for INSTANCE_TITLE, OrchestratorClient
  method.
- **Orchestrator (pytest):** admin gate (403 non-admin), validation (length,
  newlines, empty-clears), .env write round-trip (preserves other keys,
  atomic), bounce invoked, audit entry.
- **Install:** golden preserve-list regression includes INSTANCE_TITLE.

## Deploy

Frontend image rebuild + FRONTEND_IMAGE pin bump (install repo), orchestrator
git pull + `systemctl --user restart ollie-orchestrator`, compose template
update on existing boxes (re-run 06 or hand-add the env line + `docker compose
up -d dashboard`). Same playbook as the 2026-07 deploys. Verify per box: set a
title in the UI as admin, confirm tab/sidebar/login on a fresh load, confirm a
non-admin sees no edit control.
