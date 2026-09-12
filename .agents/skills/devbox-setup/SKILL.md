---
name: devbox-setup
description: Sets up the devbox end to end - the dedicated laptop SSH key, the two ~/.ssh/config host blocks, the first deploy and .env on the workstation, herdr machine registration, and the in-container manual steps (GitHub keys, gh auth login, op account add, secrets.env, GitHub App credentials). Use this whenever someone is installing or re-installing the devbox, onboarding a new laptop, says they cannot connect, gets "Too many authentication failures", "Permission denied (publickey)", an empty BIND_ADDR preflight failure, or a herdr machine stuck offline, or asks which manual steps are still outstanding.
---

# devbox setup

Setup has four phases with a hard ordering: laptop key → `~/.ssh/config` → deploy and `.env` on the
workstation → in-container identity steps. Each phase ends with a check that must pass before moving on,
because a failure two phases later is almost always an unverified earlier phase.

Full reference: `docs/setup.md`. Read it when a value or flag is not spelled out here.

## Phase 1 - the laptop key (on the laptop)

```bash
ssh-keygen -t ed25519 -N '' -C laptop-devbox -f ~/.ssh/devbox
ssh-copy-id -i ~/.ssh/devbox.pub -p 2222 vit@workstation   # host sshd, needed by ./bin/push
cat ~/.ssh/devbox.pub                                        # goes into .env in phase 3
```

Use a dedicated, passphrase-less **file** key, not the 1Password SSH agent. 1Password asks for per-use
authorization and herdr's saved-machine connections run in the background, non-interactively - they cannot
answer that prompt, so the machine flaps between `connecting` and `offline`. The 1Password agent can still
serve interactive `ssh devbox`; the two coexist.

## Phase 2 - `~/.ssh/config` (on the laptop)

Two entries for the same machine on different ports: `2222` is the workstation's own sshd, `2223` is the
container's.

```
Host workstation
  HostName workstation
  Port 2222
  User vit
  IdentitiesOnly yes
  IdentityFile ~/.ssh/devbox
  ServerAliveInterval 30

Host devbox
  HostName workstation
  Port 2223
  User dev
  IdentitiesOnly yes
  IdentityFile ~/.ssh/devbox
  ServerAliveInterval 30
```

`IdentitiesOnly yes` is load-bearing: without it the agent offers every key it holds and the server rejects
the connection with `Too many authentication failures` before reaching the right one.

Check: `ssh -G devbox | grep -E '^(hostname|port|user|identityfile|identitiesonly) '` then
`ssh workstation true`.

## Phase 3 - deploy and configure (from the laptop)

```bash
./bin/push workstation
ssh workstation 'cd ~/devbox && ./bin/devbox env'
```

`env` creates `.env` from `.env.example`, never clobbers an existing one, and fills `BIND_ADDR` from
`tailscale ip -4` plus `HOST_UID`/`HOST_GID` from the current user. Tailscale must be up first - with it
down there is no address to write, and `up` then refuses on the empty value. Then edit `~/devbox/.env` on
the workstation - at minimum put the phase-1 public key in `DEVBOX_EXTRA_AUTHORIZED_KEYS`, which takes
newline-separated keys - and start it:

```bash
ssh workstation 'cd ~/devbox && ./bin/devbox up && ./bin/devbox doctor'
```

`doctor` is the acceptance test for this phase: it checks compose, `BIND_ADDR` against Tailscale, that
something listens on `BIND_ADDR:${DEVBOX_SSH_PORT}` and **nothing** on `0.0.0.0`, container health, that PID 1
is `dev`, and ten toolchain probes. It exits non-zero if any check fails.

`.env` is gitignored **and** excluded from `bin/push`, so later deploys never touch it.

If the node's Tailscale address later changes, `doctor` reports
`BIND_ADDR is X but Tailscale reports Y`; re-run `./bin/devbox env && ./bin/devbox up`.

## Phase 4 - attach herdr and finish the identity steps

```bash
ssh devbox true                                    # accept the container host key once
herdr machine add devbox --label "Workstation devbox"  # interactive terminal: it verifies the remote binary
herdr                                              # "Workstation devbox" appears next to "Local"
```

Bootstrap runs on every container start, is fully idempotent, and prints the outstanding steps at the end -
so `./bin/devbox bootstrap` is the authoritative answer to "what is left to do", never a guess:

```bash
ssh workstation 'cd ~/devbox && ./bin/devbox keys'       # the two public keys + host-key fingerprint
```

1. Add `id_personal.pub` **and** `id_work.pub` to GitHub twice each - once as an Authentication key, once
   as a Signing key. Without the Signing key registration commits push fine but show as unverified.
2. `gh auth login --hostname github.com --git-protocol ssh --web`; a second account is a second
   `gh auth login`, then `gh auth switch`. Tokens persist in `~/.config/gh` on the bind mount.
3. `op account add --address <OP_ACCOUNT_ADDRESS> --email <OP_ACCOUNT_EMAIL>`, then `eval "$(op signin)"` per
   shell.
4. Fill `~/.config/devbox/secrets.env` with `op://vault/item/field` references. `devenv <cmd>` wraps
   `op run --env-file` - a single unresolvable reference fails the whole command, so only add lines for items
   that exist.
5. Place the work-app GitHub App credentials in `~/.config/work/work-app/` (`app-id` and
   `app.pem`, mode 600). Bootstrap creates that directory and never fetches secrets.

Verification of the identity wiring lives in `docs/git.md`; the short version is
`ssh -T git@github.com` → `Hi rozsival!` and `ssh -T github-work` → `Hi rozsival-work!`.

## When setup does not work

| Symptom                                 | Cause and fix                                                   |
|-----------------------------------------|-----------------------------------------------------------------|
| `up` aborts on empty `BIND_ADDR`        | Preflight working as designed. Tailscale up, then `env`         |
| `Too many authentication failures`      | Missing `IdentitiesOnly yes` in the `Host devbox` block         |
| `Permission denied (publickey)`         | Key not in `DEVBOX_EXTRA_AUTHORIZED_KEYS` or on GitHub; restart |
| herdr machine stuck `offline`           | Passphrase-protected or agent-only key; use the file key        |
| `Host key verification failed`          | Data dir was wiped; `ssh-keygen -R '[workstation]:2223'`      |
| `Permission denied` writing `/home/dev` | `${DEVBOX_DATA_DIR}` not owned by `HOST_UID:HOST_GID`           |
| SSH itself is the broken thing          | `./bin/devbox shell` on the host bypasses the container's sshd  |

`authorized_keys` is rebuilt on every container start from `https://github.com/<DEVBOX_GITHUB_USER>.keys` plus
`DEVBOX_EXTRA_AUTHORIZED_KEYS`, so key changes take a restart, not a manual edit.
