# 📦 devbox

Containerised remote development environment for the `workstation` AI workstation: a single Docker
container running its own unprivileged `sshd`, published only on the node's Tailscale address, so a
[herdr](https://herdr.dev) client on a laptop can attach to it as a saved machine and run OMP agents inside
it.

The container **is** the sandbox. Agents running with bypassed permissions reach the project tree and the
internet - never the host filesystem and never the host Docker daemon.

## 🚀 Quick start

First run, from the laptop:

```bash
./bin/push workstation                 # rsync the repo to ~/devbox on the workstation
ssh workstation 'cd ~/devbox && ./bin/devbox env && ./bin/devbox up'
```

`env` is a separate step only on the first run: it creates `.env` (which `push` never overwrites) and fills
`BIND_ADDR` from `tailscale ip -4`. Afterwards a deploy is one command:

```bash
./bin/push workstation --up
```

Then wire up the laptop:

```bash
ssh devbox true                          # accept the host key once (see the SSH config below)
herdr machine add devbox --label "Workstation devbox"
herdr                                    # `devbox` appears next to `Local`
```

Access uses a dedicated, passphrase-less laptop key rather than the 1Password SSH agent. That is not a
preference: 1Password asks for per-use authorization, and herdr's background saved-machine connections are
non-interactive - they cannot answer that prompt, so the machine would flap between `connecting` and
`offline`. Create it once, authorize it, and keep it out of the agent:

```bash
ssh-keygen -t ed25519 -N '' -C laptop-devbox -f ~/.ssh/devbox
# workstation (for ./bin/push): append ~/.ssh/devbox.pub to ~/.ssh/authorized_keys there
# devbox: put the same public key in DEVBOX_EXTRA_AUTHORIZED_KEYS in .env, then ./bin/devbox up
```

Required `~/.ssh/config` entries on the laptop:

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

`authorized_keys` inside the devbox is assembled on every container start from
`https://github.com/<DEVBOX_GITHUB_USER>.keys` plus `DEVBOX_EXTRA_AUTHORIZED_KEYS`, so rotating a key on
GitHub is a restart, not a manual edit. Any key in the agent still works for interactive `ssh devbox`.

## 🔌 Exposure

| Layer | Behavior |
| --- | --- |
| Docker | Publishes `2223` on `127.0.0.1` and `BIND_ADDR` (the node's Tailscale IP) - never `0.0.0.0` |
| Tailscale | The only route to `BIND_ADDR` |
| Result | Reachable from the Tailnet, invisible from the public internet |

Docker publishes ports with `nat/PREROUTING` DNAT, so packets reaching the container are *forwarded*, not
delivered locally - they never traverse the `INPUT` chain UFW manages, and `ufw deny 2223` cannot block a
published port ([moby/moby#17496](https://github.com/moby/moby/issues/17496)). An address-scoped published
port is enforced by the DNAT rule itself. `BIND_ADDR` is mandatory: unset, `./bin/devbox up` refuses to start
rather than silently falling back to `0.0.0.0`.

Dev servers are **not** published. Forward them instead:

```bash
ssh -N -L 5173:localhost:5173 devbox
```

## 🧰 Commands

```
./bin/devbox env         # create .env and sync BIND_ADDR, HOST_UID, HOST_GID
./bin/devbox up          # preflight, build, start
./bin/devbox down        # stop and remove
./bin/devbox rebuild     # rebuild the image from scratch and restart
./bin/devbox bootstrap   # re-run the in-container user setup (idempotent)
./bin/devbox shell       # login shell in the container
./bin/devbox logs [-f]   # container logs
./bin/devbox keys        # devbox public keys + sshd host-key fingerprint
./bin/devbox doctor      # host wiring, exposure, container health, toolchain versions
```

## ✅ Manual checklist

`bootstrap` prints exactly what is left; nothing below is ever automated, because all of it needs a browser
or a secret.

1. Add both keys from `./bin/devbox keys` to GitHub **twice each** - once as an Authentication key, once as a
   Signing key.
2. `gh auth login --hostname github.com --git-protocol ssh --web` inside the devbox (repeat per account,
   switch with `gh auth switch`). The token persists in `~/.config/gh` on the bind mount.
3. `op account add --address my.1password.com --email <email>`, then `eval "$(op signin)"` per shell.
4. Fill `~/.config/devbox/secrets.env` with `op://` references and run commands as `devenv <cmd>`.
5. Place the work-app GitHub App credentials in `~/.config/work/work-app/`
   (`app-id`, `app.pem` at mode 600) if you need them.

## 🧱 What is inside

`ubuntu:26.04` plus a pinned toolchain in `/usr/local/bin`: `herdr`, `gh`, `lazygit`, `wt` (worktrunk),
`terraform`, `op`, `ripgrep`, `fd`, and Node 24 with pnpm 12 via nvm in `/opt/nvm`. OMP is installed by
`bootstrap` into `~/.local/bin` instead of the image, so `omp update` works without a rebuild.

Two Git identities, both with SSH auth and SSH commit signing:

| Scope | Identity | Key | Remote |
| --- | --- | --- | --- |
| everywhere | `GIT_PERSONAL_*` | `~/.ssh/id_personal` | `github.com` |
| `~/projects/work/**` | `GIT_WORK_*` | `~/.ssh/id_work` | `github-work` |

Clone work repos through the alias - `git clone github-work:<org>/<repo> ~/projects/work/<repo>` -
because URL rewriting from an `includeIf` file cannot apply before the repo directory exists. Existing
`git@github.com:` remotes already inside `~/projects/work/` are rewritten automatically.

## 🗄 Persistence

`${DEVBOX_DATA_DIR}` on the host is bind-mounted at `/home/dev`: dotfiles, both SSH identities, the sshd host
key, `~/.config/gh`, and the whole `~/projects` tree. A bind mount rather than a named volume so `tar` can
back it up and the host user (same UID) can inspect it. Container and image rebuilds keep everything,
including the client's `known_hosts` entry.

## 🔧 Extending

- **A new pinned tool**: one `ARG <TOOL>_VERSION` plus one install block in the `Dockerfile`, then
  `./bin/devbox rebuild`.
- **Host-specific tweaks**: `docker-compose.override.yml` is picked up automatically and gitignored.
- **Local workstation models**: opt-in - copy `harnesses/omp.yml` from the `workstation` repo into
  `~/.omp/agent/models.yml` inside the devbox and set the provider `baseUrl` to the workstation's Tailscale
  address.

## 🚧 Deliberate boundaries

- **No host Docker socket.** Mounting `/var/run/docker.sock` would hand the sandbox host root and void the
  point of the container. Project-level containers are therefore unavailable inside the devbox; if they are
  ever needed, the answer is a `docker:dind-rootless` sidecar plus `DOCKER_HOST`, not a socket mount.
- **No root process at runtime.** `sshd` runs as `dev` with `UsePAM no` and pubkey-only auth, so it needs
  neither `/etc/shadow` nor setuid. User namespaces are not configured on the host, so container root would
  be host UID 0 in a runtime escape.
- **1Password stays interactive.** `op` sessions expire, so anything an agent needs unattended must be a
  long-lived credential written once into the devbox (the `gh` token, `~/.terraformrc`) rather than fetched
  per run through `op`. The escape hatch is an `OP_SERVICE_ACCOUNT_TOKEN` plus a dedicated shared vault
  (service accounts cannot read Private vaults).
