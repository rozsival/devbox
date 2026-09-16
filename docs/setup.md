# 🛠 Setup

First deploy, per-host config, laptop SSH wiring, in order - each step verifiable alone.

## Prerequisites

| Where       | Requirement                                                                  |
|-------------|------------------------------------------------------------------------------|
| Workstation | Ubuntu 26.04, Docker with compose v2, Tailscale up, `rsync`, a known UID/GID |
| Laptop      | `rsync`, an SSH client, and a [herdr](https://herdr.dev) client              |

Check the workstation in one call:

```bash
ssh workstation 'docker --version && docker compose version && tailscale ip -4 && id -u && command -v rsync'
```

Different host UID is fine: `./bin/devbox env` derives `HOST_UID`/`HOST_GID` from the current user, owning
the bind-mounted home.

## 1. Create the laptop key

No private key sits on the laptop's disk - a 1Password SSH item served by the agent. The public half sits
at `~/.ssh/config`; `IdentityFile` picks it there.

1. 1Password → new SSH Key item (ed25519), e.g. *Devbox Laptop*; enable the SSH agent.
2. Save its public key as `~/.ssh/devbox.pub` (the item's *public key* field, or via `ssh-add -l`/
   `ssh-add -L | grep <fingerprint>`).

Authorize it in both places:

```bash
# workstation host (needed by ./bin/push)
ssh-copy-id -i ~/.ssh/devbox.pub -p 2222 vit@workstation

# devbox container: paste the same public key into DEVBOX_EXTRA_AUTHORIZED_KEYS in .env (step 3)
cat ~/.ssh/devbox.pub
```

herdr's background connections need 1Password unlocked and the key's herdr approval remembered. A machine
flapping `connecting`/`offline` under a locked 1Password reflects that - unlock or approve it. Unworkable?
A passphrase-less *file* key (`ssh-keygen -t ed25519 -N '' -f ~/.ssh/devbox`) serves only these two blocks,
never GitHub.

## 2. Add the `~/.ssh/config` blocks

Two hosts, one machine, different ports: `2222` workstation sshd, `2223` container's.

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

`ForwardAgent no` states the default: manual git needs explicit `ssh -A devbox` ([Git identities](git.md)),
never herdr's connection. GitHub `Host` blocks match: `IdentityFile ~/.ssh/id_personal.pub` for
`github.com`, `~/.ssh/id_work.pub` for `work.github.com`.

`IdentitiesOnly yes` is load-bearing: without it the agent offers every key, and the server rejects with
`Too many authentication failures` first.

Verify resolved parameters, then the connection:

```bash
ssh -G devbox | grep -E '^(hostname|port|user|identityfile|identitiesonly) '
ssh workstation true
```

## 3. Deploy and configure

```bash
./bin/push workstation
ssh workstation 'cd ~/devbox && ./bin/devbox env'
```

`env` creates `.env` from `.env.example`: `BIND_ADDR` from `tailscale ip -4`, `HOST_UID`/`HOST_GID` from
`dev` (else current user). Edit `~/devbox/.env`, at minimum `DEVBOX_EXTRA_AUTHORIZED_KEYS` with step 1's
key.

Provision the project Docker daemon once: needs `.env` present, moves `DEVBOX_DATA_DIR` to `/home/dev`
under `dev`, refusing while the container runs (before the first `up`):

```bash
ssh -t workstation 'cd ~/devbox && sudo ./bin/rootless-docker'
```

`--check` reports what's missing, unchanged otherwise; see [Docker](docker.md). Then start the container:

```bash
ssh workstation 'cd ~/devbox && ./bin/devbox up && ./bin/devbox doctor'
```

`.env` is gitignored **and** excluded from `bin/push` - deploys leave it untouched.

## 4. Attach herdr

```bash
ssh devbox true                                    # accept the host key once
herdr machine add devbox --label "Workstation devbox"  # interactive terminal; verifies the remote binary
herdr                                              # `Workstation devbox` appears next to `Local`
```

## 5. Optional but recommended

Two extras outside `bootstrap`, keeping first starts fast, offline-safe:

```bash
ssh workstation 'cd ~/devbox && ./bin/devbox skills'   # 3 global agent skills + agent-browser + Chrome
./bin/sync-omp                                           # laptop OMP preset → devbox
```

Both idempotent, rerunnable anytime. Details: [Toolchain](toolchain.md#agent-skills-and-browser-automation).

## 6. Agent git on the laptop (optional but recommended)

Agents run on the laptop too, same launcher, same mechanism:

```bash
./bin/install-agent
```

Installs `omp-launcher`, `gh` shim, credential helper, fence in `~/.local/libexec/devbox-agent`;
`devbox-gh-token` in `~/.local/bin`; `omp` symlinked to the launcher in both directories;
`~/.config/devbox/agent*.gitconfig`;
`~/.config/devbox/secrets.env` from template if missing. Idempotent: regenerates generated files, keeps
`secrets.env`, touches nothing else. Reports whether `omp` resolves to the launcher, and prints the two
manual steps: PATs in `~/.config/devbox/secrets.env`, App credentials at
`~/.config/work/work-app/`. See [Git identities](git.md#laptop-install).

`./bin/laptop-doctor` is the laptop's acceptance test. It covers steps 1, 2 and 6 plus the GitHub `Host`
blocks and the signing config: keys held by 1Password with none on disk, every `Host` selecting one `.pub`,
both gitconfigs signing via `op-ssh-sign`, the override current, both PATs accepted, and all four
connections authenticating. Details: [CLI reference](cli.md#binlaptop-doctor).

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
| `GIT_PERSONAL_PUBKEY`          | *(empty)*         | Laptop's personal auth key; selects the forwarded key                                 |
| `GIT_PERSONAL_SIGNINGKEY`      | *(empty)*         | Laptop's personal signing key (`git config user.signingkey` on the laptop)            |
| `GIT_WORK_PUBKEY`           | *(empty)*         | Same, for `~/projects/work/**`                                                     |
| `GIT_WORK_SIGNINGKEY`       | *(empty)*         | Same, for `~/projects/work/**`                                                     |

`.env` holds no secrets: tool credentials in `~/.config/devbox/secrets.env`, project secrets in each
project's own `.env`. See [Secrets](secrets.md).

## ❓ FAQ

**Why does `authorized_keys` come from GitHub?**
Rebuilt every container start from `https://github.com/<DEVBOX_GITHUB_USER>.keys` plus
`DEVBOX_EXTRA_AUTHORIZED_KEYS` - rotating a key is a restart, not an edit. Narrow trust: clear
`DEVBOX_GITHUB_USER`, list keys explicitly.

**How do I authorize another client - a phone, a second laptop?**
Append its public key to `DEVBOX_EXTRA_AUTHORIZED_KEYS` in `.env` **on the workstation**
(`workstation:~/devbox/.env`; never synced by `bin/push`), run `./bin/devbox up`. Values newline-separate
in one quoted pair - compose passes them intact:

```bash
DEVBOX_EXTRA_AUTHORIZED_KEYS="ssh-ed25519 AAAA…O/L+ laptop-devbox
ssh-ed25519 AAAA…a0iNF iphone"
```

`up` recreates the container, re-reading `.env` - `docker restart` keeps the old environment. Confirm with
`docker compose exec devbox ssh-keygen -lf /home/dev/.ssh/authorized_keys`. Client still needs the tailnet:
port publishes only on `BIND_ADDR`.

**Do I need a key file on disk at all?**
No. Every key - devbox key, both GitHub identities - is a 1Password item; `~/.ssh` holds only `.pub`
halves. Reason for a file key: herdr's background connection failing while 1Password is locked (step 1) -
serving those two blocks only.

**`up` failed with an empty `BIND_ADDR`. Is that a bug?**
No - the preflight is working as intended. Run `./bin/devbox env` (Tailscale up first), or set the address
by hand. `0.0.0.0` as fallback would expose devbox publicly.

**Does `bin/push` overwrite my host configuration?**
No - excludes `.git`, `.env`, `data/`, `.DS_Store`; `--delete` hits only synced paths.

**Do I need to re-run `env` after a redeploy?**
Only if the Tailscale address changed; `doctor` compares `BIND_ADDR` to `tailscale ip -4`, failing on drift.

**I already have a devbox at the old data path. What does `sudo ./bin/rootless-docker` do to it?**
Nothing while the container runs - it refuses, pointing to `./bin/devbox down` first. Stopped, it `mv`s the
old `DEVBOX_DATA_DIR` to `/home/dev`, chowned to `dev`. Keys, cloned repos, `~/.config/devbox/secrets.env`
survive - a move, not a recreate. Finish with `./bin/devbox rebuild`.

**Where does the data live on the host?**
`${DEVBOX_DATA_DIR}` (default `/home/dev`), owned by `HOST_UID:HOST_GID`. See [Operations](operations.md)
for backup/restore.
