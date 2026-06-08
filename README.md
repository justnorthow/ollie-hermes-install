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
```

Each script prints what it's doing and is idempotent — re-running won't break anything.

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
