# AGENTS.md

This file provides guidance to AI assistants (Claude, Gemini, Copilot, OpenCode etc.) when working with code
in this repository.

## Project Overview

`devbox` provisions a containerised remote development environment on the AI coding workstation: one
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
   `log_warn`/`log_error` helpers, the same convention every script in `bin/` and `container/` uses. Do not
   introduce a code-generation step for ~10 commands
3. **Pinned versions only** - every external binary comes from an explicit `ARG <TOOL>_VERSION` and is
   checksum-verified where upstream publishes a checksum file. Never invent a hash
4. **No root in the container** - no `privileged`, no `cap_add`, no `/var/run/docker.sock` mount. `sshd` runs
   as `dev`. Project containers come from the *rootless sibling* daemon, never from the host's root daemon and
   never from a nested one: nesting needs setuid `newuidmap`, which `cap_drop: ALL` plus `no-new-privileges`
   deliberately make impossible (`docs/docker.md`)
5. **`BIND_ADDR` is the security boundary** - never publish a port without it, never add `0.0.0.0` bindings
6. **Bootstrap stays idempotent** - every step in `container/bootstrap.sh` is guarded so a re-run is a no-op
7. **Commits** - Conventional Commits v1.0.0, lowercase, no final punctuation, 100 chars max
8. **No private keys in the container** - identities are public keys only; agent git goes over HTTPS through
   the launcher; manual work forwards the 1Password agent

## Key Files

- `README.md` - entry point: 60-second start, documentation index, layout, cheat sheet
- `docs/` - domain-scoped documentation, each file ending in an FAQ. Update the file that owns the domain
  rather than growing `README.md`:
  - `docs/setup.md` - prerequisites, laptop key, `~/.ssh/config`, first deploy, `.env` reference
  - `docs/connecting.md` - herdr panes, `ssh devbox`, Moshi on a phone, `./bin/devbox shell`, cloning, port forwarding
  - `docs/git.md` - the identity registry, manual vs agent git, the credential helper, signing, laptop install
  - `docs/toolchain.md` - pinned versions, install locations, OMP, Moshi/`moshi-hook`, agent skills, adding a tool
  - `docs/secrets.md` - the three secret layers, `secrets.env`, `GH_TOKEN`, GCP ADC, App credentials
  - `docs/cli.md` - `bin/devbox`, `bin/rootless-docker`, `bin/push`, `bin/sync-omp`, `bin/sync-identities`,
    `bin/install-agent` and `bin/laptop-doctor` reference
  - `docs/networking.md` - exposure model, why UFW cannot block a published port, tunnels
  - `docs/docker.md` - the rootless project daemon, path identity, reaching services, `devbox-ports`
  - `docs/operations.md` - redeploy, persistence, backup, health, troubleshooting
  - `docs/security.md` - boundaries, trust assumptions, deliberate limits
- `.env.example` - the only per-host configuration; `.env` is gitignored and never synced by `bin/push`.
  Holds no identity: who this box is, per account and per directory tree, lives in
  `~/.config/devbox/identities.conf` instead (see the `home/` bullet below) - an enumeration of
  per-account variables is what that file replaced
- `Dockerfile` - pinned toolchain; `NVM_DIR=/opt/nvm` and `COREPACK_HOME=/opt/corepack` exist because
  `/home/dev` is bind-mounted and would shadow a home-directory install; `herdr` must land in
  `/usr/local/bin` because non-interactive SSH sessions get the default PATH
- `docker-compose.yml` - `${BIND_ADDR}:${DEVBOX_SSH_PORT}:2222` is the entire network boundary; `user:`,
  `cap_drop: [ALL]`, `no-new-privileges`, no root docker socket, no identity in `environment:` either - same
  reason as `.env.example`. `${DEVBOX_DOCKER_SOCKET_DIR:-/run/devbox}` mounts the *directory* because
  rootlesskit recreates the socket inode on every daemon restart, and `network_mode: bridge` keeps the
  container on `docker0`, the one interface the project-port boundary admits, and which - unlike a
  compose-managed bridge - is not removed by `down`
- `container/entrypoint.sh` - PID 1 as `dev`: home skeleton, host key, `authorized_keys`, bootstrap, the
  project-port mirror, the `moshi-hook` daemon, then `exec sshd`. The order is load-bearing; the mirror
  comes last of the setup steps because forwards live in this container's netns and are lost on every
  recreate, and both it and the hook daemon are best-effort because neither an unreachable project daemon
  nor a missing hook daemon may cost SSH access. `moshi-hook serve` is backgrounded rather than supervised
  because there is no systemd here: it becomes a child of `sshd` and is reaped by tini
- `container/bootstrap.sh` - idempotent user setup, sixteen individually-guarded sections: 1 OMP; 2 the
  identity registry (installs `devbox-identities` in `~/.local/libexec` and symlinks it into
  `~/.local/bin`, since `devbox.sh` puts only the latter on the PATH and every checklist tells people to
  run `devbox-identities check`, then `di_check`s
  `~/.config/devbox/identities.conf` - which it deliberately does *not* seed from the example, because the
  example is valid and would silently become the box's git identity - a broken registry skips every section derived from
  it as
  one block, so it costs configuration, never SSH access); 3 SSH identity **public keys** per identity (no
  private key - installed from `identities.conf`, deletes any earlier devbox-generated private key and
  prints its fingerprint to revoke); 4 `~/.ssh/config` (rendered from the registry); 5 `known_hosts`
  (seeded per forge host); 6 `~/.gitconfig` (the default identity's name, email and signing key); 7 your
  identity per non-default tree (one generated `user-<slug>.gitconfig`, the include list rewritten from
  scratch every run so a renamed or dropped identity leaves no stale `includeIf`); 8 `allowed_signers`; 9
  GitHub App credential directories per identity (created, never fetched - only placed by hand); 10 shell;
  11 the box-wide `secrets.env`; 12 `gh` (the `~/.local/libexec/devbox-agent` shim plus the per-identity
  token checklist); 13 the agent git override (the launcher plus its `omp` symlink, credential helper,
  fence, the *rendered* `agent.gitconfig` and one `agent-<slug>.gitconfig` per identity claiming a `dir` -
  every one of them, inherited authors included, since git applies every matching `includeIf` and a nested
  tree would otherwise keep the outer author; the includes are emitted shortest `dir` first so the longest
  match is read last and wins); 14 OMP config; 15 `moshi-hook` plus its OMP extension; 16 the printed manual checklist
- `container/sshd_config` - unprivileged sshd: `UsePAM no`, pubkey-only, absolute paths, `AllowTcpForwarding
  yes` (dev-server tunnels), `AllowAgentForwarding yes` (the `ssh -A devbox` escape hatch only - the
  container holds no private key of its own) and `MaxSessions 32` (herdr channels)
- `container/skills.sh` - optional, explicitly invoked (`./bin/devbox skills`): pinned `agent-browser` CLI +
  Chrome build, then `agent-browser`, `skill-creator` and `find-skills` via
  `npx skills add --global --agent universal --yes`. Chrome's shared libraries are in the `Dockerfile`
  because `--with-deps` needs root. Global npm installs pass `--prefix "$HOME/.local"` per call so the bins
  stay on the bind mount; never export `NPM_CONFIG_PREFIX` - nvm then refuses to activate its default Node
- `home/` - templates installed into `/home/dev` by bootstrap (and onto the laptop by `bin/install-agent`);
  generated files, not user-edited. `home/.config/devbox/identities.conf.example` is the template for
  `~/.config/devbox/identities.conf` - the one file naming who this box is, per account and per directory
  tree. Neither installer copies it: it validates, so seeding it would hand git and every agent session the
  placeholder identity instead of failing loudly. `home/.local/libexec/devbox-identities` is its one
  reader, sourced by every script below (`di_slugs`, `di_get`, `di_for`, `di_check`, the `di_render_*`
  functions) and installed as the `devbox-identities` CLI; deliberately bash 3.2 compatible, since the
  laptop-side scripts run under whatever `/usr/bin/env bash` macOS provides.
  `home/.local/libexec/devbox-agent/` holds `omp-launcher` (exports `GIT_CONFIG_GLOBAL`, the SSH fence,
  `GIT_TERMINAL_PROMPT=0` and a login-less `GH_CONFIG_DIR` for its own process tree only - on the laptop,
  bare `gh` would otherwise fall back to your OAuth login), reached as `omp` only through a symlink and
  never as a file named `omp`, because `omp update` resolves its install target by looking `omp` up on the
  PATH and takes a plain file there over in place - it once wrote the release binary onto the launcher,
  dropping agent sessions back on the user's gitconfig and SSH keys; the launcher drops its own PATH
  entries for the `update` subcommand so the updater lands on the real install, and the symlink confines a
  missed argv shape to the updater's shebang refusal. Beside it, the `gh` shim that deliberately shadows
  the real `gh` on the PATH: with `devbox-gh-token` it resolves `GH_TOKEN_<SLUG>` per invocation from the
  working directory, on the same `dir` prefixes in `identities.conf` that git's `includeIf` uses, because
  an agent's cwd is a project while its shell was opened in `$HOME`. Nothing exports `GH_TOKEN`; `gh auth
  login` is rejected by design (`docs/secrets.md`). `home/.config/devbox/git/agent.gitconfig.tpl` is the
  template `devbox-identities render agent-gitconfig` fills in with the registry's hosts, aliases and URL
  rewrites - edit it here, never the rendered `~/.config/devbox/git/agent.gitconfig` or the one
  `agent-<slug>.gitconfig` per identity claiming a `dir` that it produces. Sets the bot author,
  unsigned commits, and the HTTPS credential-helper rewrite for agent git (`docs/git.md`); both installers
  leave that directory at mode 500 with 444 files, because `GIT_CONFIG_GLOBAL` points into it and a `git
  config --global` inside a session therefore rewrites the agent's own identity - `~/.extra` did exactly
  that from every login bash, putting the user's name and email on five agent commits, and git's lock file
  makes the directory mode the only thing that stops such a write. `home/.bash_profile` exists only to
  reassert the `PATH` order for login shells: bash prefers it over `~/.profile`, which it sources first,
  because the distro's file prepends `~/.local/bin` *after* `~/.bashrc` and so put the real `omp` ahead of
  the launcher in every interactive `ssh devbox`, herdr pane and `./bin/devbox shell`; `devbox.sh`
  therefore asserts the order (move to front) instead of prepending only when absent
- `container/devbox-ports` - symlinked to `/usr/local/bin` by the `Dockerfile`, so a host edit is live
  without a rebuild; mirrors published project ports onto the container's own `127.0.0.1`
- `bin/devbox` - host-side CLI (`env`, `up`, `down`, `rebuild`, `bootstrap`, `skills`, `shell`, `sessions`,
  `logs`, `hook`, `keys`, `doctor`); `up`/`down`/`rebuild` refuse to drop live SSH sessions without
  `--force`, `hook` restarts the `moshi-hook` daemon with a detached `exec` precisely so it does not have
  to, and `keys` prints every identity's installed public keys (or "not set") plus the sshd host-key
  fingerprint - nothing to paste anywhere, since they are already the laptop's own keys
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
- `bin/sync-identities` - laptop-side: copies `~/.config/devbox/identities.conf` into the devbox over
  `Host devbox`, keeping one `identities.conf.bak` remotely, then re-runs `bootstrap.sh` there so every
  identity-derived file catches up; validates locally with `devbox-identities check` first, the same
  reader that runs on both sides, so a broken registry never becomes the one the devbox boots from
- `bin/install-agent` - laptop-side, idempotent: installs the same agent git override the devbox bootstraps
  (`omp-launcher`, `gh` shim, credential helper, fence, `devbox-gh-token`, `devbox-identities` in
  `~/.local/libexec` with a `~/.local/bin` symlink so it answers by name, the read-only *rendered*
  `git/agent*.gitconfig`, and `omp` symlinks to the launcher in
  `~/.local/libexec/devbox-agent` and `~/.local/bin`), and prints the `cp` command for
  `~/.config/devbox/identities.conf` rather than seeding it; regenerates every generated file, reads/edits
  nothing of the user's own `identities.conf`; reports whether `omp` resolves to the launcher and prints
  the remaining manual steps (PATs, App credentials)
- `bin/laptop-doctor` - laptop-side, read-only counterpart of `devbox doctor`: no private key on disk, one
  `id_<slug>.pub`/`signing_<slug>.pub` pair per identity (plus `devbox.pub`) held by the 1Password agent,
  every `Host` block selecting one `.pub` through it, the registry itself (`devbox-identities check`),
  every gitconfig signing via `op-ssh-sign` with the right `signing_*.pub`, the agent override installed -
  the static files byte-identical to `home/`'s templates, the agent gitconfigs byte-identical to a fresh
  `devbox-identities render agent-gitconfig` - with both `omp` hops still symlinks (a plain file is an
  `omp update` takeover) and `~/.local/bin/devbox-identities` still a symlink onto the libexec reader (the
  only hop that makes `devbox-identities` resolve by name),
  `~/.config/devbox/git` still unwritable and no login shell writing a git identity
  into it, no agent token in the macOS keychain (a system `credential.helper` running ahead of ours), every
  identity's PAT accepted by `gh`, every App pem valid, and every configured connection authenticating -
  including `Host <workstation>`, whose hostname the repo names nowhere: `laptop-doctor` reads `DEVBOX_HOST`
  from the environment or `.push.env` - the same per-laptop value `bin/push` resolves, deliberately one
  name and one file rather than two - and skips that one check when it is unset. Unsets the launcher's
  exports and strips its PATH entry first, so it is meaningful from inside an agent session. `file_mode`
  uses perl because BSD and GNU `stat` disagree and both can be on a macOS PATH
- `bin/push` - laptop-side rsync deploy; excludes `.git`, `.env`, and `data/`. `--up` runs the remote `up`
  over `ssh -t` so the live-session prompt is answerable; `--force` forwards past it. No default host: it
  sources `.push.env` (gitignored) for `DEVBOX_HOST`, then the environment, then fails - a repo going
  public must not ship one machine's alias as everyone's default
- `.agents/skills/` - four skills mirroring the docs for agents: `devbox-basics` (architecture, boundaries,
  entry routes), `devbox-setup` (five ordered setup phases plus connection failures), `devbox-laptop`
  (keys in 1Password, ssh/git config, the agent override, tokens - `laptop-doctor` as the acceptance test),
  `devbox-deploy` (sync vs apply, what a redeploy cannot destroy). They must stay consistent with `docs/`;
  when a command or default changes, update both
