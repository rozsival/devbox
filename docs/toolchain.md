# 🧰 Toolchain

`ubuntu:26.04` plus a pinned toolchain. Every external binary comes from an explicit
`ARG <TOOL>_VERSION` in the `Dockerfile` and is checksum-verified where upstream publishes a checksum file.

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

Plus from the Ubuntu archive: `git`, `git-lfs`, `starship`, `ripgrep`, `fd` (symlinked from `fdfind`), `jq`,
`curl`, `rsync`, `build-essential`, `python3`, `openssh-server`/`-client`, `nano`, `less`, `procps`,
`iproute2`, `socat` (backs `devbox-ports`, see [Project containers](#project-containers)).

Deliberately absent: **`op`** (the container holds no 1Password account) and **`gcloud`** (projects reach
Google APIs through a per-project service-account key, and ADC needs only the key file). Both decisions and
their reasoning are in [Secrets](secrets.md).

Print what is actually running:

```bash
ssh workstation 'cd ~/devbox && ./bin/devbox doctor'
```

`doctor` probes each tool with its real exit code - a missing tool fails the command rather than printing a
blank line.

## Why tools live where they do

- **`/usr/local/bin`** - the default *non-interactive* SSH `PATH`. `herdr` must be here: it prefers a
  compatible binary already on the remote `PATH` and non-interactive runs fail rather than installing, which
  is exactly how saved-machine background connections run.
- **`/opt/nvm` + `/opt/corepack`** (not `~/.nvm`) - `/home/dev` is a bind mount that would shadow anything the
  image installed under the home directory. `node`, `npm`, `npx`, `corepack` and `pnpm` are symlinked into
  `/usr/local/bin` so they resolve without a login shell.
- **`~/.local/bin`** - OMP and `moshi-hook`, installed by `bootstrap` instead of baked into the image so
  `omp update` and `moshi-hook update` work without a rebuild.
- **`/usr/local/lib/docker/cli-plugins`** - where `docker compose` and `docker buildx` live as CLI plugins.
  Only the client ships in the image; the daemon is the host's rootless `dev` daemon (see below).

## Project containers

Projects that bring their own containers reach Docker through a second, rootless daemon on the host, never
through a daemon nested in this container. See [Docker](docker.md) for the full model and the one-time
`sudo ./bin/rootless-docker` setup.

```bash
docker compose up -d
devbox-ports            # mirrors published ports onto 127.0.0.1
```

Keep `DOCKER_CLI_VERSION` in the `Dockerfile` equal to the host daemon's version - compose refuses to talk
to an API newer than the server it reaches.

## OMP

```bash
omp                 # TUI
omp --version
omp update          # updates in place; no image rebuild
```

`~/.omp/agent/config.yml` is seeded from `home/.omp/agent/config.yml` only if absent, with
`secrets: { enabled: true }` so an API key in the environment - from `~/.config/devbox/secrets.env` or a
project `.env` - is obfuscated before it can reach a provider. Your edits are never overwritten.

Local workstation models are opt-in: copy `harnesses/omp.yml` from the `workstation` repo into
`~/.omp/agent/models.yml` inside the devbox and point the provider `baseUrl` at the workstation's Tailscale
address.

Syncing the preset from the laptop, so panes in the devbox use the same model roles, theme and feature
flags:

```bash
./bin/sync-omp              # laptop → devbox:~/.omp/agent/config.yml
./bin/sync-omp devbox-2     # a different ~/.ssh/config host
```

Only `config.yml` moves. `agent.db`, `history.db`, `sessions/`, `memories/` and `models.yml` are
per-machine state and are never touched. The previous file is kept as `config.yml.bak` on the devbox, and a
running OMP session has to be restarted to pick the new preset up.

## Moshi and `moshi-hook`

[Moshi](https://getmoshi.app) is a phone terminal that connects to the devbox like any other SSH client -
`BIND_ADDR:2223`, user `dev`, an authorized key. That alone gives a terminal and herdr panes. It does *not*
give push notifications, lock-screen approvals or Chat View: those come from `moshi-hook`, a companion
daemon that `bootstrap` installs into `~/.local/bin` and the entrypoint starts.

| Piece                       | Where it lives                            | What breaks without it                  |
|-----------------------------|-------------------------------------------|-----------------------------------------|
| `moshi-hook` binary         | `~/.local/bin` (bind mount, self-updating) | Everything below                        |
| OMP extension               | `~/.omp/agent/extensions/moshi-hooks.ts`   | No lifecycle events are emitted at all  |
| Daemon (`moshi-hook serve`) | Started by `container/entrypoint.sh`       | Events go nowhere; socket-only silence  |
| Pairing                     | One manual `moshi-hook pair --token`       | Daemon runs but sends nothing to a phone |

OMP is a Tier A agent for Moshi, so a paired devbox gets the inbox, approvals and the native transcript
view, not just completion pings.

Pairing is the one manual step - the token is per-account and belongs to the phone, not the repo:

```bash
ssh devbox 'moshi-hook pair --token <token from Settings → Hooks in the app>'
ssh workstation 'cd ~/devbox && ./bin/devbox hook'   # restart so it picks the pairing up
```

`bootstrap` prints the pairing as a remaining manual step until it is done, and `./bin/devbox doctor`
reports the daemon as running-but-unpaired. Pairing state is written under the bind-mounted home, so it
survives container and image rebuilds like every other credential there.

There is no systemd in the container, so `moshi-hook service install` cannot be used - `container/entrypoint.sh`
starts the daemon instead. The consequence is that the daemon's lifetime is the container's, and a crashed
or hand-killed daemon is restarted with `./bin/devbox hook`, which is a detached `docker compose exec`:
no recreate, no dropped SSH sessions. `./bin/devbox up` will *not* revive it unless compose decides to
recreate the container.

Starting a second daemon is harmless - `serve` exits with `another moshi-hook serve is already running
(pid N, lock …)`. A lock left behind by a killed daemon does not block the next start, including when the
container's fresh PID numbering has handed that PID to an unrelated process.

The app also needs the daemon's gateway on `127.0.0.1:24543`; Moshi forwards it over its own SSH connection,
which `AllowTcpForwarding yes` in `container/sshd_config` already permits. Nothing new is published.

```bash
moshi-hook status                    # pairing, multiplexers, per-agent hook state
moshi-hook logs -f                   # ~/.local/state/moshi/hook.log
moshi-hook install --target omp      # rewrite the OMP extension after an update
```

## Agent skills and browser automation

Optional, recommended, and not part of `bootstrap` because the first run downloads a ~180 MB Chrome build:

```bash
ssh workstation 'cd ~/devbox && ./bin/devbox skills'
```

`container/skills.sh` installs three skills with `--global --agent universal`, which puts them in
`~/.agents/skills` and nowhere else - the directory OMP and every other agent here reads:

| Skill           | Source                      | What it is for                                       |
|-----------------|-----------------------------|------------------------------------------------------|
| `agent-browser` | `vercel-labs/agent-browser` | Browser automation: navigate, fill, screenshot, test |
| `skill-creator` | `anthropics/skills`         | Authoring, editing and evaluating skills             |
| `find-skills`   | `vercel-labs/skills`        | Discovering and installing more skills mid-task      |

It also installs the pinned `agent-browser` CLI and its Chrome build:

```bash
agent-browser open https://example.com
agent-browser snapshot          # accessibility tree, with refs to act on
agent-browser close
```

Three things make this work in an unprivileged container:

- **Chrome's shared libraries are in the image.** `agent-browser install --with-deps` shells out to
  `apt-get` as root, which `dev` cannot do, so the ~26 packages Chrome links against are installed in the
  `Dockerfile`. This is the headless set - GTK, Vulkan and CJK fonts are omitted on purpose (~300 MB).
- **The npm prefix is per call, not exported.** `npm install -g --prefix "$HOME/.local"`, so the binary
  lands in `~/.local/bin`: on the non-interactive `PATH` and on the bind mount, unlike a global install
  under `/opt/nvm`. Exporting `NPM_CONFIG_PREFIX` (or setting `prefix=` in `~/.npmrc`) instead makes nvm
  refuse to activate its default Node in every interactive shell, so do neither.
- **Chrome itself lives in `~/.agent-browser/browsers`.** Also the bind mount, so a rebuild does not
  re-download it.

Re-running `./bin/devbox skills` is safe: npm and `npx skills add` overwrite in place and Chrome is skipped
when already present. Bump `SKILLS_CLI_VERSION` or `AGENT_BROWSER_VERSION` in `container/skills.sh` to move
a pin, or export either variable to move one for a single run.

## Node and pnpm

```bash
node -v      # v24.21.0
pnpm -v      # 12.4.1
```

pnpm is installed with `npm install -g pnpm@12.4.1` rather than `corepack prepare`, because pnpm 12 ships a JS
wrapper that loads a native binary from its own `node_modules`; the corepack cache holds only the wrapper, so
every shimmed call re-downloaded the binary. `corepack` itself stays enabled for `yarn`, and `COREPACK_HOME`
is set so repos declaring `packageManager` still work.

## Worktrees

`wt` (worktrunk) is shell-integrated by `bootstrap`, so `wt switch` can change the current directory:

```bash
wt switch -c smoke     # create a worktree and cd into it
wt switch main         # back
wt list
```

Run `wt switch` directly, not in a pipeline - inside `cmd | tail` it executes in a subshell and its `cd`
cannot reach your shell.

## Adding a tool

1. Add `ARG <TOOL>_VERSION=<version>` next to the others in the `Dockerfile`.
2. Add one install block: `curl -fsSL` to a temp dir, verify the published checksum, `install -m 0755` into
   `/usr/local/bin`.
3. Add the probe to the `doctor` list in `bin/devbox` if the version matters.
4. `./bin/push workstation && ssh workstation 'cd ~/devbox && ./bin/devbox rebuild'`.

Never invent a hash: when upstream publishes no checksum file (`herdr`), the pinned version plus TLS is the
contract.

Host-specific tweaks that should not live in the image go in `docker-compose.override.yml`: compose picks it
up automatically and it is gitignored, so extra mounts, environment variables or resource limits stay local
to one workstation.

## ❓ FAQ

**Can I `apt-get install` something inside the container?**
No - `dev` is not root and there is no sudo. That is deliberate: the image is the record of what exists. Add
it to the `Dockerfile` and rebuild. For throwaway tools, prefer `pnpm dlx` or `python3 -m venv`.

**Can I run Docker inside the devbox?**
Yes, via a second rootless daemon owned by a dedicated host user - see [Docker](docker.md). The host's own
root daemon socket is still not mounted, and nesting a daemon in the container remains impossible: rootless
docker needs the setuid helpers `newuidmap`/`newgidmap`, which `cap_drop: [ALL]` and `no-new-privileges` rule
out.

**Does `rebuild` destroy my data?**
No. The image is rebuilt from scratch; `/home/dev` is a bind mount on the host and untouched. Only things
installed *into the image* disappear.

**Why are `omp` and `moshi-hook` not pinned in the image?**
So `omp update` and `moshi-hook update` work without a rebuild. `bootstrap` installs both into
`~/.local/bin` if `command -v` fails, and never overwrites an existing install - a version pinned at build
time would be shadowed on `PATH` by that copy anyway, and falsified by the first self-update. They are the
only two exceptions to the `ARG <TOOL>_VERSION` rule at the top of this page. `moshi-hook` is still
checksum-verified: `bootstrap` resolves upstream's `latest` pointer, then fetches the tarball *and*
`checksums.txt` for that one version and runs `sha256sum -c`, because upstream's own installer skips
verification when the checksum file cannot be fetched.

**A different Node version for one project?**
`nvm install <version>` works normally - it writes to `/opt/nvm`, which is writable by `dev` and persists
until the next image rebuild. Pin the default by bumping `NODE_VERSION`.

**`starship` prompt is missing over `ssh devbox '<cmd>'`?**
Expected - the prompt, aliases and nvm loading are interactive-guarded in `home/.bashrc.d/devbox.sh`. `PATH`
is not guarded, so tools still resolve.

**`nvm is not compatible with the "NPM_CONFIG_PREFIX" environment variable` on every login?**
Something exported `NPM_CONFIG_PREFIX` (an earlier revision of `home/.bashrc.d/devbox.sh` did). nvm's
`nvm_die_on_prefix` then refuses to activate the default Node. `unset NPM_CONFIG_PREFIX` clears the current
shell; the fix is to pass `--prefix` on the individual `npm i -g` call instead.

**Why not install the skills for every agent with `--agent '*'`?**
It symlinks them into ~45 per-agent dotdirs - `~/.aider-desk/skills`, `~/.astrbot/data/skills` and so on -
for tools that are not installed here, and reports `Failed to install 2` for two that reject global
installs. `--agent universal` writes `~/.agents/skills` only. Add a specific agent (`--agent claude`) if you
install one that reads its own directory.

**Does `agent-browser` need `--no-sandbox` here?**
No. It launches and drives Chrome headless as `dev` with `cap_drop: [ALL]` unchanged; verified with
`agent-browser open` plus `snapshot`. Headed mode is what needs the omitted GTK packages and a virtual
display.

**Do the skills survive a rebuild?**
Yes - `~/.agents/skills` is on the bind mount. Only the Chrome shared libraries live in the image, and they
are rebuilt with it. `npx skills update --global -y` refreshes the skills themselves.
