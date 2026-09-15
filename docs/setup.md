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

Access uses a dedicated, passphrase-less key rather than the 1Password SSH agent. That is not a preference:
1Password asks for per-use authorization, and herdr's background saved-machine connections are
non-interactive - they cannot answer that prompt, so the machine would flap between `connecting` and
`offline`.

```bash
ssh-keygen -t ed25519 -N '' -C laptop-devbox -f ~/.ssh/devbox
```

Authorize it in both places:

```bash
# workstation host (needed by ./bin/push)
ssh-copy-id -i ~/.ssh/devbox.pub -p 2222 vit@workstation

# devbox container: paste the same public key into DEVBOX_EXTRA_AUTHORIZED_KEYS in .env (step 3)
cat ~/.ssh/devbox.pub
```

## 2. Add the `~/.ssh/config` blocks

Two hosts, same machine, different ports: `2222` is the workstation's own sshd, `2223` is the container's.

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

## `.env` reference

| Variable                       | Default           | Purpose                                                         |
|--------------------------------|-------------------|-----------------------------------------------------------------|
| `BIND_ADDR`                    | *(empty)*         | Publish address; empty = `up` refuses                           |
| `DEVBOX_SSH_PORT`              | `2223`            | Host port (container always uses `2222`)                        |
| `DEVBOX_DATA_DIR`              | `/home/dev`       | Host path; must equal container home (path identity)            |
| `HOST_UID` / `HOST_GID`        | `1001`            | Dedicated `dev` host user; owns the data dir and project daemon |
| `DEVBOX_DOCKER_SOCKET_DIR`     | `/run/devbox`     | Project daemon socket dir, bind-mounted into the container      |
| `TZ`                           | `Europe/Prague`   | Container timezone                                              |
| `DEVBOX_GITHUB_USER`           | `rozsival`        | Seeds keys from `github.com/<user>.keys`                        |
| `DEVBOX_EXTRA_AUTHORIZED_KEYS` | *(empty)*         | Extra keys, newline-separated                                   |
| `GIT_PERSONAL_NAME` / `_EMAIL` | personal identity | Applied to `~/.gitconfig`                                       |
| `GIT_WORK_NAME` / `_EMAIL`  | work identity  | Applied to `~/.config/work/.gitconfig`                       |

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

**Can I use the 1Password agent anyway?**
For interactive `ssh devbox`, yes - any key the agent holds works if it is authorized. Only herdr's
background connections need the file key, so both can coexist.

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
