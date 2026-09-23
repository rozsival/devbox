# 🔗 Connecting

Four ways into the container, landing as `dev` in the same bind-mounted `/home/dev` - laptop and
workstation `~/projects` differ.

| Route                | From        | Use it for                                         |
|----------------------|-------------|----------------------------------------------------|
| `herdr`              | Laptop      | Normal work: survives client exit, network loss    |
| `ssh devbox`         | Laptop      | One-off commands, scripts, tunnels, `rsync`, `git` |
| Moshi                | Phone       | Watching, steering an agent away from the desk     |
| `./bin/devbox shell` | Workstation | Recovery when SSH or the network is broken         |

## herdr panes

```bash
herdr                    # select "Devbox" in the sidebar
```

A pane opens a login shell in `/home/dev`, running server-side after detach or quit - lid-close or
killed client won't interrupt a build, clone, or agent; reconnecting restores it.

`herdr` requires the pinned binary at `/usr/local/bin/herdr` - background connections get only the
default non-interactive SSH `PATH`, so it's missing from `~/.local/bin`.

## `ssh devbox`

`devbox` is an SSH config alias, not a shell alias ([Setup](setup.md#2-add-the-sshconfig-blocks)). Expands
to:

```bash
ssh -p 2223 -l dev -o IdentitiesOnly=yes -i ~/.ssh/devbox.pub <workstation>
```

Interactive, then one-shot; quote so `~` expands remotely, not on the laptop:

```bash
ssh devbox
ssh devbox 'cd ~/projects/devbox && git status -sb'
```

Anything reading `~/.ssh/config` honours it: `scp`, `rsync`, `git`, `ssh -L`.

Add `-A` to forward the laptop's 1Password agent for one connection - manual git needs it (clone, fetch,
push, signed commit; agent sessions use HTTPS instead - [Git identities](git.md)):

```bash
ssh -A devbox
```

Plain `ssh devbox` (no `-A`), herdr panes, `./bin/devbox shell` never forward the agent - manual git
fails, on purpose: [Git identities](git.md#manual-work-on-the-devbox---the-escape-hatch).

## `./bin/devbox shell`

```bash
ssh <workstation> 'cd ~/devbox && ./bin/devbox shell'   # docker compose exec -it devbox bash -l
```

This bypasses the container's sshd, working even if `authorized_keys`, the host key, or Tailscale is
broken.

## Moshi on a phone

Moshi's an SSH client: host `<workstation>`, port `2223`, user `dev`, container-authorized key. Add the
phone's key to `DEVBOX_EXTRA_AUTHORIZED_KEYS` in `.env` on the workstation, not via Easy Pair - the
entrypoint rebuilds `authorized_keys` from GitHub plus that variable each start, erasing direct edits at
the next `./bin/devbox up`.

Notifications, lock-screen approvals, and transcript view need `moshi-hook`, which `bootstrap` installs
and the entrypoint starts. One pairing step activates it - [Toolchain](toolchain.md#moshi-and-moshi-hook).

## Cloning a repo

Clone inside the container, agent forwarded, target directory picking the identity:

```bash
ssh -A devbox
git clone git@github.com:<your-github-username>/<repo> ~/projects/<repo>       # default identity
git clone git@work.github.com:<org>/<repo> ~/projects/work/<repo>              # non-default, alias required
```

Full rules - why a non-default identity's alias can't be skipped, how agent sessions authenticate without
it - in
[Git identities](git.md).

## Reaching a dev server

Dev servers aren't published - forward the port over the existing SSH connection:

```bash
# in a devbox pane
pnpm dev                                  # or python3 -m http.server 5173

# on the laptop
ssh -N -L 5173:localhost:5173 devbox &
curl -sS -o /dev/null -w '%{http_code}\n' localhost:5173    # 200
```

`AllowTcpForwarding yes` in `container/sshd_config` enables this. Add more `-L` pairs for more ports; no
`docker-compose.yml` changes.

## ❓ FAQ

**Do I clone on the laptop, the workstation, or in the container?**
In the container: the bind mount makes a repo cloned in a herdr pane visible over `ssh devbox` and
`./bin/devbox shell`, surviving `docker compose restart`.

**Is `ssh devbox` reachable from outside the Tailnet?**
No - the port publishes only on the node's Tailscale address and `127.0.0.1` ([Networking](networking.md)).

**Why does `git push` fail over plain `ssh devbox`?**
The devbox holds no private key; `-A` forwards the laptop's 1Password agent - see
[Git identities](git.md#manual-work-on-the-devbox---the-escape-hatch).

**`Too many authentication failures` - why?**
The agent offered more than six keys before the right one; `IdentitiesOnly yes` plus
`IdentityFile ~/.ssh/devbox.pub` in `Host devbox` fixes it.

**`Host key verification failed` after a rebuild?**
Shouldn't happen: the host key lives in `/home/dev/.ssh/host/`'s bind mount, surviving rebuilds. Wiped
data dir? Remove the stale line: `ssh-keygen -R '[<workstation>]:2223'`, reconnect.

**Moshi connected to my *laptop* and 1Password asked to use the Devbox Laptop key - why?**
Moshi's laptop host runs `herdr`, and every herdr client connects every saved machine itself: the new client
opens its own `ssh devbox` for the Devbox machine, and that is what 1Password is approving. Approve, and that
client shows the devbox through the laptop; deny, and only its Devbox entry sits at *Attention* - Local
panes, the desktop client and a direct phone → devbox connection are unaffected. The direct route above
involves neither the laptop nor 1Password, which is why it is the recommended one.

**Which tools resolve in a non-interactive `ssh devbox '<cmd>'`?**
All of them: pinned binaries in `/usr/local/bin` (`node`/`npm`/`npx`/`corepack`/`pnpm`, symlinked from
`/opt/nvm`); `~/.bashrc.d/devbox.sh` loads *above* Ubuntu's non-interactive early return, putting
`~/.local/bin` (OMP's install dir) on `PATH`, and `~/.bash_profile` reasserts that order for login shells,
where `~/.profile` would re-prepend `~/.local/bin` ahead of the agent launcher. Verify both routes:
`ssh devbox 'command -v omp node pnpm herdr'` and `ssh devbox 'bash -lc "command -v omp"'` - the second
must print `~/.local/libexec/devbox-agent/omp`, the launcher.

**Can I use VS Code / JetBrains Remote?**
Yes - point Remote-SSH at `devbox`: an OpenSSH server, `sftp` enabled.

**Does a pane keep running if the container restarts?**
No - the herdr server dies with the container; only the filesystem survives. herdr restores the shape,
but running processes are gone.
