# 🔗 Connecting

Four ways into the container, all landing as user `dev` in the same bind-mounted `/home/dev`. Work happens **inside**
the container - the laptop's `~/projects` and the workstation's `~/projects` are different trees.

| Route                | From        | Use it for                                                   |
|----------------------|-------------|--------------------------------------------------------------|
| `herdr`              | Laptop      | Normal work: panes survive client exit and network loss      |
| `ssh devbox`         | Laptop      | One-off commands, scripts, tunnels, `rsync`, `git`           |
| Moshi                | Phone       | Watching and steering an agent away from the desk            |
| `./bin/devbox shell` | Workstation | Recovery when SSH or the network is the thing that is broken |

## herdr panes

```bash
herdr                    # select "Workstation devbox" in the sidebar
```

A pane opens with a login shell in `/home/dev`. Detaching or quitting the client leaves the pane running
server-side, so closing the laptop lid or killing the client does not interrupt a build, a clone, or an
agent. Reconnecting restores the session shape.

`herdr` requires the pinned binary at `/usr/local/bin/herdr` - the default non-interactive SSH `PATH` is the
only `PATH` its background connections get, which is why it is not installed in `~/.local/bin`.

## `ssh devbox`

`devbox` is an SSH config alias, not a shell alias - see [Setup](setup.md#2-add-the-sshconfig-blocks). It
expands to:

```bash
ssh -p 2223 -l dev -o IdentitiesOnly=yes -i ~/.ssh/devbox.pub workstation
```

Interactive, then one-shot. Quote the command so `~` expands remotely, not on the laptop:

```bash
ssh devbox
ssh devbox 'cd ~/projects/rozsival/devbox && git status -sb'
```

Anything that reads `~/.ssh/config` honours the alias: `scp`, `rsync`, `git`, `ssh -L`.

Add `-A` to forward the laptop's 1Password SSH agent for that one connection - needed for any manual git
operation (clone, fetch, push, or a signed commit; agent sessions never need it, they authenticate over
HTTPS instead, see [Git identities](git.md)):

```bash
ssh -A devbox
```

Plain `ssh devbox` (no `-A`), herdr panes and `./bin/devbox shell` never forward the agent - manual git in
those fails to authenticate at all, on purpose. See
[Git identities](git.md#manual-work-on-the-devbox-the-escape-hatch).

## `./bin/devbox shell`

```bash
ssh workstation 'cd ~/devbox && ./bin/devbox shell'   # docker compose exec -it devbox bash -l
```

This bypasses the container's sshd entirely, so it still works when `authorized_keys`, the host key, or
Tailscale is broken.

## Moshi on a phone

Moshi is an ordinary SSH client as far as the devbox is concerned: host `workstation`, port `2223`, user
`dev`, and a key the container authorizes. Add the phone's public key to `DEVBOX_EXTRA_AUTHORIZED_KEYS` in
`.env` on the workstation, not with the app's Easy Pair flow - the entrypoint rebuilds `authorized_keys`
from GitHub plus that variable on every start, so a key written straight into the file is erased by the next
`./bin/devbox up`.

Notifications, lock-screen approvals and the native transcript view need the `moshi-hook` daemon, which
`bootstrap` installs and the entrypoint runs. One manual pairing step activates it - see
[Toolchain](toolchain.md#moshi-and-moshi-hook).

## Cloning a repo

Clone inside the container, with the agent forwarded, and let the target directory pick the identity:

```bash
ssh -A devbox
git clone git@github.com:rozsival/<repo> ~/projects/rozsival/<repo>       # personal
git clone git@work.github.com:<org>/<repo> ~/projects/work/<repo>   # work, alias required
```

Full rules, including why the work alias cannot be skipped and how agent sessions authenticate without
any of this, are in [Git identities](git.md).

## Reaching a dev server

Dev servers are **not** published. Forward the port over the existing SSH connection:

```bash
# in a devbox pane
pnpm dev                                  # or python3 -m http.server 5173

# on the laptop
ssh -N -L 5173:localhost:5173 devbox &
curl -sS -o /dev/null -w '%{http_code}\n' localhost:5173    # 200
```

`AllowTcpForwarding yes` in `container/sshd_config` exists for exactly this. Add `-L` pairs for more ports;
nothing needs to change in `docker-compose.yml`.

## ❓ FAQ

**Do I clone on the laptop, the workstation, or in the container?**
In the container. The bind mount means a repo cloned in a herdr pane is immediately visible over
`ssh devbox` and in `./bin/devbox shell`, and it survives `docker compose restart`.

**Is `ssh devbox` reachable from outside the Tailnet?**
No. The port is published only on the node's Tailscale address and `127.0.0.1`. See
[Networking](networking.md).

**Why does `git push` fail over plain `ssh devbox`?**
The devbox holds no private key; `-A` is required to forward the laptop's 1Password agent. See
[Git identities](git.md#manual-work-on-the-devbox-the-escape-hatch).

**`Too many authentication failures` - why?**
The agent offered more than six keys before the right one. `IdentitiesOnly yes` plus
`IdentityFile ~/.ssh/devbox.pub` in the `Host devbox` block fixes it.

**`Host key verification failed` after a rebuild?**
It should not happen: the host key lives in the bind mount at `/home/dev/.ssh/host/` and survives image and
container rebuilds. If the data directory was wiped, remove the stale line with
`ssh-keygen -R '[workstation]:2223'` and reconnect.

**Moshi connected to my *laptop* and 1Password asked to use the Devbox Laptop key - why?**
Because Moshi's laptop host runs `herdr`, and every herdr client connects every saved machine itself: the
new client opens its own `ssh devbox` for the Devbox machine, and that is what 1Password is approving.
Approve, and that client shows the devbox through the laptop; deny, and only its Devbox entry sits at
*Attention* - Local panes, the desktop client and a direct phone → devbox connection are unaffected. The
direct route above involves neither the laptop nor 1Password, which is why it is the recommended one.

**Which tools resolve in a non-interactive `ssh devbox '<cmd>'`?**
All of them. Two mechanisms cover it: the pinned binaries live in `/usr/local/bin` (which includes
`node`/`npm`/`npx`/`corepack`/`pnpm`, symlinked out of `/opt/nvm`), and `~/.bashrc.d/devbox.sh` is loaded *above*
Ubuntu's non-interactive early return, so `~/.local/bin` - where OMP installs - is on the `PATH` too.
Verify with `ssh devbox 'command -v omp node pnpm herdr'`.

**Can I use VS Code / JetBrains Remote?**
Yes - point Remote-SSH at the `devbox` host entry. It is an ordinary OpenSSH server with `sftp` enabled.

**Does a pane keep running if the container restarts?**
No. The herdr server dies with the container; only the filesystem survives. herdr restores the saved session
shape on the next attach, but running processes are gone.
