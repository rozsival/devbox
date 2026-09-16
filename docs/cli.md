# ⌨️ CLI reference

Two entrypoints, both hand-written bash with `set -euo pipefail`: `bin/devbox` runs **on the workstation**,
`bin/push` on **the laptop**. Log prefixes `[INFO]`, `[OK]`, `[WARN]`, `[ERROR]` match `workstation`.

## `bin/devbox`

```
Usage: ./bin/devbox <command>

  env               Create .env from .env.example and sync BIND_ADDR, HOST_UID, HOST_GID
  up [--force]      Preflight, then build and start the container
  down [--force]    Stop and remove the container
  rebuild [--force] Rebuild the image from scratch and restart
  bootstrap         Re-run the in-container user setup
  skills            Install the optional agent skills and agent-browser (recommended)
  shell             Open a login shell inside the container
  sessions          List the SSH sessions connected to the container
  logs [-f]         Show container logs (last 100 lines; -f follows)
  hook              Restart the moshi-hook daemon in place and print its status
  keys              Print the installed identity public keys and sshd host-key fingerprint
  doctor            Check host wiring, exposure, and the in-container toolchain
```

Every command loads `.env` first, failing toward `.env.example` if missing.

`up`, `down` and `rebuild` count established SSH sessions first: recreating or stopping kills them
mid-keystroke with no client output, so live sessions get a terminal prompt, or refusal in a script;
`--force`/`-f` skips it. A `docker compose up` that changes nothing leaves the container running, so a
no-op `up` never asks.

- **`env`** - never clobbers `.env`; sets `BIND_ADDR` from `tailscale ip -4`, `HOST_UID`/`HOST_GID` from
  `dev` if present, else invoking user.
- **`up`** - preflight (`BIND_ADDR` non-empty; `DEVBOX_DATA_DIR` present, owned `HOST_UID:HOST_GID`,
  `install -d`'d if absent; missing project Docker socket only *warns*, toward `sudo ./bin/rootless-docker`),
  then `docker compose build` and `docker compose up -d`. Build precedes the session check - a fresh image
  alone justifies recreating.
- **`down`** - `docker compose down`. Bind mount and `.env` untouched.
- **`rebuild`** - `docker compose build --no-cache && docker compose up -d`. Use after a `Dockerfile` change.
- **`bootstrap`** - `docker compose exec` of `container/bootstrap.sh`; idempotent, reprints the checklist.
- **`skills`** - `docker compose exec` of `container/skills.sh`: three global agent skills plus
  `agent-browser`'s CLI and Chrome build. Optional, idempotent, kept separate from `bootstrap` - first run
  downloads ~180 MB. See [Toolchain](toolchain.md#agent-skills-and-browser-automation).
- **`shell`** - `docker compose exec -it devbox bash -l`. Works even with sshd or Tailscale broken.
- **`sessions`** - established sshd connections plus the last 10 `Accepted`/`Disconnected` lines, tracing a
  disconnect after the fact.
- **`logs`** - `--tail 100` by default; `-f` follows.
- **`hook`** - stops and restarts `moshi-hook` via detached `docker compose exec`, prints
  `moshi-hook status`. Non-destructive: the daemon is a child of the entrypoint; alternative is recreating
  the container, killing every SSH session. Needed after `moshi-hook pair` or a crash. See
  [Toolchain](toolchain.md#moshi-and-moshi-hook).
- **`keys`** - prints authentication (`id_*.pub`) and signing (`signing_*.pub`) public keys per identity
  (`not set` if `GIT_*_PUBKEY`/`GIT_*_SIGNINGKEY` empty in `.env`), plus sshd host-key fingerprint. Not a
  paste target - your laptop's own keys, already on GitHub.
- **`doctor`** - runs every check below, reports each, exits non-zero if any failed.

### What `doctor` checks

1. `docker` and `docker compose` v2 present
2. `BIND_ADDR` non-empty and equal to `tailscale ip -4`
3. Something listening on `BIND_ADDR:${DEVBOX_SSH_PORT}`, and **nothing** on `0.0.0.0`
4. Container health status is `healthy`
5. PID 1 runs as `dev` (no root process)
6. Eleven toolchain probes, real exit codes: `herdr`, `omp`, `node`, `pnpm`, `gh`, `lazygit`, `wt`,
   `terraform`, `git`, `docker`, `docker compose`
7. Agent git override intact: `omp` resolves through a symlink to `omp-launcher`, never a plain file an
   `omp update` could have replaced ([Git identities](git.md#omp-update))
8. `moshi-hook` daemon installed and running - unpaired warns, doesn't fail
9. Project Docker daemon reachable from the container, reporting `rootless`
10. `host.docker.internal` resolves inside the container to the project daemon's published address (`--ip`
    in `/etc/systemd/user/docker.service`) - a mismatch strands every published project port
11. `devbox-docker-firewall` service active - without it, published project ports reach the Tailnet and LAN

## `bin/rootless-docker`

```
Usage: sudo ./bin/rootless-docker [--check]
```

Host-side, one-time provisioning for the project Docker daemon: a second, rootless `dockerd` running as
dedicated unprivileged host user `dev` (uid 1001, group `devbox`) - never the host's root daemon, never
nested in the container. See [Docker](docker.md).

Requires `sudo`; every step is idempotent, so re-runs are no-ops. `--check` reports what's missing, changes
nothing.

What it provisions:

- installs `uidmap` and `slirp4netns`
- creates `dev:devbox` host user (uid 1001): no password, no keys, no sudo
- moves `DEVBOX_DATA_DIR` to `/home/dev`, chowning it so host and container bind-mount paths match
- writes `/etc/nftables.d/devbox-docker.nft`, enables `devbox-docker-firewall.service`: keeps published
  project ports off every interface but loopback and the devbox bridge
- adds one `ufw` rule so the devbox bridge reaches the gateway address ports publish on
- writes `/etc/tmpfiles.d/devbox-docker.conf` so `/run/devbox` exists before the daemon starts and on reboot
- runs `loginctl enable-linger dev`: gives the never-logged-in account a systemd user manager
- writes its own root-owned `/etc/systemd/user/docker.service` running
  `dockerd-rootless.sh --host unix:///run/devbox/docker.sock`, restarting the daemon when that file changes
- patches `.env`: `DEVBOX_DATA_DIR=/home/dev`, `HOST_UID`/`HOST_GID=1001`,
  `DEVBOX_DOCKER_SOCKET_DIR=/run/devbox`

Finish with `./bin/devbox rebuild` as your own user.

## `bin/push`

```
Usage: ./bin/push [host] [--up] [--force]

  host     SSH host to deploy to (default: $DEVBOX_HOST, then 'workstation')
  --up     Run './bin/devbox up' on the host after syncing
  --force  Pass --force to that 'up': recreate even with live SSH sessions

Environment:
  DEVBOX_HOST         default SSH host
  DEVBOX_REMOTE_PATH  remote repo path (default: ~/devbox)
```

Sync: `rsync -az --delete` excluding `.git`, `.env`, `data/` and `.DS_Store`. Checks for `rsync` on both
sides first, printing the exact remedy if missing.

`--up` runs the remote `up` over `ssh -t`, so a recreate-with-sessions prompt reaches your terminal instead
of failing the push; `--force` answers it up front.

```bash
./bin/push workstation              # sync only
./bin/push workstation --up         # sync, then build and start
./bin/push workstation --up --force # ... even if SSH sessions are connected
DEVBOX_REMOTE_PATH=~/devbox-test ./bin/push workstation
```

## `bin/sync-omp`

```
Usage: ./bin/sync-omp [ssh-host]

  ssh-host    devbox SSH host from ~/.ssh/config (default: $DEVBOX_SSH_HOST, then 'devbox')

Environment:
  DEVBOX_SSH_HOST   default SSH host
  OMP_CONFIG        source file (default: ~/.omp/agent/config.yml)
```

Copies this laptop's OMP preset into the devbox, keeping one `config.yml.bak` there. Talks to the
container's sshd (`Host devbox`, port 2223), not the workstation's, so the file lands inside bind-mounted
`/home/dev`. Unlike `bin/push`, not part of a deploy - the preset is personal state, not repo content.

## `bin/install-agent`

```
Usage: ./bin/install-agent
```

Laptop-side, idempotent: installs the same agent git override the devbox bootstraps - `omp-launcher`, `gh`
shim, credential helper (`devbox-git-credential`), SSH fence (`devbox-git-no-ssh`) in
`~/.local/libexec/devbox-agent`; `devbox-gh-token` in `~/.local/bin`; `omp` symlinks in both directories
pointing at the launcher; `~/.config/devbox/agent*.gitconfig`. All regenerated every run; nothing else of
yours is touched, except `~/.config/devbox/secrets.env` - created from the template if absent, else left
with mode reset to 600. Reports whether `omp` resolves to the launcher, plus remaining manual steps (PATs,
App credentials). See
[Git identities](git.md#laptop-install).

## `bin/laptop-doctor`

```
Usage: ./bin/laptop-doctor
```

Laptop-side, read-only counterpart of `devbox doctor`: no private key on disk, all five named `.pub` files
held by the 1Password agent; every `Host` block selecting one via that agent with `IdentitiesOnly`; both
gitconfigs signing through `op-ssh-sign` with `signing_*.pub` keys and an `allowed_signers` file; `omp`
resolving to the launcher through symlinks at both hops (a plain file is what an `omp update` takes over),
every installed agent file matching the repo template, no agent token
(`x-access-token`) in the macOS keychain - a sign a system credential helper preempted
`devbox-git-credential`; `secrets.env` at mode 600, both PATs accepted by `gh`, the App pem readable as a
key; and all four connections (`git@github.com`, `git@work.github.com`, `workstation`, `devbox`)
authenticating - the two GitHub aliases mapping two accounts. Reports every check, exits non-zero on
failure. Safe inside an agent session: drops the launcher's exports and PATH entry first, auditing your own
config. The `devbox-laptop` skill walks the fixes.

## ❓ FAQ

**Why plain bash instead of bashly, like `workstation`?**
Ten commands, no code-generation step needed - `bin/src` plus `pnpm run build:cli` would be pure overhead.
Keep it hand-written.

**Can I run `bin/devbox` from the laptop?**
No - it drives the local Docker daemon. Use `ssh workstation 'cd ~/devbox && ./bin/devbox <cmd>'`, or
`./bin/push workstation --up` for the common case.

**Is `--delete` dangerous?**
Only applies to synced paths - `.env`, `data/` and `.git` are excluded. Files added to a *tracked*
directory's remote copy are removed; intentional, the remote is a mirror.

**`up` vs `rebuild` - which do I need?**
`up` after a compose, `.env`, `container/` or `home/` change - rebuilds changed layers. `rebuild` for a
cache-free image, e.g. after bumping a pinned version.

**Does `bootstrap` overwrite my dotfiles?**
Only the three generated ones - `~/.bashrc.d/devbox.sh`, `~/.bash_profile` and `~/.ssh/config` - rewritten
from templates every run. `~/.gitconfig`, both `secrets*.env` files, and the OMP config: created if absent,
then left alone; derived Git identity values re-apply via `git config --global` each run.

**`doctor` says `BIND_ADDR is X but Tailscale reports Y`.**
The node's Tailscale address changed. `./bin/devbox env && ./bin/devbox up`.

**How do I tell whether the project Docker daemon is provisioned?**
`sudo ./bin/rootless-docker --check` reports every missing piece, changes nothing. `./bin/devbox doctor`
also checks the daemon is reachable and rootless from inside the container.
