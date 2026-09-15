# ⌨️ CLI reference

Two entrypoints, both hand-written bash with `set -euo pipefail`: `bin/devbox` runs **on the workstation**,
`bin/push` runs **on the laptop**. Log prefixes are `[INFO]`, `[OK]`, `[WARN]`, `[ERROR]`, matching
`workstation`.

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

Every command loads `.env` first and fails with a pointer to `.env.example` if it is missing.

`up`, `down` and `rebuild` count established SSH sessions first. Recreating or stopping the container kills
them mid-keystroke and the client prints nothing at all, so with sessions live they prompt on a terminal and
refuse outright in a script; `--force` (`-f`) skips the prompt. A `docker compose up` that changes nothing
leaves the container running, so a no-op `up` never asks.

- **`env`** - never clobbers an existing `.env`; rewrites `BIND_ADDR` from `tailscale ip -4` and
  `HOST_UID`/`HOST_GID` from the `dev` host user when it exists, otherwise from the invoking user.
- **`up`** - preflight (`BIND_ADDR` non-empty; `DEVBOX_DATA_DIR` present and owned by `HOST_UID:HOST_GID`,
  created with `install -d` when absent; a *warning*, not a failure, when the project Docker socket is
  missing, with a pointer to `sudo ./bin/rootless-docker`), `docker compose build`, then
  `docker compose up -d`. The build runs before the session check because a fresh image is itself a reason
  for compose to recreate.
- **`down`** - `docker compose down`. The bind mount and `.env` are untouched.
- **`rebuild`** - `docker compose build --no-cache && docker compose up -d`. Use after a `Dockerfile` change.
- **`bootstrap`** - `docker compose exec` of `container/bootstrap.sh`; idempotent and reprints the checklist.
- **`skills`** - `docker compose exec` of `container/skills.sh`: the three global agent skills plus the
  `agent-browser` CLI and its Chrome build. Optional, idempotent, and separate from `bootstrap` because the
  first run downloads ~180 MB. See [Toolchain](toolchain.md#agent-skills-and-browser-automation).
- **`shell`** - `docker compose exec -it devbox bash -l`. Works even when sshd or Tailscale is broken.
- **`sessions`** - established connections to the container's sshd plus the last 10 `Accepted`/`Disconnected`
  lines, for tracing a disconnect after the fact.
- **`logs`** - `--tail 100` by default; `-f` follows.
- **`hook`** - stops `moshi-hook` and starts it again with a detached `docker compose exec`, then prints
  `moshi-hook status`. The non-destructive restart path: the daemon is a child of the entrypoint, so the
  alternative would be recreating the container and killing every SSH session with it. Needed after
  `moshi-hook pair` and after a crash. See [Toolchain](toolchain.md#moshi-and-moshi-hook).
- **`keys`** - prints the authentication (`id_*.pub`) and signing (`signing_*.pub`) public keys per identity (or
  `not set` if the `GIT_*_PUBKEY` / `GIT_*_SIGNINGKEY` value is empty in `.env`) and the sshd host-key
  fingerprint. Not a paste target: they're already your laptop's own keys, already on GitHub.
- **`doctor`** - the checks below. It runs all of them, reports each one, and exits non-zero if any failed.

### What `doctor` checks

1. `docker` and `docker compose` v2 present
2. `BIND_ADDR` non-empty and equal to `tailscale ip -4`
3. Something listening on `BIND_ADDR:${DEVBOX_SSH_PORT}`, and **nothing** on `0.0.0.0`
4. Container health status is `healthy`
5. PID 1 runs as `dev` (no root process)
6. Eleven toolchain probes, each with its real exit code: `herdr`, `omp`, `node`, `pnpm`, `gh`, `lazygit`,
   `wt`, `terraform`, `git`, `docker`, `docker compose`
7. The `moshi-hook` daemon is installed and running - unpaired is reported as a warning, not a failure
8. The project Docker daemon is reachable from inside the container and reports `rootless`
9. `host.docker.internal` resolves inside the container

## `bin/rootless-docker`

```
Usage: sudo ./bin/rootless-docker [--check]
```

Host-side, one-time provisioning for the project Docker daemon: a second, rootless `dockerd` running as a
dedicated unprivileged host user `dev` (uid 1001, group `devbox`) - never the host's root daemon, never
nested in the container. See [Docker](docker.md) for the reasoning.

Must run with `sudo`. Every step is idempotent, so a re-run is a no-op. `--check` reports what is missing and
changes nothing.

What it provisions:

- installs `uidmap` and `slirp4netns`
- creates the `dev:devbox` host user (uid 1001), no password, no keys, no sudo
- moves `DEVBOX_DATA_DIR` to `/home/dev` and chowns it, so container and host bind-mount paths match
- writes `/etc/nftables.d/devbox-docker.nft` and enables `devbox-docker-firewall.service`, which keeps
  published project ports off every interface but loopback and the devbox bridge
- adds one `ufw` rule so the devbox bridge can reach the gateway address ports are published on
- writes `/etc/tmpfiles.d/devbox-docker.conf` so `/run/devbox` exists before the daemon starts and on reboot
- runs `loginctl enable-linger dev`, so the never-logged-in account still gets a systemd user manager
- writes its own root-owned `/etc/systemd/user/docker.service` running
  `dockerd-rootless.sh --host unix:///run/devbox/docker.sock`, and restarts the daemon when that file changes
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

The sync is `rsync -az --delete` excluding `.git`, `.env`, `data/` and `.DS_Store`. It checks for `rsync` on
both sides first and prints the exact remedy if it is missing.

`--up` runs the remote `up` over `ssh -t`, so when that `up` would recreate the container with sessions
attached its prompt reaches your terminal instead of failing the push. `--force` answers it up front.

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

Copies this laptop's OMP preset into the devbox and keeps one `config.yml.bak` there. It talks to the
container's sshd (`Host devbox`, port 2223), not the workstation's, so the file lands inside the bind-mounted
`/home/dev`. Unlike `bin/push` it is not part of a deploy - the preset is personal state, not repo content.

## `bin/install-agent`

```
Usage: ./bin/install-agent
```

Laptop-side, idempotent: installs the same agent git override the devbox bootstraps - the `omp` launcher,
`gh` shim, credential helper and fence in `~/.local/libexec/devbox-agent`, `devbox-gh-token` in
`~/.local/bin`, a `~/.local/bin/omp` symlink to the launcher, and `~/.config/devbox/agent*.gitconfig`. Every
file is regenerated on every run; nothing of yours is read or edited. Reports whether `omp` currently
resolves to the launcher and prints the remaining manual steps (PATs, App credentials). See
[Git identities](git.md#laptop-install).

## ❓ FAQ

**Why plain bash instead of bashly, like `workstation`?**
Ten commands and no code-generation step. `bin/src` plus a `pnpm run build:cli` pipeline would be pure
overhead here. Keep it hand-written.

**Can I run `bin/devbox` from the laptop?**
No - it drives the local Docker daemon. Use `ssh workstation 'cd ~/devbox && ./bin/devbox <cmd>'`, or
`./bin/push workstation --up` for the common case.

**Is `--delete` dangerous?**
It only applies to paths that are synced, and `.env`, `data/` and `.git` are excluded. Files you added to the
remote copy of a *tracked* directory will be removed - that is intentional, the remote is a mirror.

**`up` vs `rebuild` - which do I need?**
`up` after a compose, `.env`, `container/` or `home/` change (it rebuilds layers that changed). `rebuild` when
you need a cache-free image, e.g. after bumping a pinned version.

**Does `bootstrap` overwrite my dotfiles?**
Only the two generated ones: `~/.bashrc.d/devbox.sh` and `~/.ssh/config`, both rewritten from the templates
on every run. `~/.gitconfig`, both `secrets*.env` files and the OMP config are created if absent and then
left alone; derived Git identity values are re-applied with `git config --global` on each run.

**`doctor` says `BIND_ADDR is X but Tailscale reports Y`.**
The node's Tailscale address changed. `./bin/devbox env && ./bin/devbox up`.

**How do I tell whether the project Docker daemon is provisioned?**
`sudo ./bin/rootless-docker --check` reports every missing piece and changes nothing. `./bin/devbox doctor`
also checks that the daemon is reachable and rootless from inside the container.
