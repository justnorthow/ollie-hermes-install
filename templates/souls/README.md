# Agent personas (SOUL.md)

Hermes loads `SOUL.md` from each agent's home and injects it as the agent's
identity **fresh every message** (`~/.hermes/SOUL.md` for the default agent;
`~/.hermes/profiles/<name>/SOUL.md` for a profile). `scripts/08-install-souls.sh`
provisions these from the files here.

## Two kinds of persona

- **`default-onboarding.md`** → the default agent's `SOUL.md`. Its contents are a
  first-run *interview directive*: on first contact the agent (named Ollie by
  default) asks the operator for name, personality, mission, communication style,
  and hard rules, then **overwrites its own `SOUL.md`** with the finalized persona
  and removes the `OLLIE-SOUL-BOOTSTRAP` marker. After that it never re-runs.

- **`<profile>.md`** (e.g. `paige.md`, `karl.md`) → a hand-authored preset for a
  non-default agent. No onboarding — the persona is whatever you write here.

## Marker-gating (why your edits are safe)

`08-install-souls.sh` only writes a target `SOUL.md` when it is **replaceable**:
missing, still the stock Hermes template (effectively empty), or still carrying a
marker (`OLLIE-SOUL-BOOTSTRAP` / `OLLIE-PRESET-SOUL`). A real persona with no
marker is left untouched — so a completed onboarding or a hand-edited host file is
never clobbered.

## Authoring a preset for a new agent

1. Create `templates/souls/<profile-name>.md` (match the profile name used with
   `scripts/03-install-profile.sh`). Keep the `OLLIE-PRESET-SOUL` marker comment
   so `08` can deploy/refresh it; write the real persona as plain prose.
2. Run `scripts/08-install-souls.sh` (after the profile exists). It installs the
   preset to that profile's `SOUL.md`.
3. To stop the repo from managing a host copy, delete the marker line on the host
   file (or just edit the host file directly — removing the marker pins it).
