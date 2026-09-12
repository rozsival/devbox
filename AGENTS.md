# AGENTS.md

This file provides guidance to AI assistants (Claude, Gemini, Copilot, OpenCode etc.) when working with code
in this repository.

## Project Overview

`devbox` provisions a containerised remote development environment on the `workstation` AI workstation: one
Docker container running an unprivileged `sshd` published only on the node's Tailscale address, so a herdr
client can attach to it as a saved machine and run OMP agents inside it. The container is the agent sandbox -
it reaches the project tree, the internet and a rootless project Docker daemon, never the host filesystem or
the host's root Docker daemon.

## Stack

- **Host**: Ubuntu 26.04 LTS, Docker with compose v2, Tailscale; repo lives at `~/devbox`
- **Image**: `ubuntu:26.04` + pinned `herdr`, `gh`, `lazygit`, `wt` (worktrunk), `terraform`, the Docker CLI
  with the compose and buildx plugins, and Node 24 / pnpm 12 through nvm in `/opt/nvm`. No `op` and no
  `gcloud`: the container holds no vault and no Google account (see `docs/secrets.md`)
- **Runtime**: `sshd` on container port 2222, published as `${BIND_ADDR}:2223` and `127.0.0.1:2223`
- **Project Docker**: a second, rootless `dockerd` owned by the dedicated host user `dev` (uid 1001), socket
  `/run/devbox/docker.sock` bind-mounted in; provisioned once by `sudo ./bin/rootless-docker`
- **Config**: `.env` (from `.env.example`), `docker-compose.yml`, `container/*`, `home/*`

## Critical Rules

1. **Package manager** - `apt-get` only in scripts and Dockerfiles (never `apt`): `apt` has no stable CLI
   interface and warns on every scripted call
2. **`bin/devbox` is hand-written bash, not bashly** - `set -euo pipefail`, `log_info`/`log_success`/
   `log_warn`/`log_error` helpers matching workstation's prefixes. Do not introduce a code-generation step
   for ~10 commands
3. **Pinned versions only** - every external binary comes from an explicit `ARG <TOOL>_VERSION` and is
   checksum-verified where upstream publishes a checksum file. Never invent a hash
4. **No root in the container** - no `privileged`, no `cap_add`, no `/var/run/docker.sock` mount. `sshd` runs
   as `dev`. Project containers come from the *rootless sibling* daemon, never from the host's root daemon and
   never from a nested one: nesting needs setuid `newuidmap`, which `cap_drop: ALL` plus `no-new-privileges`
   deliberately make impossible (`docs/docker.md`)
5. **`BIND_ADDR` is the security boundary** - never publish a port without it, never add `0.0.0.0` bindings
6. **Bootstrap stays idempotent** - every step in `container/bootstrap.sh` is guarded so a re-run is a no-op
7. **Commits** - Conventional Commits v1.0.0, lowercase, no final punctuation, 100 chars max

## Key Files

- `README.md` - entry point: 60-second start, documentation index, layout, cheat sheet
- `docs/` - domain-scoped documentation, each file ending in an FAQ. Update the file that owns the domain
  rather than growing `README.md`:
  - `docs/setup.md` - prerequisites, laptop key, `~/.ssh/config`, first deploy, `.env` reference
  - `docs/connecting.md` - herdr panes, `ssh devbox`, `./bin/devbox shell`, cloning, port forwarding
  - `docs/git.md` - the two identities, clone rules, signing, GitHub key registration
  - `docs/toolchain.md` - pinned versions, install locations, OMP, agent skills, adding a tool
  - `docs/secrets.md` - the three secret layers, `secrets.env`, `GH_TOKEN`, GCP ADC, App credentials
  - `docs/cli.md` - `bin/devbox`, `bin/push` and `bin/sync-omp` reference
  - `docs/networking.md` - exposure model, why UFW cannot block a published port, tunnels
  - `docs/docker.md` - the rootless project daemon, path identity, reaching services, `devbox-ports`
  - `docs/operations.md` - redeploy, persistence, backup, health, troubleshooting
  - `docs/security.md` - boundaries, trust assumptions, deliberate limits
- `.env.example` - the only per-host configuration; `.env` is gitignored and never synced by `bin/push`
- `Dockerfile` - pinned toolchain; `NVM_DIR=/opt/nvm` and `COREPACK_HOME=/opt/corepack` exist because
  `/home/dev` is bind-mounted and would shadow a home-directory install; `herdr` must land in
  `/usr/local/bin` because non-interactive SSH sessions get the default PATH
- `docker-compose.yml` - `${BIND_ADDR}:${DEVBOX_SSH_PORT}:2222` is the entire network boundary; `user:`,
  `cap_drop: [ALL]`, `no-new-privileges`, no root docker socket. `${DEVBOX_DOCKER_SOCKET_DIR:-/run/devbox}`
  mounts the *directory* because rootlesskit recreates the socket inode on every daemon restart, and
  `network_mode: bridge` keeps the container on `docker0`, the one interface the project-port boundary
  admits, and which - unlike a compose-managed bridge - is not removed by `down`
- `container/entrypoint.sh` - PID 1 as `dev`: home skeleton, host key, `authorized_keys`, bootstrap, then
  `exec sshd`. The order is load-bearing
- `container/bootstrap.sh` - idempotent user setup: OMP, both SSH identities, `~/.ssh/config`, known_hosts,
  the two-identity Git config, shell, `gh`, the box-wide `secrets.env`, and the printed manual checklist
- `container/sshd_config` - unprivileged sshd: `UsePAM no`, pubkey-only, absolute paths, `AllowTcpForwarding
  yes` (dev-server tunnels) and `MaxSessions 32` (herdr channels)
- `container/skills.sh` - optional, explicitly invoked (`./bin/devbox skills`): pinned `agent-browser` CLI +
  Chrome build, then `agent-browser`, `skill-creator` and `find-skills` via
  `npx skills add --global --agent universal --yes`. Chrome's shared libraries are in the `Dockerfile`
  because `--with-deps` needs root. Global npm installs pass `--prefix "$HOME/.local"` per call so the bins
  stay on the bind mount; never export `NPM_CONFIG_PREFIX` - nvm then refuses to activate its default Node
- `home/` - templates installed into `/home/dev` by bootstrap; generated files, not user-edited
- `container/devbox-ports` - symlinked to `/usr/local/bin` by the `Dockerfile`, so a host edit is live
  without a rebuild; mirrors published project ports onto the container's own `127.0.0.1`
- `bin/devbox` - host-side CLI (`env`, `up`, `down`, `rebuild`, `bootstrap`, `skills`, `shell`, `sessions`,
  `logs`, `keys`, `doctor`); `up`/`down`/`rebuild` refuse to drop live SSH sessions without `--force`
- `bin/rootless-docker` - host-side, needs `sudo`, idempotent, `--check` reports only: installs `uidmap` and
  `slirp4netns`, creates the `dev:devbox` host user with pinned uid/gid 1001, moves `DEVBOX_DATA_DIR` to
  `/home/dev` (path identity), writes `/etc/tmpfiles.d/devbox-docker.conf`, installs the nftables table plus
  `devbox-docker-firewall.service` that keeps published project ports off every interface but loopback and
  `docker0` (`--ip` covers only the default bridge, so the unit also passes `--default-network-opt` and the
  table backs both up), adds the one `ufw` rule that lets the devbox bridge reach the gateway, and runs a
  lingering rootless `dockerd` on `/run/devbox/docker.sock` from a root-owned unit in `/etc/systemd/user`,
  so nothing in the bind mount can rewrite the daemon's command line
- `bin/sync-omp` - laptop-side: copies `~/.omp/agent/config.yml` into the devbox over `Host devbox`; only
  the preset, never the per-machine OMP state
- `bin/push` - laptop-side rsync deploy; excludes `.git`, `.env`, and `data/`. `--up` runs the remote `up`
  over `ssh -t` so the live-session prompt is answerable; `--force` forwards past it
- `.agents/skills/` - three skills mirroring the docs for agents: `devbox-basics` (architecture, boundaries,
  entry routes), `devbox-setup` (five ordered setup phases plus connection failures), `devbox-deploy`
  (sync vs apply, what a redeploy cannot destroy). They must stay consistent with `docs/`; when a command or
  default changes, update both
