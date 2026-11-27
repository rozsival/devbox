# 🔗 Connecting

> Three ways into the container, landing as `dev` in the same bind-mounted `/home/dev` — laptop and workstation
> `~/projects` differ. Normal work goes through Moshi, straight to the container's sshd; `ssh devbox` covers one-off
> commands and tunnels, and `./bin/devbox shell` is the recovery route.

**Related:** [Installation](installation.md) · [Git Identities](git.md) · [Toolchain](toolchain.md) ·
[Networking](networking.md)

---

## 🗺️ Routes

| Route                | From          | Use it for                                         |
| -------------------- | ------------- | -------------------------------------------------- |
| Moshi                | Moshi devices | Normal work: herdr panes survive disconnects       |
| `ssh devbox`         | Laptop        | One-off commands, scripts, tunnels, `rsync`, `git` |
| `./bin/devbox shell` | Workstation   | Recovery when SSH or the network is broken         |

## 📱 Moshi

Moshi's an SSH client: host `<workstation>`, port `2223`, user `dev`, container-authorized key. It connects straight to
the container's sshd — no laptop in between, no 1Password prompt.

> [!IMPORTANT]
> Add each device's key to `DEVBOX_EXTRA_AUTHORIZED_KEYS` in `.env` on the workstation, not via Easy Pair — the
> entrypoint rebuilds `authorized_keys` from GitHub plus that variable each start, erasing direct edits at the next
> `./bin/devbox start`.

Panes run in the container's herdr server (the pinned `/usr/local/bin/herdr`) and keep running server-side after a
disconnect — a dropped network or a closed app won't interrupt a build, clone, or agent; reconnecting restores it.

Notifications, lock-screen approvals, and transcript view need `moshi-hook`, which `bootstrap` installs and the
entrypoint starts. One pairing step activates it — [Toolchain](toolchain.md#-moshi-and-moshi-hook).

> [!NOTE]
> The laptop's herdr client does not register the Devbox as a saved machine: Moshi is the one client for it, and a
> second one only duplicates the same panes. To drop an existing profile: `herdr machine list`, then
> `herdr machine remove <id>` (the 32-hex id; the label is refused). Removing it disconnects that client only; the
> Devbox's herdr server and its panes keep running.

## 🔑 `ssh devbox`

`devbox` is an SSH config alias, not a shell alias ([Installation](installation.md#2-add-the-sshconfig-blocks)).
Expands to:

```bash
ssh -p 2223 -l dev -o IdentitiesOnly=yes -i ~/.ssh/devbox.pub <workstation>
```

Interactive, then one-shot; quote so `~` expands remotely, not on the laptop:

```bash
ssh devbox
ssh devbox 'cd ~/projects/devbox && git status -sb'
```

Anything reading `~/.ssh/config` honours it: `scp`, `rsync`, `git`, `ssh -L`.

Add `-A` to forward the laptop's 1Password agent for one connection — manual git needs it (clone, fetch, push, signed
commit; agent sessions use HTTPS instead — [Git Identities](git.md)):

```bash
ssh -A devbox
```

> [!NOTE]
> Plain `ssh devbox` (no `-A`), Moshi and `./bin/devbox shell` never forward the agent — manual git fails, on purpose:
> [Git Identities](git.md#-manual-work-on-the-devbox--the-escape-hatch).

## 🧯 `./bin/devbox shell`

```bash
ssh <workstation> 'cd ~/devbox && ./bin/devbox shell'   # docker compose exec -it devbox bash -l
```

This bypasses the container's sshd, working even if `authorized_keys`, the host key, or Tailscale is broken.

## 📥 Cloning a repo

Clone inside the container, agent forwarded, target directory picking the identity — the remote is the same plain GitHub
URL either way:

```bash
ssh -A devbox
git clone git@github.com:<your-github-username>/<repo> ~/projects/<repo>       # default identity
git clone git@github.com:<org>/<repo> ~/projects/work/<repo>                   # non-default, org in its `orgs`
```

Full rules — how the ssh tag and the `hasconfig:` org include pick a non-default identity's key and author, how agent
sessions authenticate without either — in [Git Identities](git.md).

## 🌐 Reaching a dev server

Dev servers aren't published — forward the port over the existing SSH connection:

```bash
# in a devbox pane
pnpm dev                                  # or python3 -m http.server 5173

# on the laptop
ssh -N -L 5173:localhost:5173 devbox &
curl -sS -o /dev/null -w '%{http_code}\n' localhost:5173    # 200
```

`AllowTcpForwarding yes` in `container/sshd_config` enables this. Add more `-L` pairs for more ports; no
`docker-compose.yml` changes.

---

## ❓ FAQ

### Do I clone on the laptop, the workstation, or in the container?

In the container: the bind mount makes a repo cloned in a herdr pane visible over `ssh devbox` and `./bin/devbox shell`,
surviving `docker compose restart`.

### Is `ssh devbox` reachable from outside the Tailnet?

No — the port publishes only on the node's Tailscale address and `127.0.0.1` ([Networking](networking.md)).

### Why does `git push` fail over plain `ssh devbox`?

The Devbox holds no private key; `-A` forwards the laptop's 1Password agent — see
[Git Identities](git.md#-manual-work-on-the-devbox--the-escape-hatch).

### `Too many authentication failures` — why?

The agent offered more than six keys before the right one; `IdentitiesOnly yes` plus `IdentityFile ~/.ssh/devbox.pub` in
`Host devbox` fixes it.

### `Host key verification failed` after a rebuild?

Shouldn't happen: the host key lives in `/home/dev/.ssh/host/`'s bind mount, surviving rebuilds. Wiped data dir? Remove
the stale line: `ssh-keygen -R '[<workstation>]:2223'`, reconnect.

### Which tools resolve in a non-interactive `ssh devbox '<cmd>'`?

All of them: pinned binaries in `/usr/local/bin` (`node`/`npm`/`npx`/`corepack`/`pnpm`, symlinked from `/opt/nvm`);
`~/.bashrc.d/devbox.sh` loads _above_ Ubuntu's non-interactive early return, putting `~/.local/bin` (OMP's, Claude
Code's and Codex's install dir) on `PATH`, and `~/.bash_profile` reasserts that order for login shells, where
`~/.profile` would re-prepend `~/.local/bin` ahead of the agent launchers. Verify both routes:
`ssh devbox 'command -v omp claude codex node pnpm herdr'` and `ssh devbox 'bash -lc "command -v omp claude codex"'` —
the second must print `~/.local/libexec/devbox-agent/omp`, `…/claude` and `…/codex`, the launchers.

### Can I use VS Code / JetBrains Remote?

Yes — point Remote-SSH at `devbox`: an OpenSSH server, `sftp` enabled.

### Does a pane keep running if the container restarts?

No — the herdr server dies with the container; only the filesystem survives. herdr restores the shape, but running
processes are gone.
