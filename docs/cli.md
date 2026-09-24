# ⌨️ CLI reference

Two entrypoints, both hand-written bash with `set -euo pipefail`: `bin/devbox` runs **on the workstation**,
`bin/push` on **the laptop**. Log prefixes `[INFO]`, `[OK]`, `[WARN]`, `[ERROR]` match the workstation's.

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
- **`keys`** - one row per registry identity: its slug, ssh tag, orgs, and its two public keys (`id_<slug>.pub`,
  `signing_<slug>.pub`, or `not set - <field> for [<slug>] in identities.conf` if
  either is empty), plus the sshd host-key fingerprint. Reads from the running container when it's up,
  else straight from `${DEVBOX_DATA_DIR}/.config/devbox/identities.conf`, naming which source it used. Not
  a paste target - your laptop's own keys, already on GitHub.
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
8. `~/.config/devbox/identities.conf` passes `devbox-identities check` - a failing registry is reported
   here with the reader's own message, and skips every identity-derived check below rather than failing
   them individually
9. `~/.config/devbox/git/agent.gitconfig` plus one `agent-<slug>.gitconfig` per registry identity that
   claims a `dir`, each matching a fresh render, in a directory still read-only - a
   `git config --global` in a session writes there, and once put the user's own identity on agent commits;
   an `agent-*.gitconfig` left over from a renamed or dropped identity is flagged too
   ([Git identities](git.md#agent-sessions))
10. `moshi-hook` daemon installed and running - unpaired warns, doesn't fail
11. Project Docker daemon reachable from the container, reporting `rootless`
12. `host.docker.internal` resolves inside the container to the project daemon's published address (`--ip`
    in `/etc/systemd/user/docker.service`) - a mismatch strands every published project port
13. `devbox-docker-firewall` service active - without it, published project ports reach the Tailnet and LAN

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

  host     SSH host to deploy to (default: $DEVBOX_HOST, or DEVBOX_HOST in .push.env)

Options:
  --up     Run './bin/devbox up' on the host after syncing
  --force  Pass --force to that 'up': recreate even with live SSH sessions

Environment:
  DEVBOX_HOST         default SSH host; may also be set in .push.env beside this
                      repo (gitignored), since the alias is per-laptop
  DEVBOX_REMOTE_PATH  remote repo path (default: ~/devbox)
```

No default host ships in the repo - the workstation's SSH alias is per-laptop, so it comes from an
argument, `$DEVBOX_HOST`, or `DEVBOX_HOST=<alias>` in `.push.env` beside the repo (gitignored), in that
order; none of the three set errors out naming all three ways to fix it.

Sync: `rsync -az --delete` excluding `.git`, `.env`, `data/` and `.DS_Store`. Checks for `rsync` on both
sides first, printing the exact remedy if missing.

`--up` runs the remote `up` over `ssh -t`, so a recreate-with-sessions prompt reaches your terminal instead
of failing the push; `--force` answers it up front.

```bash
echo 'DEVBOX_HOST=<workstation>' >.push.env   # once, so every bare ./bin/push below resolves it
./bin/push                            # sync only
./bin/push --up                       # sync, then build and start
./bin/push --up --force               # ... even if SSH sessions are connected
DEVBOX_REMOTE_PATH=~/devbox-test ./bin/push <workstation>
```

## `bin/sync-identities`

```
Usage: ./bin/sync-identities [ssh-host]

  ssh-host    devbox SSH host from ~/.ssh/config (default: $DEVBOX_SSH_HOST, then 'devbox')

Environment:
  DEVBOX_SSH_HOST      default SSH host
  DEVBOX_IDENTITIES    source file (default: ~/.config/devbox/identities.conf)
```

Copies this laptop's identity registry into the devbox: validates it locally with `devbox-identities check`
first (a registry that does not validate must not be the one the devbox boots from), backs up the remote
copy as `identities.conf.bak`, `rsync`s the file over, then re-runs `./bin/devbox bootstrap` there so
`~/.ssh/config`, `~/.gitconfig`'s includes, `allowed_signers` and the agent gitconfigs catch up with
whatever just landed. Same host resolution as `bin/sync-omp` - `Host devbox`, port 2223, not the
workstation's.

```bash
./bin/sync-identities              # laptop → devbox:~/.config/devbox/identities.conf
./bin/sync-identities devbox-2     # a different ~/.ssh/config host
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
pointing at the launcher; `~/.config/devbox/git/agent*.gitconfig`, whose directory is left read-only (mode
500, files 444) so a `git config --global` in a session cannot rewrite the agent identity; the
`devbox-identities` reader in `~/.local/libexec`, symlinked into `~/.local/bin` so it answers by name. All regenerated
every run; nothing else of yours is
touched. `~/.config/devbox/identities.conf` is *not* created for you - the example is a valid file, so
seeding it would render agent gitconfigs authoring as `your-agent`; a missing registry fails the check and
the run prints the `cp` command instead. `~/.config/devbox/secrets.env` is created from its template if
absent, then left
alone. Reports whether `omp` resolves to the launcher, plus the remaining manual steps per registry
identity: a `GH_TOKEN_<SLUG>` line in `secrets.env`, and - for any identity with an `app` directory set -
its `{app-id,app.pem}` (mode 600) there. See [Git identities](git.md#laptop-install).

## `bin/laptop-doctor`

```
Usage: ./bin/laptop-doctor
```

Laptop-side, read-only counterpart of `devbox doctor`: gates on `~/.config/devbox/identities.conf`
existing and passing `devbox-identities check` first, then loops the registry for the rest - no private
key on disk, every identity's `.pub` files (plus `devbox.pub`) held by the 1Password agent; per forge host,
the plain connection selecting the host's default key and each identity's tagged connection (`ssh -P <slug>`) selecting
its own, with no leftover SSH-alias `Host` block; every identity's gitconfig
signing through `op-ssh-sign` with its own `signing_*.pub` key and an `allowed_signers` file covering all of
them; each `orgs` pattern probed as a `hasconfig:` remote from `/` - email, signing key and
`core.sshCommand` matching what `org-<slug>.gitconfig` should set, and no `gitdir:` include left rewriting
URLs; no clone still pointed at a stale SSH-alias remote (`devbox-identities alias-remotes`); `omp`
resolving to the launcher through symlinks at both hops (a plain file is what an `omp update` takes over),
`~/.local/bin/devbox-identities` still a symlink onto the libexec reader - the hop that makes the name
resolve at all, since only `~/.local/bin` is on the PATH,
every installed agent file matching the repo template, `~/.config/devbox/git/` still read-only and no
login shell writing a git identity into it, no agent token (`x-access-token`) in the macOS keychain - a
sign a system credential helper preempted `devbox-git-credential`; `secrets.env` at mode 600, every
identity's `GH_TOKEN_<SLUG>` accepted by `gh`, each configured App's pem readable as a key; and every
configured connection (each registry identity - tagged where it has one, plain otherwise - `devbox`, and
the workstation if `DEVBOX_HOST` (in the environment or in `.push.env`, the same value `bin/push` reads)
names its `~/.ssh/config` alias - unset just logs that the check is opt-in) authenticating, two identities'
connections mapping to a distinct account unless two blocks share one `pubkey` on purpose
([Git identities](git.md#-faq)). Reports every check, exits non-zero on
failure. Safe inside an agent session: drops the launcher's exports and PATH entry first, auditing your own
config. The `devbox-laptop` skill walks the fixes.

## `devbox-identities`

```
Usage: devbox-identities list|dir-slugs|default|get|show|for|check|file|org-urls|alias-remotes|render ...

  list                                    Slugs, in config order
  dir-slugs                               Slugs claiming a tree, shortest dir first
  default                                 The slug with no 'dir' (the default identity)
  get <slug> <field>                      One resolved field (see identities.conf.example for the list);
                                           'tag' is the ssh tag (empty when the plain key already matches)
  show <slug>                             Every resolved field for one identity
  for [directory]                         The slug that owns a tree (default: $PWD)
  check                                   Validate the registry; non-zero and a message per problem on error
  file                                    Path to the registry in effect ($DEVBOX_IDENTITIES_FILE)
  org-urls <slug>                         hasconfig: URL patterns its 'orgs' match
  alias-remotes                           Clones still on a git@<slug>.<host>: remote from the SSH-alias era
  render ssh-config                       ~/.ssh/config's per-host and per-tag blocks
  render agent-gitconfig [slug]           The root agent.gitconfig, or one identity's [user] block
  render user-gitconfig <slug>            One identity's own gitconfig for its tree ([user] only)
  render org-gitconfig <slug>             One identity's own gitconfig for its orgs ([user] + ssh tag)
  render allowed-signers                  ~/.ssh/allowed_signers, one line per identity with a signing key
```

Installed at `~/.local/libexec/devbox-identities` by `container/bootstrap.sh` and `bin/install-agent`; also
sourceable as a library (`. devbox-identities`) by scripts that need `di_slugs`, `di_default`, `di_get`,
`di_for` or the renderers directly, which is how `bootstrap.sh`, `bin/devbox keys` and `bin/laptop-doctor`
read the registry. `DEVBOX_IDENTITIES_FILE` overrides the config path (used by `bin/sync-identities` to
validate the laptop's copy before syncing it); `DEVBOX_IDENTITIES_TEMPLATE_DIR` points `render
agent-gitconfig` at `agent.gitconfig.tpl` when it isn't at the default `~/.config/devbox/git`.

```bash
devbox-identities list                    # one slug per line, e.g. personal, work
devbox-identities get work dir             # ~/projects/work
devbox-identities get work tag             # work, or empty if it shares the host's plain key
devbox-identities for ~/projects/work/app  # work (longest matching dir prefix wins)
devbox-identities check || echo 'fix identities.conf before bootstrapping'
```

## ❓ FAQ

**Why plain bash instead of bashly?**
Ten commands, no code-generation step needed - `bin/src` plus `pnpm run build:cli` would be pure overhead.
Keep it hand-written.

**Can I run `bin/devbox` from the laptop?**
No - it drives the local Docker daemon. Use `ssh <workstation> 'cd ~/devbox && ./bin/devbox <cmd>'`, or
`./bin/push --up` for the common case.

**Is `--delete` dangerous?**
Only applies to synced paths - `.env`, `data/` and `.git` are excluded. Files added to a *tracked*
directory's remote copy are removed; intentional, the remote is a mirror.

**`up` vs `rebuild` - which do I need?**
`up` after a compose, `.env`, `container/` or `home/` change - rebuilds changed layers. `rebuild` for a
cache-free image, e.g. after bumping a pinned version.

**Does `bootstrap` overwrite my dotfiles?**
Only the three generated ones - `~/.bashrc.d/devbox.sh`, `~/.bash_profile` and `~/.ssh/config` - rewritten
from templates every run. `~/.gitconfig`, `secrets.env`, `identities.conf` and the OMP config: created if
absent, then left alone; derived identity-registry values re-apply via `git config --global` each run.

**`doctor` says `BIND_ADDR is X but Tailscale reports Y`.**
The node's Tailscale address changed. `./bin/devbox env && ./bin/devbox up`.

**How do I tell whether the project Docker daemon is provisioned?**
`sudo ./bin/rootless-docker --check` reports every missing piece, changes nothing. `./bin/devbox doctor`
also checks the daemon is reachable and rootless from inside the container.
