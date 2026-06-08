# First-Run Identity Onboarding via Hermes Native Injection — Design

**Date:** 2026-06-08
**Status:** Approved (direction + gate decided 2026-06-08)
**Supersedes the delivery mechanism of:** `2026-06-07-soul-onboarding-design.md` (the
interview *content* and `ollie-set-identity` save path are unchanged; only *how the
interview directive reaches the agent* changes).

## Problem

The first-run identity interview (default agent asks the operator for its name,
personality, mission, communication style, and hard rules, then writes `SOUL.md`
via `ollie-set-identity`) was delivered by seeding the directive **into
`~/.hermes/SOUL.md`**. Hermes injects `SOUL.md` into the system prompt on **every
message**. So on every turn the model re-reads "FIRST-RUN SETUP: ask these 5
questions" and intermittently anchors on it and **restarts the interview** — re-asking
the name, reverting the chosen name, looping. Six successive directive rewrites
(v1–v6) only reduced the restart frequency; they could not eliminate it, because the
mechanism re-asserts the setup instruction every turn. This is an architectural
problem, not a wording problem.

Evidence (live, on-box): with the frontend session-continuity fix in place (so the
agent has full conversation history), v6 progressed name → personality → mission, then
restarted to question 1 on the 4th message. The restart tracks the per-message
re-injection, not the conversation state.

## Root Cause (verified in hermes-agent source, v0.16.0)

`gateway/run.py:9447` injects onboarding directives **exactly once, on the very first
message of a fresh install**:

```python
# First-message onboarding -- only on the very first interaction ever
if not history and not self.session_store.has_any_sessions():
    ...
    if profile_build_mode(_onb_cfg) == "ask" and not is_seen(_onb_cfg, PROFILE_BUILD_FLAG):
        context_prompt += profile_build_directive()      # injected ONCE
        mark_seen(_hermes_home / "config.yaml", PROFILE_BUILD_FLAG)
    else:
        context_prompt += _intro_note
```

`profile_build_directive()` (in `agent/onboarding.py`) returns Hermes's built-in
*user-profile* onboarding note. Because the block is gated by `not history`, the
directive is present for message 1 only; messages 2…N proceed as a **normal
conversation off history**, with nothing re-asserting "start setup." That is exactly
the property the SOUL.md approach lacks. The fix is to deliver **our** identity
interview through **this same once-only channel** instead of through `SOUL.md`.

## Decision

- **Gate:** Once-ever (Hermes-native). Onboarding fires on the first message of a
  brand-new install. If the operator abandons mid-interview, identity stays the
  default; the directive instructs the agent that **declining still saves a sensible
  default** via `ollie-set-identity`, so on first contact the loop terminates with an
  identity set in nearly all cases.
- **Patch surface:** `agent/onboarding.py` **only**. No edits to the 20,000-line
  `gateway/run.py`. We override `profile_build_directive()` so the existing call site
  injects our text.
- **Application method:** **append a marker-guarded re-definition** at the end of
  `onboarding.py`. Python binds the module name to the last definition, and the call
  site's `from agent.onboarding import profile_build_directive` picks up ours. This is
  append-only, line-number-independent, idempotent (skip if marker present), and
  trivially re-applied after `hermes update` wipes it — the same maintenance model as
  `07-patch-cron-brain.sh`.

## Architecture

Three cooperating pieces, all vendored in the install repo:

### 1. The directive text — `templates/onboarding/profile-build-directive.md`

Plain prose (no Python), installed to `~/.hermes/ollie-onboarding-directive.txt`. It is
the v6 interview **simplified**: the anti-restart scaffolding ("read the conversation,
continue from where you are, never re-ask") is **removed** — it is unnecessary once the
directive is injected only once. What remains:

- A one-line self-introduction as "Ollie" (placeholder default name).
- Five questions, asked **one at a time**, in order, each with an example:
  name → personality → mission → communication style → hard rules.
- Save phase: compose the finalized persona as second-person prose, write it to a temp
  file, then run exactly one command —
  `ollie-set-identity --name "<chosen name>" --soul-file <temp>` — which writes
  `SOUL.md` **and** updates the dashboard label (orchestrator `PATCH`).
- Decline path: write a sensible default persona (named with whatever they gave, or
  "Ollie") and run `ollie-set-identity` so identity is always established.

Decoupling the text into a file means editing the interview never requires re-patching
Python — replace the `.txt` and restart the gateway.

### 2. The code patch — appended to `agent/onboarding.py`

```python
# >>> OLLIE-IDENTITY-ONBOARDING (idempotent; re-applied after hermes update) >>>
import os as _ollie_os
_ollie_orig_profile_build_directive = profile_build_directive
def profile_build_directive() -> str:
    """Override: deliver the Ollie identity interview on first contact.

    Falls back to Hermes's built-in user-profile onboarding when this gateway's
    agent already carries a real (non-default) persona, or when the directive
    file is missing — so preset agents (paige/karl) and customized agents are
    never interrogated for an identity they already have.
    """
    home = _ollie_os.environ.get("HERMES_HOME") or _ollie_os.path.expanduser("~/.hermes")
    soul_path = _ollie_os.path.join(home, "SOUL.md")
    try:
        with open(soul_path, encoding="utf-8") as _f:
            _soul = _f.read()
        # A real, personalized persona (no OLLIE-SOUL-DEFAULT marker, non-empty)
        # means this agent already has an identity — use the stock user-profile flow.
        if _soul.strip() and "OLLIE-SOUL-DEFAULT" not in _soul:
            return _ollie_orig_profile_build_directive()
    except FileNotFoundError:
        pass
    try:
        _p = _ollie_os.path.join(home, "ollie-onboarding-directive.txt")
        with open(_p, encoding="utf-8") as _f:
            return "\n\n" + _f.read().strip()
    except Exception:
        return _ollie_orig_profile_build_directive()
# <<< OLLIE-IDENTITY-ONBOARDING <<<
```

Why this is safe:
- **Preset/customized agents fall through** to Hermes's own onboarding (the persona
  marker check), so paige/karl are never asked "what's my name."
- **Missing directive file falls through** to stock behavior — never an empty prompt.
- The original function is captured (`_ollie_orig_…`) before shadowing, so the
  fallback is the genuine upstream directive.

### 3. The installer — `scripts/10-patch-onboarding.sh`

Mirrors `07-patch-cron-brain.sh`:
1. Refuse to run as root; require `~/.hermes/hermes-agent/agent/onboarding.py`.
2. Copy `templates/onboarding/profile-build-directive.md` →
   `~/.hermes/ollie-onboarding-directive.txt`.
3. If `onboarding.py` lacks the `OLLIE-IDENTITY-ONBOARDING` marker, back it up
   (`.bak.onboard`) and append the override block; else report already-applied.
4. Restart all `hermes-gateway*` user units so the override loads.
5. Print a verification hint.

### 4. Default persona — `templates/souls/default.md` (replaces `default-onboarding.md`)

The default agent's `SOUL.md` becomes a **minimal persona stub**, not an interview
directive:

```markdown
# Ollie — Agent Persona

<!-- OLLIE-SOUL-DEFAULT — minimal starter persona; replaced when identity setup completes. -->

You are **Ollie**, this operator's personal agent. Your personality and mission
aren't fully defined yet — you'll learn them directly from the operator and then
update this file. Until then: be helpful, be honest, and keep a light, friendly tone.
```

- Marker `OLLIE-SOUL-DEFAULT` lets `08` recognize it as replaceable and lets the
  onboarding override recognize "still default → run the interview."
- It gives a clean first impression ("I'm Ollie") without any setup mechanics in the
  every-message system prompt.
- `ollie-set-identity` overwrites it with the operator's chosen persona (no marker →
  preserved thereafter).

### 5. `scripts/08-install-souls.sh` change

- Install `templates/souls/default.md` (was `default-onboarding.md`) to
  `~/.hermes/SOUL.md`.
- `soul_is_replaceable()` recognizes the new `OLLIE-SOUL-DEFAULT` marker (add it to the
  existing `OLLIE-SOUL-BOOTSTRAP|OLLIE-PRESET-SOUL` grep alternation; keep the old
  marker so any box already seeded with a v1–v6 bootstrap is still treated as
  replaceable and gets upgraded to the minimal stub on re-run).
- Update the closing message (no longer "interviews you … then rewrites the file" via
  SOUL.md; onboarding now runs through the gateway patch).

## Data Flow (fresh install, happy path)

1. Operator runs `01…10`. `08` seeds minimal `SOUL.md` (Ollie stub). `10` installs the
   directive file + patches `onboarding.py` + restarts gateway.
2. Operator opens the dashboard, sends the first message ever.
3. `run.py` sees `not history and not has_any_sessions()`, `profile_build_mode == ask`,
   flag unseen → appends `profile_build_directive()` (now our interview) to message 1's
   context → marks the flag seen.
4. The agent runs the 5-question interview across messages 2…6, **off conversation
   history**, with no re-injection → no restart.
5. The agent writes the persona to a temp file and runs `ollie-set-identity` → `SOUL.md`
   rewritten with the chosen persona (no marker), dashboard label PATCHed to the chosen
   name. Subsequent turns use the new persona; onboarding never fires again.

## Testing

- **Unit (pytest, in hermes-agent):** not added to the upstream tree (we don't own its
  test suite); instead the installer verifies idempotency and the override is exercised
  on-box.
- **On-box validation (simulate a fresh install):**
  1. Stop gateway; clear sessions (`session_store` / `state.db` messages) and unset
     `onboarding.seen.profile_build_offered` in `~/.hermes/config.yaml`; reset
     `SOUL.md` to the minimal stub. Restart gateway.
  2. From the dashboard, run the full interview in one chat. Assert: progresses through
     all five questions **without restarting or re-asking the name**; keeps the chosen
     name; finishes by running `ollie-set-identity`; dashboard label auto-updates.
  3. Re-run `10-patch-onboarding.sh` → reports already-applied (idempotent).
  4. Confirm a preset profile gateway (paige) does **not** trigger the identity
     interview (persona marker fall-through).

## Out of Scope (YAGNI)

- Re-offer-until-set gating (rejected: would require patching `run.py`).
- Preserving Hermes's user-profile onboarding *in addition to* identity onboarding on
  the same first message (the override replaces it on the default agent; preset agents
  still get it via fall-through). A future "after identity, offer to learn about you"
  hand-off can live in the directive text if wanted later.
- Frontend changes (the session-continuity fix that makes history reliable is already
  deployed and is a prerequisite, not part of this work).

## Files

- Create: `templates/onboarding/profile-build-directive.md`
- Create: `templates/souls/default.md`
- Create: `scripts/10-patch-onboarding.sh`
- Delete: `templates/souls/default-onboarding.md`
- Modify: `scripts/08-install-souls.sh` (default source filename + marker + message)
- Modify: `README.md` (add step 10)
- Patched on-box (not in repo): `~/.hermes/hermes-agent/agent/onboarding.py`
