# 🛠 Setup

First deploy, per-host configuration, and the laptop-side SSH wiring. Do these in order; each step is
verifiable on its own.

## Prerequisites

| Where       | Requirement                                                                  |
|-------------|------------------------------------------------------------------------------|
| Workstation | Ubuntu 26.04, Docker with compose v2, Tailscale up, `rsync`, a known UID/GID |
| Laptop      | `rsync`, an SSH client, and a [herdr](https://herdr.dev) client              |

Check the workstation in one call:

```bash
ssh workstation 'docker --version && docker compose version && tailscale ip -4 && id -u && command -v rsync'
```

A different host UID is fine: `./bin/devbox env` picks `HOST_UID`/`HOST_GID` up from the current user, and the
bind-mounted home is created owned by them.

## 1. Create the laptop key

No private key on the laptop's disk: the key is a 1Password SSH item, and the 1Password agent serves it.
Only the public half is written next to `~/.ssh/config`, where `IdentityFile` uses it to pick that one key
out of the agent.

1. 1Password → new SSH Key item (ed25519), e.g. *Devbox Laptop*; make sure the 1Password SSH agent is on.
2. Save its public key as `~/.ssh/devbox.pub` (the item's *public key* field, or
   `ssh-add -l` to find it and `ssh-add -L | grep <fingerprint>` to print it).

Authorize it in both places:

```bash
# workstation host (needed by ./bin/push)
ssh-copy-id -i ~/.ssh/devbox.pub -p 2222 vit@workstation

# devbox container: paste the same public key into DEVBOX_EXTRA_AUTHORIZED_KEYS in .env (step 3)
cat ~/.ssh/devbox.pub
```

herdr's saved-machine connections run in the background, so they depend on 1Password being unlocked and on
the key's approval being remembered for herdr. A machine that flaps between `connecting` and `offline` while
1Password is locked is that dependency, not a devbox fault - unlock, or approve the key for herdr in the
1Password prompt. If that ever proves unworkable, a dedicated passphrase-less *file* key
(`ssh-keygen -t ed25519 -N '' -f ~/.ssh/devbox`) is the documented exception: it serves only these two host
blocks, nothing GitHub-facing.

## 2. Add the `~/.ssh/config` blocks

Two hosts, same machine, different ports: `2222` is the workstation's own sshd, `2223` is the container's.

```
Host *
  IdentityAgent "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"

Host workstation
  HostName workstation
  Port 2222
  User vit
  IdentitiesOnly yes
  IdentityFile ~/.ssh/devbox.pub
  ServerAliveInterval 30

Host devbox
  HostName workstation
  Port 2223
  User dev
  IdentitiesOnly yes
  IdentityFile ~/.ssh/devbox.pub
  ForwardAgent no
  ServerAliveInterval 30
```

`ForwardAgent no` is the default, spelled out: manual git as yourself inside the devbox is an explicit
`ssh -A devbox` ([Git identities](git.md)), never something herdr's connection carries. The GitHub `Host`
blocks follow the same pattern - `IdentityFile ~/.ssh/id_personal.pub` for `github.com`,
`~/.ssh/id_work.pub` for the `work.github.com` alias - so the laptop and the devbox share one layout.

`IdentitiesOnly yes` is load-bearing: without it the agent offers every key it holds and the server rejects
the connection with `Too many authentication failures` before reaching the right one.

Verify the resolved parameters, then the connection:

```bash
ssh -G devbox | grep -E '^(hostname|port|user|identityfile|identitiesonly) '
ssh workstation true
```

## 3. Deploy and configure

```bash
./bin/push workstation
ssh workstation 'cd ~/devbox && ./bin/devbox env'
```

`env` creates `.env` from `.env.example` and fills `BIND_ADDR` from `tailscale ip -4`, plus `HOST_UID` and
`HOST_GID` from the `dev` host user once it exists, otherwise from the current user. Then edit
`~/devbox/.env` on the workstation - at minimum `DEVBOX_EXTRA_AUTHORIZED_KEYS` with the key from step 1.

Provision the project Docker daemon once. It needs `.env` to exist (hence after `env`) and moves
`DEVBOX_DATA_DIR` to `/home/dev` under the new `dev` account, which it refuses to do while the container
is running (hence before the first `up`):

```bash
ssh -t workstation 'cd ~/devbox && sudo ./bin/rootless-docker'
```

`--check` reports what is missing without changing anything; see [Docker](docker.md) for what it provisions.
Then start the container:

```bash
ssh workstation 'cd ~/devbox && ./bin/devbox up && ./bin/devbox doctor'
```

`.env` is gitignored **and** excluded from `bin/push`, so every later deploy leaves it untouched.

## 4. Attach herdr

```bash
ssh devbox true                                    # accept the host key once
herdr machine add devbox --label "Workstation devbox"  # interactive terminal; verifies the remote binary
herdr                                              # `Workstation devbox` appears next to `Local`
```

## 5. Optional but recommended

Two extras that are deliberately not part of `bootstrap`, so a first start stays fast and offline-safe:

```bash
ssh workstation 'cd ~/devbox && ./bin/devbox skills'   # 3 global agent skills + agent-browser + Chrome
./bin/sync-omp                                           # laptop OMP preset → devbox
```

Both are idempotent and can be re-run at any time. Details in
[Toolchain](toolchain.md#agent-skills-and-browser-automation).

## 6. Agent git on the laptop (optional but recommended)

Agents can also run directly on the laptop, not just inside the devbox - same launcher, same mechanism:

```bash
./bin/install-agent
```

Installs the `omp` launcher, `gh` shim, credential helper and fence into `~/.local/libexec/devbox-agent`,
`devbox-gh-token` into `~/.local/bin`, symlinks `~/.local/bin/omp` to the launcher, and writes
`~/.config/devbox/agent*.gitconfig`. Idempotent - regenerates every file, reads or edits nothing of yours. It
reports whether `omp` resolves to the launcher and prints the same two manual steps as the devbox: PATs in
`~/.config/devbox/secrets.env`, App credentials at `~/.config/work/work-app/`. See
[Git identities](git.md#laptop-install).

## `.env` reference

| Variable                       | Default           | Purpose                                                                               |
|--------------------------------|-------------------|---------------------------------------------------------------------------------------|
| `BIND_ADDR`                    | *(empty)*         | Publish address; empty = `up` refuses                                                 |
| `DEVBOX_SSH_PORT`              | `2223`            | Host port (container always uses `2222`)                                              |
| `DEVBOX_DATA_DIR`              | `/home/dev`       | Host path; must equal container home (path identity)                                  |
| `HOST_UID` / `HOST_GID`        | `1001`            | Dedicated `dev` host user; owns the data dir and project daemon                       |
| `DEVBOX_DOCKER_SOCKET_DIR`     | `/run/devbox`     | Project daemon socket dir, bind-mounted into the container                            |
| `TZ`                           | `Europe/Prague`   | Container timezone                                                                    |
| `DEVBOX_GITHUB_USER`           | `rozsival`        | Seeds keys from `github.com/<user>.keys`                                              |
| `DEVBOX_EXTRA_AUTHORIZED_KEYS` | *(empty)*         | Extra keys, newline-separated                                                         |
| `GIT_PERSONAL_NAME` / `_EMAIL` | personal identity | Applied to `~/.gitconfig`                                                             |
| `GIT_WORK_NAME` / `_EMAIL`  | work identity  | Applied to `~/.config/work/.gitconfig`                                             |
| `GIT_PERSONAL_PUBKEY`          | *(empty)*         | Laptop's personal authentication public key; selects the forwarded key for manual git |
| `GIT_PERSONAL_SIGNINGKEY`      | *(empty)*         | Laptop's personal signing public key (`git config user.signingkey` on the laptop)     |
| `GIT_WORK_PUBKEY`           | *(empty)*         | Same, for `~/projects/work/**`                                                     |
| `GIT_WORK_SIGNINGKEY`       | *(empty)*         | Same, for `~/projects/work/**`                                                     |

`.env` holds no secrets: tool credentials go in `~/.config/devbox/secrets.env` inside the container and
project secrets in each project's own `.env`. See [Secrets](secrets.md).

## ❓ FAQ

**Why does `authorized_keys` come from GitHub?**
It is rebuilt on every container start from `https://github.com/<DEVBOX_GITHUB_USER>.keys` plus
`DEVBOX_EXTRA_AUTHORIZED_KEYS`, so rotating a key on GitHub is a restart rather than a manual edit. To narrow
the trust, clear `DEVBOX_GITHUB_USER` and list keys explicitly instead.

**How do I authorize another client - a phone, a second laptop?**
Append its public key to `DEVBOX_EXTRA_AUTHORIZED_KEYS` in `.env` **on the workstation**
(`workstation:~/devbox/.env`; `bin/push` never syncs it) and run `./bin/devbox up`. The value is
newline-separated inside one pair of double quotes - compose passes multi-line values through intact:

```bash
DEVBOX_EXTRA_AUTHORIZED_KEYS="ssh-ed25519 AAAA…O/L+ laptop-devbox
ssh-ed25519 AAAA…a0iNF iphone"
```

`up` recreates the container, which is what re-reads `.env` - a plain `docker restart` would keep the old
environment. Confirm with `docker compose exec devbox ssh-keygen -lf /home/dev/.ssh/authorized_keys`. The
client still needs to be on the tailnet: the port is published only on `BIND_ADDR`.

**Do I need a key file on disk at all?**
No. Every key - the devbox key and both GitHub identities - is a 1Password item, and `~/.ssh` holds only the
`.pub` halves `IdentityFile` selects by. The only reason to ever create a file key is herdr's background
connection failing while 1Password is locked (see step 1); it would serve those two host blocks and nothing
else.

**`up` failed with an empty `BIND_ADDR`. Is that a bug?**
No, it is the preflight doing its job. Run `./bin/devbox env` (Tailscale must be up first), or set the address
by hand. The alternative - falling back to `0.0.0.0` - would publish the devbox to the public internet.

**Does `bin/push` overwrite my host configuration?**
No. It excludes `.git`, `.env`, `data/` and `.DS_Store`, and `--delete` applies only to synced paths.

**Do I need to re-run `env` after a redeploy?**
Only if the Tailscale address changed. `doctor` compares `BIND_ADDR` against `tailscale ip -4` and fails when
they diverge.

**I already have a devbox at the old data path. What does `sudo ./bin/rootless-docker` do to it?**
Nothing while the container is running - it refuses and tells you to `./bin/devbox down` first. Stopped, it
`mv`s the old `DEVBOX_DATA_DIR` to `/home/dev` and chowns the tree to the new `dev` user. Keys, cloned repos
and `~/.config/devbox/secrets.env` all survive: it is a move, not a recreate. Finish with
`./bin/devbox rebuild`.

**Where does the data live on the host?**
`${DEVBOX_DATA_DIR}` (default `/home/dev`), owned by `HOST_UID:HOST_GID`. See [Operations](operations.md) for
backup and restore.
