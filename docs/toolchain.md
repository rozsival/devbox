# 🧰 Toolchain

`ubuntu:26.04` plus a pinned toolchain: every external binary has an explicit `ARG <TOOL>_VERSION` in the
`Dockerfile`, checksum-verified where upstream publishes one.

## Pinned versions

| Tool             | Version   | Installed as                                       |
|------------------|-----------|----------------------------------------------------|
| `herdr`          | `0.9.0`   | `/usr/local/bin/herdr`                             |
| `node`           | `24.21.0` | nvm in `/opt/nvm`, symlinked into `/usr/local/bin` |
| `pnpm`           | `12.4.1`  | `npm install -g`, symlinked into `/usr/local/bin`  |
| `gh`             | `2.100.0` | pinned `.deb`                                      |
| `lazygit`        | `0.65.0`  | `/usr/local/bin/lazygit` (alias `lg`)              |
| `wt` (worktrunk) | `0.77.0`  | `/usr/local/bin/wt` + `git-wt`                     |
| `terraform`      | `1.16.2`  | `/usr/local/bin/terraform`                         |
| `nvm`            | `0.40.7`  | `/opt/nvm`                                         |
| Docker CLI       | `29.8.0`  | `/usr/local/bin/docker`                            |
| Compose plugin   | `5.5.1`   | `/usr/local/lib/docker/cli-plugins/docker-compose` |
| Buildx plugin    | `0.37.1`  | `/usr/local/lib/docker/cli-plugins/docker-buildx`  |

Also from the Ubuntu archive: `git`, `git-lfs`, `starship`, `ripgrep`, `fd` (symlinked from `fdfind`), `jq`,
`curl`, `rsync`, `build-essential`, `python3`, `openssh-server`/`-client`, `nano`, `less`, `procps`,
`iproute2`, `socat` (backs `devbox-ports`, see [Project containers](#project-containers)).

Deliberately absent: **`op`** (no 1Password account here) and **`gcloud`** (projects reach Google APIs via
a per-project service-account key; ADC needs only the key file) - see [Secrets](secrets.md).

Check what's running - `doctor` fails on a tool's real exit code, not a blank line:

```bash
ssh <workstation> 'cd ~/devbox && ./bin/devbox doctor'
```

## Why tools live where they do

- **`/usr/local/bin`** - default *non-interactive* SSH `PATH`; `herdr` needs it since non-interactive SSH
  uses only a pre-existing compatible binary and never installs - true of saved-machine background
  connections.
- **`/opt/nvm` + `/opt/corepack`** (not `~/.nvm`) - `/home/dev`'s bind mount would shadow anything the
  image installs there; `node`, `npm`, `npx`, `corepack`, `pnpm` symlink into `/usr/local/bin` to resolve
  without a login shell.
- **`~/.local/bin`** - OMP and `moshi-hook`, installed by `bootstrap` rather than baked in, so `omp update`
  and `moshi-hook update` work without a rebuild. Also `devbox-gh-token`, the per-directory GitHub token resolver
  ([Secrets](secrets.md#gh)).
- **`~/.local/libexec/devbox-agent`** - `omp-launcher`, the `gh` shim, and two git-fencing scripts
  (`devbox-git-credential`, `devbox-git-no-ssh`), plus an `omp` symlink to the launcher.
  `home/.bashrc.d/devbox.sh` puts it first on every devbox shell's `PATH`, shadowing `gh` and `omp`; the
  launcher does likewise for one process tree elsewhere, including the laptop (`./bin/install-agent`).
  `home/.bash_profile` re-asserts that order for login shells, where the distro's `~/.profile` prepends
  `~/.local/bin` *after* sourcing `~/.bashrc` and would otherwise put the real `omp` in front. See
  [Git identities](git.md#agent-sessions).
- **`/usr/local/lib/docker/cli-plugins`** - home for `docker compose`/`docker buildx` as CLI plugins; only
  the client ships in the image, the daemon is the host's rootless `dev` daemon (below).

## Project containers

Projects with their own containers reach Docker via a second, rootless host daemon, never one nested here -
see [Docker](docker.md) for the model and `sudo ./bin/rootless-docker` setup.

```bash
docker compose up -d
devbox-ports            # mirrors published ports onto 127.0.0.1
```

Keep `DOCKER_CLI_VERSION` equal to the host daemon's - compose refuses an API newer than its server.

## OMP

```bash
omp                 # TUI
omp --version
omp update          # updates ~/.local/bin/omp in place; no image rebuild
```

`omp` on the `PATH` is the agent launcher, not the binary; `omp update` passes through to the real install
it shadows, which is why the launcher survives an update. See
[Git identities](git.md#omp-update).

`~/.omp/agent/config.yml` seeds from `home/.omp/agent/config.yml` only if absent, with
`secrets: { enabled: true }` obfuscating an API key in the environment - `~/.config/devbox/secrets.env` or
a project `.env` - before it reaches a provider. Your edits are never overwritten.

Local workstation-served models are opt-in: copy your model-serving repo's `harnesses/omp.yml` into
`~/.omp/agent/models.yml`, pointing the provider `baseUrl` at the workstation's Tailscale address.

Sync the laptop's preset so devbox panes share model roles, theme and feature flags:

```bash
./bin/sync-omp              # laptop → devbox:~/.omp/agent/config.yml
./bin/sync-omp devbox-2     # a different ~/.ssh/config host
```

Only `config.yml` moves; `agent.db`, `history.db`, `sessions/`, `memories/` and `models.yml` stay
per-machine, untouched. The prior file is kept as `config.yml.bak`; a running session needs a restart for
the new preset.

## Moshi and `moshi-hook`

[Moshi](https://getmoshi.app) connects like any SSH client (`BIND_ADDR:2223`, user `dev`, authorized key)
for a terminal and herdr panes only - not push notifications, lock-screen approvals or Chat View, which
need `moshi-hook`, a companion daemon `bootstrap` installs into `~/.local/bin` and the entrypoint starts.

| Piece                       | Where it lives                             | What breaks without it          |
|-----------------------------|--------------------------------------------|----------------------------------|
| `moshi-hook` binary         | `~/.local/bin` (bind mount, self-updating) | Everything below                |
| OMP extension               | `~/.omp/agent/extensions/moshi-hooks.ts`   | No lifecycle events emitted     |
| Daemon (`moshi-hook serve`) | Started by `container/entrypoint.sh`       | Events go nowhere; socket silence |
| Pairing                     | One manual `moshi-hook pair --token`       | Daemon runs, sends nothing to a phone |

OMP is a Tier A Moshi agent: pairing brings the inbox, approvals and native transcript view, not just
completion pings.

Pairing is the one manual step: the token is per-account, belongs to the phone, not the repo:

```bash
ssh devbox 'moshi-hook pair --token <token from Settings → Hooks in the app>'
ssh <workstation> 'cd ~/devbox && ./bin/devbox hook'   # restart so it picks the pairing up
```

`bootstrap` flags pairing as outstanding until done; `doctor` reports it running-but-unpaired. Pairing
state survives rebuilds under the bind-mounted home like other credentials.

No systemd means `moshi-hook service install` can't be used - `container/entrypoint.sh` starts the daemon,
tying its lifetime to the container's. Restart a crashed/hand-killed one with `./bin/devbox hook` (a
detached `docker compose exec`: no recreate, no dropped SSH sessions); `./bin/devbox up` alone won't revive
it unless compose recreates the container.

A second daemon is harmless: `serve` exits with `another moshi-hook serve is already running (pid N, lock
…)`, and a killed daemon's lock never blocks the next start, even across PID reuse.

Moshi also needs the daemon's gateway `127.0.0.1:24543`, reached over its own SSH connection - already
permitted by `AllowTcpForwarding yes` in `container/sshd_config` - so nothing new is published.

```bash
moshi-hook status                    # pairing, multiplexers, per-agent hook state
moshi-hook logs -f                   # ~/.local/state/moshi/hook.log
moshi-hook install --target omp      # rewrite the OMP extension after an update
```

## Agent skills and browser automation

Optional, recommended, and not in `bootstrap` since the first run downloads a ~180 MB Chrome build:

```bash
ssh <workstation> 'cd ~/devbox && ./bin/devbox skills'
```

`container/skills.sh` installs three skills with `--global --agent universal`, landing them only in
`~/.agents/skills` - the directory every agent here reads:

| Skill           | Source                      | What it is for                                       |
|-----------------|------------------------------|-------------------------------------------------------|
| `agent-browser` | `vercel-labs/agent-browser` | Browser automation: navigate, fill, screenshot, test |
| `skill-creator` | `anthropics/skills`         | Authoring, editing and evaluating skills             |
| `find-skills`   | `vercel-labs/skills`        | Discovering and installing more skills mid-task      |

Also installs the pinned `agent-browser` CLI and Chrome build:

```bash
agent-browser open https://example.com
agent-browser snapshot          # accessibility tree, with refs to act on
agent-browser close
```

Why this works unprivileged:

- **Chrome's shared libraries are in the image.** `agent-browser install --with-deps` needs root `apt-get`,
  unavailable to `dev`, so the ~26 packages Chrome links against are baked into the `Dockerfile` - the
  headless set, omitting GTK, Vulkan and CJK fonts on purpose (~300 MB).
- **The npm prefix is per call, not exported.** `npm install -g --prefix "$HOME/.local"` lands the binary
  in `~/.local/bin`, on the non-interactive `PATH` and bind mount, unlike a global install under
  `/opt/nvm`. Exporting `NPM_CONFIG_PREFIX` (or setting `prefix=` in `~/.npmrc`) instead makes nvm refuse
  its default Node in every interactive shell - do neither.
- **Chrome lives in `~/.agent-browser/browsers`.** Also the bind mount, so rebuilds skip re-download.

Re-running `./bin/devbox skills` is safe: npm and `npx skills add` overwrite in place, Chrome skips if
present. Bump `SKILLS_CLI_VERSION`/`AGENT_BROWSER_VERSION` in `container/skills.sh` to move a pin, or
export either for one run.

## Node and pnpm

```bash
node -v      # v24.21.0
pnpm -v      # 12.4.1
```

pnpm installs via `npm install -g pnpm@12.4.1`, not `corepack prepare`: pnpm 12's JS wrapper loads a native
binary from its own `node_modules`, but corepack's cache held only the wrapper - every shimmed call
re-downloaded it. `corepack` stays enabled for `yarn`, with `COREPACK_HOME` set so repos declaring
`packageManager` still work.

## Worktrees

`wt` (worktrunk) is shell-integrated by `bootstrap`, so `wt switch` can change the current directory:

```bash
wt switch -c smoke     # create a worktree and cd into it
wt switch main         # back
wt list
```

Run `wt switch` directly, not piped: inside `cmd | tail` it runs in a subshell whose `cd` can't reach your
shell.

## Adding a tool

1. Add `ARG <TOOL>_VERSION=<version>` next to the others in the `Dockerfile`.
2. One install block: `curl -fsSL` to a temp dir, verify the published checksum, `install -m 0755` into
   `/usr/local/bin`.
3. Add a probe to `doctor`'s list in `bin/devbox` if the version matters.
4. `./bin/push <workstation> && ssh <workstation> 'cd ~/devbox && ./bin/devbox rebuild'`.

Never invent a hash: without a published checksum file (`herdr`), pinned version plus TLS is the contract.

Host-specific tweaks go in `docker-compose.override.yml`: compose auto-loads it, gitignored, so extra
mounts, env vars or resource limits stay local to one workstation.

## ❓ FAQ

**Can I `apt-get install` something inside the container?**
No - `dev` has no root or sudo, by design: the image records what exists. Add it to the `Dockerfile` and
rebuild; for throwaway tools use `pnpm dlx` or `python3 -m venv`.

**Can I run Docker inside the devbox?**
Yes, via a second rootless daemon owned by a dedicated user - see [Docker](docker.md). The host's root
socket stays unmounted; nesting is impossible: rootless docker needs setuid helpers
`newuidmap`/`newgidmap`, ruled out by `cap_drop: [ALL]` and `no-new-privileges`.

**Does `rebuild` destroy my data?**
No - the image rebuilds from scratch; `/home/dev` is a host bind mount, untouched. Only things installed
*into the image* disappear.

**Why are `omp` and `moshi-hook` not pinned in the image?**
So updates work without a rebuild: `bootstrap` installs both into `~/.local/bin` only if `command -v`
fails, never overwriting an install already there - a build-time pin would be shadowed on `PATH` and
falsified by self-update anyway. `ARG <TOOL>_VERSION`'s only two exceptions. `moshi-hook` still gets
checksum-verified: `bootstrap` fetches upstream's `latest` tarball plus `checksums.txt`, runs
`sha256sum -c` - upstream's installer skips verification without one.

**A different Node version for one project?**
`nvm install <version>` works normally - writes to `/opt/nvm`, writable by `dev`, persisting until the
next rebuild. Pin the default by bumping `NODE_VERSION`.

**`starship` prompt is missing over `ssh devbox '<cmd>'`?**
Expected - prompt, aliases and nvm loading are interactive-guarded in `home/.bashrc.d/devbox.sh`. `PATH`
isn't guarded, so tools still resolve.

**`nvm is not compatible with the "NPM_CONFIG_PREFIX" environment variable` on every login?**
Something exported `NPM_CONFIG_PREFIX` (an earlier `home/.bashrc.d/devbox.sh` did), and nvm's
`nvm_die_on_prefix` refuses the default Node. `unset NPM_CONFIG_PREFIX` clears the shell; fix with
`--prefix` on each `npm i -g` call.

**Why not install the skills for every agent with `--agent '*'`?**
It symlinks them into ~45 per-agent dotdirs (`~/.aider-desk/skills`, `~/.astrbot/data/skills`, etc.) for
tools not installed here, reporting `Failed to install 2` for two rejecting global installs. `--agent
universal` writes only `~/.agents/skills`; add `--agent claude` for one reading its own directory.

**Does `agent-browser` need `--no-sandbox` here?**
No - it launches and drives Chrome headless as `dev` with `cap_drop: [ALL]` unchanged, verified via
`agent-browser open` plus `snapshot`. Headed mode needs the omitted GTK packages and a virtual display.

**Do the skills survive a rebuild?**
Yes - `~/.agents/skills` is on the bind mount. Only Chrome's shared libraries live in the image, rebuilt
with it; `npx skills update --global -y` refreshes the skills themselves.
