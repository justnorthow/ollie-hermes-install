# 01-bootstrap Privilege + Portable Service User — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `01-bootstrap.sh` work whether run as root or a sudo-capable user, default to a distro-neutral service user (`ollie`), and never lock the operator out of that user.

**Architecture:** A single bash script does a privileged system bootstrap. We add a self-elevation entry guard, configurable/operator-aware user creation, and a merge-don't-clobber SSH key seed. The rest of the stack already derives paths from `$HOME`, so only cosmetic edits ripple to scripts 02–07 and docs.

**Tech Stack:** Bash, systemd (`loginctl`, `--user` services), apt, Docker. No unit-test framework — validation is integration scenarios run on the live box (with a root SSH fallback) using throwaway users.

**TDD note:** This is a system-mutating shell script; there is no in-repo unit harness. "Tests" = the on-box scenario matrix in Task 4, each with exact commands and expected output. The live box runs the `ubuntu` stack, so we validate **01 in isolation** (user/keys/privilege mechanics) and never run a parallel `ollie` stack (port collisions). All throwaway artifacts are removed in Task 4 Step 7.

**Spec:** `docs/superpowers/specs/2026-06-07-01-bootstrap-privilege-portable-user-design.md`

---

### Task 1: Rewrite `scripts/01-bootstrap.sh`

**Files:**
- Modify (full rewrite): `scripts/01-bootstrap.sh`

- [ ] **Step 1: Replace the entire file with the new implementation**

```bash
#!/usr/bin/env bash
# 01-bootstrap.sh — prepare a fresh Linux host for the Ollie + Hermes stack.
#
# Run as: root, OR any sudo-capable user (the script self-elevates via sudo).
# Idempotent: safe to re-run.
#
# What it does:
#   1. Ensures root privileges (self-elevates via sudo if needed)
#   2. Creates a dedicated service user (default: ollie) with passwordless sudo
#   3. Seeds that user's SSH authorized_keys from whoever ran the install
#      (operator -> root -> existing, deduped) so you never lose access to it
#   4. Enables systemd linger so user services survive logout / reboot
#   5. Installs prereqs: docker, compose plugin, python3, git, jq, sqlite3, etc.
#   6. Adds the service user to the docker group
#
# The whole stack derives paths from $HOME (Hermes profile dirs, systemd %h unit
# templates, orchestrator src/config.py), so the service-user name is freely
# configurable — it does NOT have to be "ubuntu".
#
# Config (all optional env vars):
#   TARGET_USER=ollie     # service user to create/use
#   USE_CURRENT_USER=1    # use the invoking sudo user instead of a dedicated one
#   NO_SELF_ELEVATE=1     # don't auto-sudo; just instruct and exit if not root
#
# Invoke as a file (needed for self-elevation): bash scripts/01-bootstrap.sh
# After this script: ssh <service-user>@<host> (or `sudo -iu <service-user>`)
# then run 02-install-hermes.sh

set -euo pipefail

DEFAULT_USER="ollie"
TARGET_USER="${TARGET_USER:-${DEFAULT_USER}}"

# Resolve the operator (the human who launched this) BEFORE any elevation:
# explicit OLLIE_OPERATOR (preserved across our sudo re-exec) -> SUDO_USER
# (set when invoked via sudo) -> current login name.
OPERATOR="${OLLIE_OPERATOR:-${SUDO_USER:-$(id -un)}}"

# --- Privilege guard: be root, or self-elevate via sudo ---
if [[ "$(id -u)" -ne 0 ]]; then
  if [[ "${NO_SELF_ELEVATE:-0}" == "1" ]]; then
    echo "error: must run as root. Re-run with:  sudo bash $0" >&2
    exit 1
  fi
  if command -v sudo >/dev/null 2>&1 && sudo -v; then
    echo "==> not root — re-executing under sudo (operator: ${OPERATOR})"
    exec sudo OLLIE_OPERATOR="${OPERATOR}" NO_SELF_ELEVATE=1 \
         TARGET_USER="${TARGET_USER}" USE_CURRENT_USER="${USE_CURRENT_USER:-}" \
         bash "$0" "$@"
  fi
  echo "error: this script needs root, but you are '${OPERATOR}' without usable sudo." >&2
  echo "       Log in as root and re-run, or have an admin grant you sudo, then:" >&2
  echo "       sudo bash $0" >&2
  exit 1
fi

# --- uid 0 from here down; OPERATOR names the human who launched it ---

if [[ "${USE_CURRENT_USER:-0}" == "1" ]]; then
  if [[ "${OPERATOR}" == "root" || -z "${OPERATOR}" ]]; then
    echo "error: USE_CURRENT_USER=1 but operator is root — set TARGET_USER instead." >&2
    exit 1
  fi
  TARGET_USER="${OPERATOR}"
fi

USER_PREEXISTING=false
if id -u "${TARGET_USER}" >/dev/null 2>&1; then
  USER_PREEXISTING=true
fi
echo "==> service user: ${TARGET_USER} (operator: ${OPERATOR}, pre-existing: ${USER_PREEXISTING})"

echo "==> ensuring ${TARGET_USER} exists with sudo + docker group ready"
if [[ "${USER_PREEXISTING}" == "false" ]]; then
  useradd -m -s /bin/bash "${TARGET_USER}"
fi
usermod -aG sudo "${TARGET_USER}"

echo "==> granting passwordless sudo to ${TARGET_USER} (needed for unattended 02-07)"
if [[ "${USER_PREEXISTING}" == "true" && "${TARGET_USER}" != "${DEFAULT_USER}" ]]; then
  echo "    WARNING: ${TARGET_USER} is a pre-existing account; this grants it passwordless" >&2
  echo "             sudo. Review /etc/sudoers.d/${TARGET_USER} afterward if undesired." >&2
fi
echo "${TARGET_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${TARGET_USER}"
chmod 0440 "/etc/sudoers.d/${TARGET_USER}"

echo "==> seeding ${TARGET_USER} authorized_keys from operator -> root -> existing (deduped)"
USER_HOME="$(getent passwd "${TARGET_USER}" | cut -d: -f6)"
USER_AK="${USER_HOME}/.ssh/authorized_keys"
mkdir -p "${USER_HOME}/.ssh"
touch "${USER_AK}"
if [[ "${OPERATOR}" == "root" ]]; then
  OP_AK="/root/.ssh/authorized_keys"
else
  OP_AK="$(getent passwd "${OPERATOR}" | cut -d: -f6)/.ssh/authorized_keys"
fi
# Merge, never overwrite: a plain cp could clobber a key added directly to the
# service account and lock you out on re-run. Order-preserving, blank+dup safe.
{
  [[ -f "${OP_AK}" ]] && cat "${OP_AK}"
  [[ -f /root/.ssh/authorized_keys ]] && cat /root/.ssh/authorized_keys
  cat "${USER_AK}"
} 2>/dev/null | awk 'NF && !seen[$0]++' > "${USER_AK}.tmp"
mv "${USER_AK}.tmp" "${USER_AK}"
chown -R "${TARGET_USER}:$(id -gn "${TARGET_USER}")" "${USER_HOME}/.ssh"
chmod 700 "${USER_HOME}/.ssh"
chmod 600 "${USER_AK}"
if [[ ! -s "${USER_AK}" ]]; then
  echo "    WARNING: no SSH keys found for operator or root — ${TARGET_USER} has NO" >&2
  echo "             authorized_keys. Add one, or use 'sudo -iu ${TARGET_USER}'." >&2
fi

echo "==> enabling systemd --user linger for ${TARGET_USER} (services survive logout)"
loginctl enable-linger "${TARGET_USER}"

echo "==> apt update + base prereqs"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
  ca-certificates curl gnupg lsb-release \
  git python3 python3-venv python3-pip \
  jq sqlite3 sed tar rsync openssh-client \
  >/dev/null

echo "==> installing Docker CE + Compose plugin"
install -m 0755 -d /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null
  chmod a+r /etc/apt/keyrings/docker.gpg
fi
ARCH="$(dpkg --print-architecture)"
CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -qq
apt-get install -y -qq \
  docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin \
  >/dev/null

echo "==> adding ${TARGET_USER} to docker group"
usermod -aG docker "${TARGET_USER}"

echo
echo "==> verification"
sudo -u "${TARGET_USER}" id
docker --version
docker compose version
python3 --version
git --version

echo
echo "✓ bootstrap complete."
echo
echo "  service user : ${TARGET_USER}"
echo "  reach it     : ssh ${TARGET_USER}@<host>   (or: sudo -iu ${TARGET_USER})"
echo "  NOTE: docker-group membership needs a FRESH login before step 06."
echo "next: become ${TARGET_USER} and run scripts/02-install-hermes.sh"
```

- [ ] **Step 2: Syntax-check the script**

Run: `bash -n scripts/01-bootstrap.sh`
Expected: no output, exit 0. (If `shellcheck` is available: `shellcheck scripts/01-bootstrap.sh` — warnings acceptable, no parse errors.)

- [ ] **Step 3: Commit**

```bash
git add scripts/01-bootstrap.sh
git commit -m "feat(01): self-elevation + portable service user (ollie) + operator-aware key seed"
```

---

### Task 2: Genericize service-user references in `scripts/02–07`

These are comments/messages only — the real guards are `id -u==0` and `$HOME`. Change wording so they don't imply the user must be named `ubuntu`.

**Files:**
- Modify: `scripts/02-install-hermes.sh`, `03-install-profile.sh`, `04-install-cortex-plugin.sh`, `05-install-orchestrator.sh`, `06-install-stack.sh`, `07-patch-cron-brain.sh`

- [ ] **Step 1: Apply these exact replacements**

`02-install-hermes.sh`:
- `# Run as: ubuntu (NOT root) — Hermes installs to $HOME/.hermes`
  → `# Run as: the service user (ollie by default; NOT root) — Hermes installs to $HOME/.hermes`
- `  echo "error: run as the ubuntu user, not root (Hermes installs to \$HOME/.hermes)" >&2`
  → `  echo "error: run as the service user, not root (Hermes installs to \$HOME/.hermes)" >&2`

`03-install-profile.sh`:
- `# Run as: ubuntu` → `# Run as: the service user (ollie by default)`
- `  echo "error: run as the ubuntu user, not root" >&2`
  → `  echo "error: run as the service user, not root" >&2`

`04-install-cortex-plugin.sh`:
- `# Run as: ubuntu` → `# Run as: the service user (ollie by default)`
- `  echo "error: run as the ubuntu user, not root" >&2`
  → `  echo "error: run as the service user, not root" >&2`

`05-install-orchestrator.sh`:
- `# Run as: ubuntu` → `# Run as: the service user (ollie by default)`
- `  echo "error: run as the ubuntu user, not root" >&2`
  → `  echo "error: run as the service user, not root" >&2`

`06-install-stack.sh`:
- `# Run as: ubuntu (in the `docker` group)` → `# Run as: the service user (ollie by default; in the `docker` group)`
- `  echo "error: run as the ubuntu user, not root" >&2`
  → `  echo "error: run as the service user, not root" >&2`
- `  echo "error: ubuntu user not in docker group — log out and back in after running 01-bootstrap.sh" >&2`
  → `  echo "error: service user not in docker group — log out and back in after running 01-bootstrap.sh" >&2`

`07-patch-cron-brain.sh`:
- `# Run as: ubuntu (NOT root) — patches files under ~/.hermes/hermes-agent`
  → `# Run as: the service user (ollie by default; NOT root) — patches files under ~/.hermes/hermes-agent`
- `  echo "error: run as the ubuntu user, not root" >&2`
  → `  echo "error: run as the service user, not root" >&2`

- [ ] **Step 2: Syntax-check all touched scripts**

Run: `for f in scripts/0[2-7]*.sh; do bash -n "$f" && echo "ok $f"; done`
Expected: `ok scripts/02-...` … `ok scripts/07-...` (all ok, exit 0).

- [ ] **Step 3: Commit**

```bash
git add scripts/02-install-hermes.sh scripts/03-install-profile.sh scripts/04-install-cortex-plugin.sh scripts/05-install-orchestrator.sh scripts/06-install-stack.sh scripts/07-patch-cron-brain.sh
git commit -m "chore(02-07): genericize 'ubuntu user' wording to 'service user'"
```

---

### Task 3: Update `README.md` and `docs/migration-notes.md`

**Files:**
- Modify: `README.md` (quick-start block, ~lines 25–61)
- Modify: `docs/migration-notes.md` (add a one-line note)

- [ ] **Step 1: Update README quick-start**

Replace the steps that reference the `ubuntu` user. The block currently reads:

```bash
# 2. Bootstrap: create ubuntu user, install Docker + Python + git
bash scripts/01-bootstrap.sh

# 3. Switch to the ubuntu user for the rest
su - ubuntu
cd ~/ollie-hermes-install   # we'll re-clone here so ubuntu owns it
git clone https://github.com/justnorthow/ollie-hermes-install.git
cd ollie-hermes-install
```

Replace with:

```bash
# 2. Bootstrap: creates the service user (default: ollie), installs Docker + Python + git.
#    Run it as root, OR as any sudo-capable user — it self-elevates via sudo.
#    Options: TARGET_USER=<name> to pick the service user, USE_CURRENT_USER=1
#    to run the stack as yourself, NO_SELF_ELEVATE=1 to disable auto-sudo.
bash scripts/01-bootstrap.sh

# 3. Become the service user for the rest (re-login picks up the docker group)
sudo -iu ollie               # or: ssh ollie@<host>
git clone https://github.com/justnorthow/ollie-hermes-install.git
cd ollie-hermes-install
```

Also update the prose line under "What you get"/prereqs that says steps run as `ubuntu`: change any "run as the ubuntu user" to "run as the service user (`ollie` by default)". (Search README for `ubuntu` and update human-facing references; leave the `download.docker.com/linux/ubuntu` URL and OS-name mentions alone.)

- [ ] **Step 2: Add a note to migration-notes**

After the first heading in `docs/migration-notes.md`, add:

```markdown
> Note: new installs default the service user to **`ollie`** (configurable via
> `TARGET_USER`). The commands below target boxes provisioned with the older
> `ubuntu` service user — substitute your service-user name as needed.
```

Leave the existing `ubuntu@<IP>` operational commands intact (they document a real past migration).

- [ ] **Step 3: Commit**

```bash
git add README.md docs/migration-notes.md
git commit -m "docs: service user is now 'ollie' (configurable); document 01 run modes"
```

---

### Task 4: Validate on the box (01 in isolation) + clean up

Run from the Windows control machine. Helper for clean script transfer (BOM/CRLF-safe), reused from this session:

```powershell
function Send-And-Run { param([string]$LocalSh,[string]$RemoteName)
  $txt=[System.IO.File]::ReadAllText($LocalSh).Replace("`r","").TrimStart([char]0xFEFF)
  $tmp=[System.IO.Path]::Combine($env:TEMP,"clean_$RemoteName")
  [System.IO.File]::WriteAllText($tmp,$txt,(New-Object System.Text.UTF8Encoding($false)))
  scp -q $tmp "ollie:/tmp/$RemoteName" 2>&1 | Out-Null
  ssh ollie "bash /tmp/$RemoteName" 2>&1 }
```

> Push the new `01` to the box first: `scp` it to `ollie:/home/ubuntu/ollie-hermes-install/scripts/01-bootstrap.sh` (same BOM/CRLF-safe transfer). The box's `ubuntu` user has root fallback (`ssh root@…:6066`) if anything goes wrong.

- [ ] **Step 1: Idempotent re-run as root, default now `ollie` — existing `ubuntu` stack untouched**

Run (script file `t1.sh`): `sudo TARGET_USER=ollie bash /home/ubuntu/ollie-hermes-install/scripts/01-bootstrap.sh`
Expected: completes ✓; `getent passwd ollie` exists; `sudo -u ollie id` shows `sudo` + `docker` groups; existing `ubuntu` services still `active`; our current SSH (as `ubuntu`) still works on a fresh connection.

- [ ] **Step 2: Self-elevation from a sudo user (throwaway `testop`)**

Setup (as root): create `testop` with sudo + a DISTINCT throwaway SSH key in `~testop/.ssh/authorized_keys`.
Run as testop without sudo: `bash /home/ubuntu/ollie-hermes-install/scripts/01-bootstrap.sh`
Expected: prints `not root — re-executing under sudo (operator: testop)`; completes; `testop`'s key now appears in `~ollie/.ssh/authorized_keys` (verify with `grep`), proving operator-aware seeding.

- [ ] **Step 3: `NO_SELF_ELEVATE=1` as non-root → instruct + exit**

Run as testop: `NO_SELF_ELEVATE=1 bash /home/ubuntu/ollie-hermes-install/scripts/01-bootstrap.sh; echo "exit=$?"`
Expected: prints `must run as root. Re-run with:  sudo bash …`; `exit=1`.

- [ ] **Step 4: No-sudo user → clean error**

Setup (as root): create `nosudo` user NOT in sudo group.
Run as nosudo: `bash /home/ubuntu/ollie-hermes-install/scripts/01-bootstrap.sh; echo "exit=$?"`
Expected: prints `this script needs root, but you are 'nosudo' without usable sudo.`; `exit=1`. (No password hang — `sudo -v` fails non-interactively for a non-sudoer.)

- [ ] **Step 5: `USE_CURRENT_USER=1` → no new user + warning**

Run as testop: `USE_CURRENT_USER=1 bash /home/ubuntu/ollie-hermes-install/scripts/01-bootstrap.sh`
Expected: `service user: testop`; prints the `WARNING: testop is a pre-existing account … passwordless sudo`; no separate `ollie` work for this run; completes.

- [ ] **Step 6: Confirm WordPress + live stack untouched**

Run: `systemctl is-active apache2 mysql; docker ps --format '{{.Names}}'; systemctl --user -M ubuntu@ is-active hermes-gateway 2>/dev/null || true`
Expected: apache2/mysql `active`; `cortex` + `ollie-dashboard` present; live `ubuntu` stack unaffected.

- [ ] **Step 7: Clean up all throwaway artifacts**

Run (as root): remove the test users and the test-created `ollie` if it was only for testing:
```bash
sudo loginctl disable-linger testop nosudo ollie 2>/dev/null || true
sudo userdel -r testop 2>/dev/null; sudo userdel -r nosudo 2>/dev/null
# Remove ollie ONLY if it was created purely for this test and runs no services:
sudo userdel -r ollie 2>/dev/null; sudo groupdel ollie 2>/dev/null
sudo rm -f /etc/sudoers.d/testop /etc/sudoers.d/nosudo /etc/sudoers.d/ollie
```
Expected: `getent passwd testop nosudo ollie` returns nothing; the live `ubuntu` stack + WordPress still healthy (re-check Step 6).

---

### Task 5: Push + sync the box repo

- [ ] **Step 1: Push all commits**

```bash
git push origin master
```
Expected: refs updated, exit 0.

- [ ] **Step 2: Reset the box's repo checkout to clean origin/master**

Run: `ssh ollie 'cd ~/ollie-hermes-install && git fetch -q origin && git reset --hard origin/master && git rev-parse --short HEAD'`
Expected: box HEAD == local HEAD; working tree clean.

- [ ] **Step 3: Final confirmation**

Run: `git -C D:\devprojects\ollie-hermes-install status --porcelain` (expect empty) and compare local/origin/box HEADs (all equal).

---

## Self-Review

**Spec coverage:**
- Entry/privilege guard (self-elevation, NO_SELF_ELEVATE, no-sudo error) → Task 1 Step 1; validated Task 4 Steps 2–4.
- Service-user resolution (TARGET_USER default ollie, USE_CURRENT_USER, pre-existing handling) → Task 1; validated Task 4 Steps 1,5.
- Passwordless sudo + warning on pre-existing → Task 1; validated Task 4 Step 5.
- Operator-aware key propagation (merge/dedupe, no-keys warning) → Task 1; validated Task 4 Step 2.
- End-of-run summary + docker-group re-login note → Task 1 Step 1 (final echo block).
- Cosmetic genericization 02–07 → Task 2. Header-comment fix + `$HOME` rationale → Task 1 Step 1.
- README + migration-notes → Task 3.
- Grandfather live box / rollout → Task 4 (isolation + cleanup), Task 5.
- No functional caveat (stack is `$HOME`-based) → reflected in Task 1 header comment; no path edits needed elsewhere (verified in spec).

**Placeholder scan:** none — full script and exact string replacements provided.

**Type/name consistency:** env var names (`TARGET_USER`, `USE_CURRENT_USER`, `NO_SELF_ELEVATE`, `OLLIE_OPERATOR`), `DEFAULT_USER="ollie"`, and `OPERATOR`/`USER_PREEXISTING` vars are used consistently across Task 1 and the Task 4 validation commands.
