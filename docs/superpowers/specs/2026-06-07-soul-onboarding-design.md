# First-run SOUL provisioning — default-agent onboarding + preset personas

Status: approved (design) — 2026-06-07
Scope: new `templates/souls/` content + new `scripts/08-install-souls.sh` + a README quick-start line. No changes to `01–07` logic.

## Problem

A fresh Hermes install ships `~/.hermes/SOUL.md` as an empty commented template,
so every agent starts with no defined personality, mission, or working style.
We want:

1. **The default agent ("Ollie")** to **interview the operator on first contact**
   — name, personality, mission, communication style, hard rules — and write the
   answers into its own `SOUL.md`, so it becomes *their* agent.
2. **Other agents (paige, karl, future ones)** to **ship with hand-authored
   personas** (preset `SOUL.md`) — no onboarding.

Hermes already has a built-in first-message onboarding, but it profiles the
**USER** ("tell me about you" → user-profile memory). Ours is the mirror image:
it defines the **AGENT** (→ `SOUL.md`). They are complementary; ours runs first.

## Key facts (verified on the running install, Hermes v0.16.0)

- `agent/prompt_builder.py:load_soul_md()` reads `get_hermes_home() / "SOUL.md"`
  and injects it as agent identity (system-prompt slot #1), **re-read every message**.
- Each profile overrides `HERMES_HOME` to its own dir, so a profile loads
  `~/.hermes/profiles/<name>/SOUL.md`; the default loads `~/.hermes/SOUL.md`.
- The Hermes installer creates `SOUL.md` **only if absent** → a customized
  `SOUL.md` survives `hermes update`.
- Built-in user onboarding: `agent/onboarding.py:profile_build_directive()`,
  gated by `config.onboarding.profile_build` (default `ask`). We leave it on.

## Approach (chosen)

**SOUL.md bootstrap directive — no upstream patch.** The default agent ships a
`SOUL.md` whose *contents are the onboarding directive*. Because `SOUL.md` is
injected into the system prompt every turn, the agent reads "you are Ollie, your
persona isn't set — interview the operator, then rewrite this file" and does so
on first contact. When it writes the finalized persona, the directive (and its
marker) are gone → **self-clearing**, never repeats. Preset agents ship a plain
hand-authored `SOUL.md`.

Rejected: ② patching `agent/onboarding.py` (adds an update-fragile patch like
`07`); ③ a Hermes skill (skills are capability triggers, poor fit for first-run
gating).

## Goals

- Default agent runs the 5-question identity interview once, on first contact,
  and persists the result to its `SOUL.md`.
- Preset agents get vendored personas installed to their per-profile `SOUL.md`.
- Install is idempotent and **never clobbers a completed/customized `SOUL.md`**.
- No upstream patching; survives `hermes update`.

## Non-goals

- Authoring the real paige/karl personas now — they ship as clearly-marked
  starter placeholders for the operator to fill in.
- A bespoke CLI command to re-run onboarding (v1: restoring the bootstrap file
  re-triggers it; the directive also honors "redo your setup" conversationally).
- Unit-testing the LLM conversation itself (covered by a manual smoke test).
- Changing Hermes's built-in user-profile onboarding.

## Design

### Component 1 — vendored content under `templates/souls/`

- **`default-onboarding.md`** — the default agent's bootstrap `SOUL.md`. Contains
  a `<!-- OLLIE-SOUL-BOOTSTRAP v1 ... -->` marker and the first-run directive:
  greet as Ollie (renameable; mention `/help`); ask, conversationally, the five —
  **Name** (Ollie by default, changeable), **Personality** (tone/vibe/quirks),
  **Mission**, **Communication** (brief vs thorough; formats), **Hard rules**
  (always/never); draft a second-person persona and confirm ("does this capture
  it?"); on confirmation OVERWRITE `~/.hermes/SOUL.md` with ONLY the finalized
  persona (removing the setup section + marker). On decline: write a sensible
  default Ollie persona so it won't re-ask. Identity setup precedes any built-in
  "tell me about you" step. (Full text is the approved draft in the design
  discussion; it is the literal file content.)
- **`paige.md`, `karl.md`** — starter presets. Carry an `<!-- OLLIE-PRESET-SOUL -->`
  marker and TODO-marked fields (name/personality/mission/communication/rules)
  for the operator to complete.
- **`README.md`** — short guide: how `SOUL.md` works, the two marker conventions,
  how to author a preset for a future agent, and how marker-gating protects
  customized files.

### Component 2 — `scripts/08-install-souls.sh`

Run as the service user (NOT root), after `02` (default exists) and, if profiles
are used, after `03`. Idempotent and re-runnable.

**"Replaceable" — the shared gate (`soul_is_replaceable`).** A target `SOUL.md`
may be written iff it is one of:
- missing, OR
- carries one of our markers (`OLLIE-SOUL-BOOTSTRAP` / `OLLIE-PRESET-SOUL`), OR
- is **unconfigured stock content**, in either of the two forms Hermes ships:
  1. the *empty comment template* — what `~/.hermes/SOUL.md` holds for the default
     agent: only `#` headers, HTML-comment blocks, and blank lines remain after
     stripping; or
  2. the *stock default-persona prose* that `hermes profile create` writes
     verbatim into a NEW profile's `SOUL.md` ("You are Hermes Agent, an
     intelligent AI assistant created by Nous Research. …"), detected by the
     stable signature `an intelligent AI assistant created by Nous Research`.

A real, customized persona (prose, no marker, not the stock signature) is kept.
Form #2 was discovered during on-box validation — without it, presets would
silently no-op on every freshly-created profile.

**Default agent** → `~/.hermes/SOUL.md`: install `default-onboarding.md` when the
target is replaceable (in practice: the empty template, form #1); otherwise leave
it untouched (a completed onboarding or a hand-edit).

**Preset agents** → for each `~/.hermes/profiles/<name>/`: if
`templates/souls/<name>.md` exists, install it to `<profile>/SOUL.md` when the
target is replaceable (on a fresh profile this is form #2 above). Profiles with
no matching preset are left as-is.

Print a per-target summary (installed / skipped-customized / no-preset).

### Sequencing & self-clearing

- Both our directive (in `SOUL.md`, every turn) and Hermes's user-profile note
  (first message) can appear on message 1; the directive's wording orders them
  ("identity first, then 'tell me about you'"). Soft control — acceptable for v1.
- Self-clearing is entirely directive-driven: once the agent rewrites `SOUL.md`
  (on completion OR decline), the marker is gone, so the runtime onboarding and
  the install gate both stop firing.

## Edge cases

- **Re-run install after onboarding** → marker absent + real content ⇒ skipped,
  not clobbered.
- **Operator declines** → agent writes a default Ollie persona ⇒ no nagging.
- **Operator never finishes (closes chat mid-setup)** → marker remains ⇒ re-offers
  next session. Acceptable.
- **Agent can write the file** → it runs as the service user; `~/.hermes/SOUL.md`
  is in its home and writable via the agent's file tools.
- **Profile with a pre-existing customized `SOUL.md`** → not overwritten by a preset.
- **Fresh profile from `hermes profile create`** → its `SOUL.md` holds Hermes's
  stock default-persona prose (NOT the empty template), so the signature check
  (replaceable form #2) lets the preset install. Discovered during on-box
  validation; handled in `soul_is_replaceable` (commit `cee06d1`).

## Testing

**Automated (on-box, non-LLM), scriptable like the `01` validation:**
1. Fresh default `SOUL.md` (stock template) → `08` installs bootstrap; marker present.
2. Re-run `08` → bootstrap still present (idempotent), not duplicated.
3. Simulate completed onboarding (write a persona without marker) → `08` leaves it untouched.
4. Preset: with `templates/souls/paige.md` present and a `paige` profile → `08`
   installs it to `profiles/paige/SOUL.md`; re-run leaves a customized one untouched.
5. Profile with no matching preset → left as-is.

**Manual (interactive, one-time smoke test):** fresh default chat → confirm Ollie
greets + runs the five-question interview → answer → confirm `~/.hermes/SOUL.md`
is rewritten to the persona with the marker gone. Flagged as manual (LLM behavior).

## Files

- New: `templates/souls/default-onboarding.md`, `templates/souls/paige.md`,
  `templates/souls/karl.md`, `templates/souls/README.md`
- New: `scripts/08-install-souls.sh`
- Edit: `README.md` (add `08` as the final install step)

## Rollout

- Commit on `feat/soul-onboarding`; subagent-driven implementation; merge to master.
- The live box: re-run `08` to seed the default bootstrap + any presets (the
  current default `SOUL.md` is still the stock template, so it's eligible).
