# ollie-hermes-install

Repeatable install scripts for the Ollie + Hermes agent stack.

This repo replaces the hand-rolled steps in `ollie-hermes-frontend/docs/deployment.md` with idempotent, sourceable scripts. The scripts are designed to run **in order** on a fresh Ubuntu 24.04+ Linux host; each one is safe to re-run.

## What you get

A working install of:

- **Hermes Agent** (host-native, multi-profile) — the LLM gateway + dashboard per agent profile
- **Cortex** (Docker) — memory + brain knowledge base
- **Orchestrator** (host-native) — agent management API
- **Ollie dashboard** (Docker) — the React frontend
- **Cortex memory plugin** registered into Hermes so chat turns get extracted into memory

## Prerequisites

- A fresh Linux VM (tested on Ubuntu 24.04+)
- `root` SSH access (or sudo-capable user)
- Outbound HTTPS works (LLM APIs, GitHub, Docker Hub, AgentMail, Telegram)
- ~4GB RAM, 40GB disk (CX23-class)
- Open inbound ports per `docs/firewall.md`

## Quick start (fresh box, run as root)

```bash
# 1. Clone this repo
git clone https://github.com/justnorthow/ollie-hermes-install.git
cd ollie-hermes-install

# 2. Bootstrap: creates the service user (default: ollie), installs Docker + Python + git.
#    Run it as root, OR as any sudo-capable user — it self-elevates via sudo.
#    Options: TARGET_USER=<name> to pick the service user, USE_CURRENT_USER=1
#    to run the stack as yourself, NO_SELF_ELEVATE=1 to disable auto-sudo.
bash scripts/01-bootstrap.sh

# 3. Become the service user for the rest (a fresh login picks up the docker group)
sudo -iu ollie               # or: ssh ollie@<host>
git clone https://github.com/justnorthow/ollie-hermes-install.git
cd ollie-hermes-install

# 4. Install Hermes Agent natively
bash scripts/02-install-hermes.sh

# 5. (Optional) Add additional profiles for extra agents
bash scripts/03-install-profile.sh paige 8643 9121
bash scripts/03-install-profile.sh karl  8644 9122

# 6. Install the cortex memory plugin into Hermes
bash scripts/04-install-cortex-plugin.sh

# 7. Install the orchestrator (agent management API)
bash scripts/05-install-orchestrator.sh

# 8. Install the cortex + frontend Docker stack
bash scripts/06-install-stack.sh

# 9. Patch hermes-agent so cron jobs can use the cortex brain tools.
#    See the script header for the rationale and what it edits.
#    Re-run this after every `hermes update`.
bash scripts/07-patch-cron-brain.sh

# 10. Provision agent personas: seed the default agent's minimal "Ollie" persona
#     + any preset personas for extra profiles. Marker-gated — never overwrites
#     a customized SOUL.md. Re-run after adding a profile.
bash scripts/08-install-souls.sh

# 11. Install the identity-sync helper (ollie-set-identity): lets the agent save
#     its persona + update its dashboard display name in one deterministic step
#     during onboarding. Needs the orchestrator (step 7) for the rename half.
bash scripts/09-install-identity-sync.sh

# 12. (Optional — skip if the box is not managed by Ollie Fleet)
#     Install ollie-fleetctl and the fleet-heartbeat systemd user timer.
#     fleetctl is the verb CLI that the Ollie Fleet dashboard invokes over SSH
#     to manage the box. Available verbs (all emit JSON):
#       health | agents <list|get|create|update|delete|set-identity>
#       restart <target> | logs <service> | update [hermes|stack|orchestrator|all]
#       backup | heartbeat | version
#     The binary lands in ~/.local/bin and is also symlinked to /usr/local/bin.
#     The heartbeat timer fires every 5 minutes but is a no-op until the box is
#     enrolled: enrollment writes ~/.config/ollie-fleet/.env (FLEET_URL + FLEET_TOKEN).
#     Safe to install on un-enrolled boxes. Re-running after `hermes update` is not
#     required (fleetctl lives outside ~/.hermes/hermes-agent), but is always safe.
#     Note: `ollie-fleetctl update hermes` encodes the full post-update runbook
#     (re-runs scripts 04, 07, 08) in one command when fleetctl is installed.
bash scripts/10-install-fleetctl.sh
```

> First-run identity setup (naming the default agent, its personality, mission, etc.)
> is handled by the **dashboard's identity wizard** on first launch — not by an install
> script. The wizard writes the agent's `SOUL.md` and dashboard name via the orchestrator.

Each script prints what it's doing and is idempotent — re-running won't break anything.

## After a `hermes update`

A `hermes update` (run from the CLI or the dashboard's "update gateway") **resets host state to stock** — it re-patches `hermes-agent` internals and reverts the agents' `SOUL.md` persona files to the default Hermes persona. Your customized personas, brain-tool cron patch, etc. are **not** preserved.

**Preferred: one command.** If `ollie-fleetctl` is installed:

```bash
ollie-fleetctl update hermes
```

This git-pulls the install repo and, after `hermes update`, re-applies everything the
update wipes: the Cortex memory plugin (`04-install-cortex-plugin.sh`), the cron
brain-tools patch (`07-patch-cron-brain.sh`), the agent personas
(`08-install-souls.sh`), and the `ollie-set-identity` command allowlist
(`09-install-identity-sync.sh`).

**By hand (no fleetctl):** run the same set, in order:

```bash
cd ~/ollie-hermes-install && git pull
bash scripts/04-install-cortex-plugin.sh
bash scripts/07-patch-cron-brain.sh
bash scripts/08-install-souls.sh
bash scripts/09-install-identity-sync.sh
```

- `08` is marker-aware: it rewrites a host `SOUL.md` only when it's missing or still the stock default, and skips any persona you've since customized on the host. So it restores what the update wiped without clobbering live edits.
- The canonical persona text lives in `templates/souls/{default,karl,paige}.md`. Edit those (and commit) if you want a change to survive future updates; editing only the host copy means the next update reverts it.

> Heads-up: there is **no backup** of host `SOUL.md` — Hermes doesn't log system prompts, and the personas aren't stored in `state.db`. If you customize a persona directly in the dashboard, mirror it back into `templates/souls/` or an update will lose it.

## Layout

```
scripts/    Idempotent install scripts, run in order
templates/  Files copied/expanded by the scripts (systemd units, docker-compose, .env examples)
docs/       Reference docs — architecture, firewall rules, post-install hardening
```

## Source of truth

This repo is the canonical install source. The runbook in `ollie-hermes-frontend/docs/deployment.md` will eventually be replaced by a pointer here.

## License

Internal — JNOW only for now.
