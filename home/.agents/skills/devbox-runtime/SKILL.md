---
name: devbox-runtime
description: How to work in the machine this agent session runs on - the devbox container (remote, unprivileged Ubuntu sandbox) or the user's macOS laptop - and how the two relate. Use it whenever DEVBOX_ENV matters to a decision - installing a tool, running Docker or a dev server, giving the user a URL or port, a path that may only exist on the other machine, a git or gh authentication failure, a secret or vault-rendered file that is missing - and whenever you catch yourself assuming root, sudo, the user's own credentials or the other machine's files.
---

# Working in the devbox and on the laptop

`DEVBOX_ENV` (set by the `omp`/`claude` launcher) says where this session runs: `devbox` or `laptop`. Your context
already holds a short summary for this machine. This skill covers what to do about it.

```
laptop (macOS)                         workstation (Ubuntu host)            container "devbox"
the user, 1Password, herdr client  --ssh over Tailscale-->  BIND_ADDR:2223  -->  sshd as dev, agents, /home/dev
                                                            rootless dockerd (uid 1001)  <--socket--  docker CLI
```

The laptop's `~/projects` and the devbox's `/home/dev/projects` are different trees. Nothing syncs them except git.

## On the devbox

### A tool is missing

1. Check the PATH a login shell sees: `bash -lc 'command -v <tool>'`. Pinned tools live in `/usr/local/bin`; nvm,
   rustup and Ruby live under `/opt`.
2. Per-user installs work and survive rebuilds when they land under `/home/dev`:
   - `npm i -g --prefix ~/.local <pkg>`; never export `NPM_CONFIG_PREFIX`, because nvm refuses to activate with it set
   - `cargo install --root ~/.local <crate>`; bare `cargo install` writes to `CARGO_HOME=/opt/cargo`, lost on a rebuild
   - `gem install --user-install <gem>`
   - `pipx` or `uv tool` when they exist, or a project-local virtualenv
3. A system package (`apt-get`) needs root, and there is none. Don't look for one: no `sudo`, no setuid helpers, and
   `docker run -v /:/host` reaches only a rootless daemon that has no host root. Propose the change instead: an
   `apt-get install` line or a pinned `ARG <TOOL>_VERSION` block in the devbox repo's `Dockerfile`, followed by
   `./bin/devbox rebuild` on the workstation, which the user runs.

### Docker

- `docker` and `docker compose` reach a sibling rootless daemon through `/run/devbox/docker.sock`. It is not
  Docker-in-Docker and not the host's daemon.
- **Path identity:** the daemon resolves bind-mount sources on the host, where `/home/dev` is the same path. Mounts from
  `/tmp`, `/opt` or anywhere outside `/home/dev` silently resolve to the host's own directories.
- Files a container writes as its own unprivileged user (postgres as uid 999) come out owned by a subordinate uid that
  `dev` can't read. Prefer named volumes for database data.
- **Reaching a published port:** from this shell, use `host.docker.internal:<port>`, or run `devbox-ports` once per new
  service to mirror every published port onto `localhost:<port>` (`devbox-ports status`, `devbox-ports stop`).
- **`127.0.0.1:<port>:<port>` in a compose file** binds the host's loopback, which nothing here can reach. Make the
  address a variable (`${DOCKER_BIND_IP:-127.0.0.1}`) and set `DOCKER_BIND_IP=172.17.0.1` in the project's devbox
  `.env`; laptops leave it unset.
- `--network host` shares the **workstation's** network namespace, not this container's: its `localhost` is the
  workstation's, and what it listens on does not appear on this container's `localhost`. The firewall still keeps its
  processes off the workstation's own services and the Tailnet. `--privileged` is privileged only inside the rootless
  daemon's user namespace, never host root.

### Dev servers and URLs

The user's browser is on the laptop. A server listening here on `localhost:<port>` reaches them only through a
tunnel they run on the laptop:

```bash
ssh -N -L <port>:localhost:<port> devbox                # a port in the devbox, or one devbox-ports mirrors
ssh -N -L <port>:host.docker.internal:<port> devbox     # a project-container port without the mirror
```

Give the user that command with the URL. Never tell them to open `http://<workstation>:<port>`: nothing is published
beyond SSH. For your own browser checks, `agent-browser` runs a headless Chrome inside the devbox, if it was installed
with `./bin/devbox skills`.

### Secrets

- Every shell sources `~/.config/devbox/secrets.env` and then unsets the per-identity `GH_TOKEN_<SLUG>` PATs again
  (`devbox-gh-token` reads those from the file), which leaves any model API keys in the environment.
- There is no `op` (1Password) and no `gcloud`. A vault-rendered file such as `.env.local` from `op inject` or
  `pnpm run env:inject` is generated on the laptop and copied in by the user. Ask for it; don't stub the values.

### Persistence

`/home/dev` is a host bind mount and survives everything. `/tmp` is a tmpfs mounted `noexec`, gone on every container
restart: `chmod +x /tmp/x && /tmp/x` fails with "Permission denied", so run `bash /tmp/x` or use `mktemp -d -p "$HOME"`
(and clean it up). Anything installed outside `/home/dev` is lost on a rebuild. Background processes die with the
container. herdr restores the pane layout, not the processes.

## On the laptop

- macOS with a BSD userland: `sed -i ''`, `stat -f`, `date -j`, and no `grep -P` or `readlink -f` on old systems.
  Check `command -v gsed gstat` before assuming GNU behaviour.
- This is the user's own machine. Their SSH keys sit in 1Password, their `gh` OAuth login sits in the keychain, and
  their dotfiles are live. The launcher hides all of that from this session on purpose. The guardrail denies
  `security find-*-password`, `gh auth token` and absolute-path `gh`, and `op` prompts. Don't route around them.
- **Reaching the devbox:** `ssh devbox '<cmd>'` works but makes 1Password prompt the user for approval. Use it only
  when they ask for something to happen on the devbox, and remember the paths there differ.
- Agent git and `gh` behave exactly as on the devbox (next section).

## Git and GitHub (both machines)

- The launcher sets `GIT_CONFIG_GLOBAL` to a read-only agent gitconfig. Remotes are rewritten to HTTPS and answered by
  `devbox-git-credential` with the repository's GitHub App installation token, or a read-only PAT where no App is
  installed. Commits carry the identity's bot author and are unsigned. That is intended; never set `user.name` or
  `user.email` and never `git config --global`.
- Remotes may be SSH URLs (the user's own clones): the agent gitconfig rewrites the covered hosts to HTTPS, so leave
  every remote URL alone. Only a remote the rewrite does not cover reaches ssh, and that fails with a one-line
  explanation from `devbox-git-no-ssh`. That is the fence working, not a bug to work around.
- `gh` is a shim that picks the token per working directory. Inside a checkout, repository commands use the App token.
  Never run `gh auth login`.
- **Diagnosing a 403 or a missing repo:** `devbox-git-credential explain <owner>/<repo>` names the identity and whether
  an App or the PAT answers. A read-only PAT can't push: the identity needs its App installed on that repository. Tell
  the user; don't swap credentials.
- **Wrong author on a commit:** a clone's own `[user]` section outranks the agent author (`git config --local --list`).
  Report it rather than rewriting history.

## When unsure

Check rather than guess: `echo $DEVBOX_ENV`, `uname -s`, `ls /etc/devbox-env`, `command -v <tool>`. When an action only
makes sense on the other machine, say so and hand the user the exact command to run there.
