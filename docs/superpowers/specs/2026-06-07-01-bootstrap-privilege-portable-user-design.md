# 01-bootstrap.sh — privilege handling + portable service user

Status: approved (design) — 2026-06-07
Scope: `scripts/01-bootstrap.sh` (primary) + cosmetic genericization across `scripts/02–07` and docs.

## Problem

`01-bootstrap.sh` is the only step that needs root: it creates a user, writes
sudoers, installs Docker + apt packages, and enables linger. Today it:

1. Hard-requires being invoked as uid 0 (errors otherwise with "run as root").
2. Creates a user named **`ubuntu`** and seeds that user's `authorized_keys`
   by copying **root's** keys.

Two real-world gaps surface once someone other than us runs it (scenario: we
sometimes provision the box, but customers also run it on their own box logged
in as their own sudo-capable user):

- **No graceful sudo handoff.** A customer logged in as `alice` (sudo, not
  root) just sees "run as root" and has to know to prepend `sudo`.
- **Access can be lost.** Keys are seeded from `/root/.ssh/authorized_keys`. If
  the operator logged in as a sudo user (root's keys empty — a real case we
  hit), the new service user ends up with no way in.
- **`ubuntu` is a poor default name.** It implies a distro and is an odd
  account to plant on a customer's box.

A prior code comment claimed "the rest of the stack (… orchestrator paths)
assumes `/home/ubuntu/`." This was **verified false**: every component derives
paths from `$HOME`/`%h` (orchestrator `src/config.py` lines 23–26 default
`HERMES_STACK_DIR`/`HERMES_PROFILES_DIR`/`SYSTEMD_USER_DIR` to `home / …`;
scripts 02–07 use `${HOME}`; systemd units use `%h`). So the service-user name
is freely changeable.

## Goals

- Support both access patterns: direct `root` login, and a sudo-capable
  operator who runs it as themselves.
- Never lock the operator out of the service user.
- Use a distro-neutral, product-branded default service user (`ollie`),
  overridable.
- Keep the install fully non-interactive (no mid-run password prompts).
- Keep everything idempotent and re-runnable.

## Non-goals

- Supporting truly unprivileged installs (no root AND no sudo) — impossible for
  a system bootstrap; we detect and explain instead.
- Renaming the service user on the already-running box (it stays `ubuntu`,
  grandfathered).
- Auditing/altering the orchestrator beyond confirming it is `$HOME`-based
  (already confirmed).

## Design

### Configuration knobs (env vars, all optional)

| Var | Default | Effect |
|---|---|---|
| `TARGET_USER` | `ollie` | Service user to create/use. |
| `USE_CURRENT_USER` | unset | If `1`, sets `TARGET_USER` to the operator (the invoking sudo user). |
| `NO_SELF_ELEVATE` | unset | If `1`, do not auto-`sudo`; just instruct and exit when not root. |
| `OLLIE_OPERATOR` | (auto) | Internal: the human who launched it, preserved across the sudo re-exec for key propagation. |

### 1. Entry / privilege guard (hybrid self-elevation)

Resolve the operator identity first: `OPERATOR = OLLIE_OPERATOR or SUDO_USER or
current-user`. Then:

```
if not root:
    if NO_SELF_ELEVATE == 1:
        echo "Run as root, or: sudo bash 01-bootstrap.sh"; exit 1
    if sudo exists and `sudo -v` succeeds:
        echo "not root — re-executing under sudo (operator: $OPERATOR)"
        exec sudo OLLIE_OPERATOR="$OPERATOR" NO_SELF_ELEVATE=1 \
             TARGET_USER="$TARGET_USER" USE_CURRENT_USER="${USE_CURRENT_USER:-}" \
             bash "$0" "$@"
    else:
        echo "error: this needs root. You are '$OPERATOR' without sudo."
        echo "       Log in as root, or have an admin grant sudo, then:"
        echo "       sudo bash $0"
        exit 1
# from here down we are uid 0; OPERATOR names the human who launched it
```

`NO_SELF_ELEVATE=1` is set on the re-exec to guarantee no elevation loop.

### 2. Service-user resolution

- If `USE_CURRENT_USER=1`, set `TARGET_USER="$OPERATOR"` (and refuse if that
  resolves to `root`).
- Create `TARGET_USER` only if missing (`useradd -m -s /bin/bash`).
- Whether new or pre-existing: ensure membership in `sudo` and `docker` groups,
  enable linger. **Never** modify a pre-existing user's home contents.
- Track `USER_PREEXISTING` (true if `id` succeeded before we touched it) — used
  to decide the passwordless-sudo warning.

### 3. Passwordless sudo

The automated steps 02–07 require passwordless sudo (e.g. 02's
`sudo ln -s … /usr/local/bin/hermes`) and docker-group membership, or the run
would block on a password prompt. So we always write
`/etc/sudoers.d/<TARGET_USER>` with `NOPASSWD:ALL`.

If `USER_PREEXISTING` (custom/current user that already existed), print a
**prominent warning**: "granting passwordless sudo to existing account
'<user>' so the install can run unattended — review
/etc/sudoers.d/<user> afterward if that's not desired."

### 4. SSH key propagation (access preservation)

Build the target's `authorized_keys` by concatenating, in priority order, then
de-duping (order-preserving, blank-safe — the existing `awk 'NF && !seen'`):

1. Operator's keys: `~OPERATOR/.ssh/authorized_keys` (or `/root/.ssh/…` when
   operator is root).
2. Root's keys (`/root/.ssh/authorized_keys`), if different from #1.
3. The target user's existing `authorized_keys` (preserve).

Then `chown` to the target user, `chmod 700 ~/.ssh`, `chmod 600
authorized_keys`. Result: whoever ran the install can `ssh <user>@host` **and**
`sudo -iu <user>`. If all three sources are empty, print a warning with
remediation (add a key, or use `sudo -iu <user>` from a privileged session) —
do not fail.

When `TARGET_USER == OPERATOR` (USE_CURRENT_USER), their keys are already
present → effectively a no-op, no lock-out risk.

### 5. End-of-run summary + messaging

Print: the service user chosen; how to reach it (`ssh <user>@host` or
`sudo -iu <user>`); the reminder that docker-group membership needs a fresh
login before step 06; and any warnings emitted (self-elevated,
passwordless-sudo-on-existing-user, no-keys).

### 6. Cosmetic genericization (02–07 + docs)

- Reword `# Run as: ubuntu` and "run as the ubuntu user, not root" → "Run as:
  the service user" / "run as the service user, not root" across 02–07. (These
  are messages/comments only; the actual guard is `id -u==0` + `$HOME`.)
- Fix 01's header comment: drop the false "/home/ubuntu assumption" rationale;
  state the stack is `$HOME`-based and the user name is configurable.
- README quick-start and migration-notes: use `<service-user>` / `ollie` and
  show the new override knobs; keep examples runnable.

## Behavior matrix

| Operator runs… | as | result |
|---|---|---|
| `sudo bash 01` | sudo user `alice` | already uid 0 → creates `ollie`, seeds **alice's** keys, alice retains access |
| `bash 01` | sudo user `alice` | self-elevates via sudo → same as above |
| `bash 01` | root (ssh root@) | creates `ollie`, seeds root's keys |
| `USE_CURRENT_USER=1 sudo bash 01` | `alice` | stack runs as `alice` (no new user); warns about passwordless sudo |
| `bash 01` | non-sudo user `bob` | clean error: needs root/sudo |
| `NO_SELF_ELEVATE=1 bash 01` | `alice` | prints `sudo bash 01…` and exits |

## Testing plan

On the live box (root fallback available), validate **01 in isolation** — a
full parallel `ollie` stack can't run here (02–07 would collide on ports with
the live `ubuntu` stack), so stack-level retest is out of scope for this box:

1. Re-run `sudo bash 01` (default now `ollie`) → creates `ollie`, idempotent,
   existing `ubuntu` untouched, current SSH access preserved.
2. Create throwaway sudo user `testop` (distinct key) → `bash 01` as `testop`
   without sudo → confirms self-elevation + `testop`'s key seeded into `ollie`.
3. `NO_SELF_ELEVATE=1 bash 01` as non-root → clean instruction + exit 1.
4. Throwaway **no-sudo** user → `bash 01` → clean "needs root/sudo" error.
5. `USE_CURRENT_USER=1 sudo bash 01` as `testop` → no new user; warning shown.
6. Clean up: remove `testop`, the throwaway no-sudo user, and the test `ollie`
   user/group/sudoers created for the test (leave the box exactly as found:
   live `ubuntu` stack intact).

## Rollout

- The running box is unaffected (still `ubuntu`; we do not migrate a live user).
- New installs default to `ollie`.
- Commit to `ollie-hermes-install`, push, sync the box checkout.

## Files touched

- `scripts/01-bootstrap.sh` — the privilege/user/key logic (primary).
- `scripts/02–07` — cosmetic message/comment genericization.
- `README.md`, `docs/migration-notes.md` — service-user references + new knobs.
