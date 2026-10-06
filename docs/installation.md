# 🛠️ Installation

> First deploy, per-host config, laptop SSH wiring and the laptop's agent git setup, in order — each step verifiable
> alone.

**Related:** [Connecting](connecting.md) · [Git Identities](git.md) · [Secrets](secrets.md) ·
[Toolchain](toolchain.md) · [Docker](docker.md) · [Operations](operations.md) · [CLI Reference](cli.md)

---

## 🧰 Prerequisites

| Where       | Requirement                                                                  |
| ----------- | ---------------------------------------------------------------------------- |
| Workstation | Ubuntu 26.04, Docker with compose v2, Tailscale up, `rsync`, a known UID/GID |
| Laptop      | `rsync`, an SSH client, and a [herdr](https://herdr.dev) client              |
|             | bash ≥ 4.2 (`brew install bash`) — macOS's 3.2 can't run `./bin/devbox`      |

`./bin/devbox` is bashly-generated and refuses older bash; Homebrew's bash, first on the `PATH`, is the one
`#!/usr/bin/env bash` finds. The workstation's Ubuntu bash is new enough.

> [!IMPORTANT]
> Not optional: the **Devbox Laptop key in 1Password** (only `~/.ssh/devbox.pub` on disk), the two **`~/.ssh/config`
> blocks** and a non-empty **`BIND_ADDR`**.

Check the workstation in one call:

```bash
ssh <workstation> 'docker --version && docker compose version && tailscale ip -4 && id -u && command -v rsync'
```

Different host UID is fine: `./bin/devbox env` derives `HOST_UID`/`HOST_GID` from the current user, owning the
bind-mounted home.

## 🚀 Install

### 1. Create the laptop key

No private key sits on the laptop's disk — a 1Password SSH item served by the agent. The public half sits in `~/.ssh/`;
`IdentityFile` in `~/.ssh/config` picks it there.

1. 1Password → new SSH Key item (ed25519), e.g. _Devbox Laptop_; enable the SSH agent.
2. Save its public key as `~/.ssh/devbox.pub` (the item's _public key_ field, or via `ssh-add -l`/
   `ssh-add -L | grep <fingerprint>`).

It opens the devbox and nothing else. The workstation's own sshd takes a different key — your default identity's
`id_<slug>.pub`, the GitHub key saved the same way ([Git Identities](git.md#-laptop-install)) — because 1Password
approves a key per application, not per use: while an `ssh -A devbox` connection lasts, anything in the devbox can sign
with the key that connection authenticated with.

```bash
# workstation host (needed by ./bin/devbox deploy): never devbox.pub
ssh-copy-id -i ~/.ssh/id_<slug>.pub -p 2222 <user>@<workstation>

# devbox container: paste devbox.pub into DEVBOX_EXTRA_AUTHORIZED_KEYS in .env (step 3)
cat ~/.ssh/devbox.pub
```

herdr's background connections need 1Password unlocked and the key's herdr approval remembered. A machine flapping
`connecting`/`offline` under a locked 1Password reflects that — unlock or approve it. Unworkable? A passphrase-less
_file_ key (`ssh-keygen -t ed25519 -N '' -f ~/.ssh/devbox`) serves only the `devbox` block, never the workstation or
GitHub.

### 2. Add the `~/.ssh/config` blocks

Two hosts, one machine, different ports: `2222` workstation sshd, `2223` container's.

```
Host *
  IdentityAgent "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"

Host <workstation>
  HostName <workstation>
  Port 2222
  User <user>
  IdentitiesOnly yes
  IdentityFile ~/.ssh/id_<slug>.pub
  ServerAliveInterval 30

Host devbox
  HostName <workstation>
  Port 2223
  User dev
  IdentitiesOnly yes
  IdentityFile ~/.ssh/devbox.pub
  ForwardAgent no
  ServerAliveInterval 30
```

`ForwardAgent no` states the default: manual git needs explicit `ssh -A devbox` ([Git Identities](git.md)), never
herdr's connection. GitHub `Host`/`Match` blocks come from `~/.config/devbox/identities.conf`: one plain
`Host github.com` block naming the key most identities on it share, plus a `Match host github.com tagged <slug>` block
per identity whose key differs — see [Git Identities](git.md#-laptop-install).

`Host <workstation>` names the default identity's `id_<slug>.pub`, never `devbox.pub`; `Host devbox` names `devbox.pub`
and nothing else. `devbox doctor laptop` checks both, and asks the workstation — without signing anything, so without a
1Password prompt — whether it would accept `devbox.pub`.

> [!NOTE]
> On a laptop set up with [rozsival/dotfiles](https://github.com/rozsival/dotfiles), none of this is written by hand:
> `~/.ssh/config` is a tracked file symlinked from that repo (`Host *`, the workstation, `devbox`), and `dot identities`
> renders the GitHub blocks into `~/.ssh/config.d/identities`, together with `~/.gitconfig`, `allowed_signers` and the
> `id_*`/`signing_*.pub` files. Change them there — the registry plus `dot identities`, or the dotfiles repo — never
> in place.

> [!IMPORTANT]
> `IdentitiesOnly yes` is load-bearing: without it the agent offers every key, and the server rejects with
> `Too many authentication failures` first.

Verify resolved parameters, then the connection:

```bash
ssh -G devbox | grep -E '^(hostname|port|user|identityfile|identitiesonly) '
ssh <workstation> true
```

### 3. Deploy and configure

```bash
./bin/devbox install                                # `devbox` on this laptop's PATH, with bash completion
./bin/devbox deploy <workstation>                   # or: echo 'DEVBOX_HOST=<workstation>' >.push.env && ./bin/devbox deploy
ssh <workstation> 'cd ~/devbox && ./bin/devbox env'
```

`install` symlinks `~/.local/bin/devbox` onto this checkout and installs its bash completion; every `deploy` does the
same on the workstation, so from then on `devbox <TAB>` works in any new shell on either machine. See
[`devbox install`](cli.md#-devbox-install).

`.push.env` (gitignored) holds `DEVBOX_HOST`, the default for `deploy`'s `<workstation>` argument, and optionally
`DEVBOX_SSH_HOST`, the `~/.ssh/config` host `sync omp` and `sync identities` use for the container (default `devbox`).

`env` creates `.env` from `.env.example`: `BIND_ADDR` from `tailscale ip -4`, `HOST_UID`/`HOST_GID` from `dev` (else
current user). Edit `~/devbox/.env`, at minimum `DEVBOX_EXTRA_AUTHORIZED_KEYS` with step 1's key.

Provision the project Docker daemon once: needs `.env` present, moves `DEVBOX_DATA_DIR` to `/home/dev` under `dev`,
refusing while the container runs (before the first `up`):

```bash
ssh -t <workstation> 'cd ~/devbox && sudo ./bin/devbox docker setup'
```

`--check` reports what's missing, unchanged otherwise; see [Docker](docker.md). Then start the container:

```bash
ssh <workstation> 'cd ~/devbox && ./bin/devbox up && ./bin/devbox doctor'
```

First boot leaves `~/.config/devbox/identities.conf` absent and prints the command that creates it:
`cp /opt/devbox/home/.config/devbox/identities.conf.example ~/.config/devbox/identities.conf`. Nothing seeds it for you,
because the example is a _valid_ file and bootstrap would otherwise configure git as `Your Name <you@example.com>`.

Fill it in from a shell in the container (`ssh <workstation> 'cd ~/devbox && ./bin/devbox shell'`, or any login shell
there): one `[slug]` block per account — name, email, the laptop's public keys — with exactly one block omitting `dir`
to become the default identity. Then re-run `./bin/devbox bootstrap` to derive `~/.ssh/config`, `~/.gitconfig`, the
agent gitconfigs and `allowed_signers` from it. It lives on the bind mount, so it survives every rebuild;
`./bin/devbox sync identities` copies the laptop's own copy over instead of retyping it. See
[Git Identities](git.md).

> [!NOTE]
> `.env` is gitignored **and** excluded from `devbox deploy` — deploys leave it untouched.

### 4. Attach herdr

```bash
ssh devbox true                          # accept the host key once
herdr machine add devbox --label "Devbox" # interactive terminal; verifies the remote binary
herdr                                    # `Devbox` appears next to `Local`
```

## 🧩 Recommended extras

### 5. Optional but recommended

Extras outside `bootstrap`, keeping first starts fast, offline-safe:

```bash
ssh <workstation> 'cd ~/devbox && ./bin/devbox skills'   # 3 global agent skills + agent-browser + Chrome
./bin/devbox sync omp                                    # laptop OMP preset → devbox
ssh -t devbox claude                                     # once: /login for Claude Code on the devbox
```

All idempotent, rerunnable anytime. Details: [Toolchain](toolchain.md#-agent-skills-and-browser-automation),
[Claude Code](toolchain.md#-claude-code).

### 6. Agent git on the laptop (optional but recommended)

The laptop is the only place a private key or a 1Password session ever lives; the devbox borrows them per connection.
Agents run on the laptop too — OMP and Claude Code, same launchers, same mechanism. Two commands make the laptop match:

```bash
./bin/devbox agent install   # omp + claude launchers, gh shim, credential helper, fence, agent gitconfigs - same as the devbox
./bin/devbox doctor laptop   # acceptance test: keys, ~/.ssh/config, signing, the override, tokens, connections
```

| Part       | What the laptop gets                                                                                                                                                                                                                                                              |
| ---------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Keys**   | One `id_<slug>.pub`/`signing_<slug>.pub` pair per identity in `~/.config/devbox/identities.conf`, plus `devbox`: 1Password SSH items, public halves only in `~/.ssh`, selected per `Host` by `IdentityFile <name>.pub` + `IdentitiesOnly`.                                        |
| **Git**    | Your own commits sign through `op-ssh-sign`; agents run through the `omp`/`claude` launchers and get HTTPS remotes, per-operation tokens, a bot author and no signing, on the same clones. On the laptop the launchers need one `PATH` line, which `devbox agent install` prints. |
| **Tokens** | One `GH_TOKEN_<SLUG>` per identity in `~/.config/devbox/secrets.env` (mode 600) and each identity's GitHub App credentials in its own `app` directory, read only by agent sessions.                                                                                               |

`devbox agent install` installs:

- `agent-launch`, `omp-launcher`, `claude-launcher`, `gh` shim, credential helper, fence in
  `~/.local/libexec/devbox-agent`
- `omp` and `claude` symlinks to their launchers in `~/.local/libexec/devbox-agent/launchers`
- `devbox-gh-token` in `~/.local/bin`
- `~/.config/devbox/git/agent*.gitconfig` (directory left read-only)
- the identity registry reader (`devbox-identities`)
- `~/.config/devbox/secrets.env` from template if missing

`identities.conf` is never created for you — it prints the `cp` command instead, so placeholder values can never become
your agent's author. Idempotent: regenerates generated files, keeps `secrets.env` and `identities.conf`, touches nothing
else — your shell rc included. One line there is yours to add, after anything that puts `~/.local/bin` first (Claude's
native install owns `~/.local/bin/claude`, so the launchers cannot live there):

```bash
export PATH="$HOME/.local/libexec/devbox-agent/launchers:$PATH"
```

On a [dotfiles](https://github.com/rozsival/dotfiles) laptop, `~/.config/bash/env.sh` already puts the launchers first.

It reports whether `omp` and `claude` resolve to their launchers, and prints the remaining manual steps per identity: a
`GH_TOKEN_<SLUG>` in `~/.config/devbox/secrets.env`, and — for any identity with an `app` directory set — its GitHub
App credentials there. See [Git Identities](git.md#-laptop-install).

`./bin/devbox doctor laptop` is the laptop's acceptance test. It covers steps 1, 2 and 6 plus the GitHub `Host` blocks
and the signing config: keys held by 1Password with none on disk, every `Host` selecting one `.pub` per registry
identity, every gitconfig signing via `op-ssh-sign`, the override current, every identity's token accepted, all
connections authenticating, and the workstation refusing `devbox.pub`. It names what is missing; the
[devbox-laptop](../.agents/skills/devbox-laptop/SKILL.md) skill and [Git Identities](git.md#-laptop-install) walk the
fixes. Details: [CLI Reference](cli.md#-devbox-doctor).

## 🧾 `.env` reference

| Variable                       | Default                | Purpose                                                         |
| ------------------------------ | ---------------------- | --------------------------------------------------------------- |
| `BIND_ADDR`                    | _(empty)_              | Publish address; empty = `up` refuses                           |
| `DEVBOX_SSH_PORT`              | `2223`                 | Host port (container always uses `2222`)                        |
| `DEVBOX_DATA_DIR`              | `/home/dev`            | Host path; must equal container home (path identity)            |
| `HOST_UID` / `HOST_GID`        | `1001`                 | Dedicated `dev` host user; owns the data dir and project daemon |
| `DEVBOX_DOCKER_SOCKET_DIR`     | `/run/devbox`          | Project daemon socket dir, bind-mounted into the container      |
| `TZ`                           | `Europe/Prague`        | Container timezone                                              |
| `DEVBOX_GITHUB_USER`           | `your-github-username` | Seeds keys from `github.com/<user>.keys`                        |
| `DEVBOX_EXTRA_AUTHORIZED_KEYS` | _(empty)_              | Extra keys, newline-separated                                   |

`.env` carries no git identity: who this box is, per account and per directory tree, lives in
`~/.config/devbox/identities.conf` (see [step 3](#3-deploy-and-configure)), never in `.env` or `docker-compose.yml`.

`.env` holds no other secrets either: tool credentials in `~/.config/devbox/secrets.env`, project secrets in each
project's own `.env`. See [Secrets](secrets.md).

## ✅ Next steps

1. Learn the everyday entry points — herdr panes, `ssh devbox`, `./bin/devbox shell` — in [Connecting](connecting.md)
2. Wire up per-directory accounts, signing and agent credentials in [Git Identities](git.md)
3. Review the three layers and the manual checklist in [Secrets](secrets.md)
4. Bookmark redeploy, backup and health checks in [Operations](operations.md)

---

## ❓ FAQ

### Why does `authorized_keys` come from GitHub?

Rebuilt every container start from `https://github.com/<DEVBOX_GITHUB_USER>.keys` plus `DEVBOX_EXTRA_AUTHORIZED_KEYS` —
rotating a key is a restart, not an edit. Narrow trust: clear `DEVBOX_GITHUB_USER`, list keys explicitly.

### How do I authorize another client — a phone, a second laptop?

Append its public key to `DEVBOX_EXTRA_AUTHORIZED_KEYS` in `.env` **on the workstation** (`<workstation>:~/devbox/.env`;
never synced by `devbox deploy`), run `./bin/devbox up`. Values newline-separate in one quoted pair — compose passes
them intact:

```bash
DEVBOX_EXTRA_AUTHORIZED_KEYS="ssh-ed25519 AAAA…O/L+ laptop-devbox
ssh-ed25519 AAAA…a0iNF iphone"
```

`up` recreates the container, re-reading `.env` — `docker restart` keeps the old environment. Confirm with
`docker compose exec devbox ssh-keygen -lf /home/dev/.ssh/authorized_keys`. Client still needs the tailnet: port
publishes only on `BIND_ADDR`.

### Do I need a key file on disk at all?

No. Every key — devbox key, every GitHub identity — is a 1Password item; `~/.ssh` holds only `.pub` halves. Reason for a
file key: herdr's background connection failing while 1Password is locked ([step 1](#1-create-the-laptop-key)) —
serving the `devbox` block only.

### `up` failed with an empty `BIND_ADDR`. Is that a bug?

No — the preflight is working as intended. Run `./bin/devbox env` (Tailscale up first), or set the address by hand.
`0.0.0.0` as fallback would expose devbox publicly.

### Does `devbox deploy` overwrite my host configuration?

No — excludes `.git`, `.env`, `data/`, `.DS_Store`; `--delete` hits only synced paths.

### Do I need to re-run `env` after a redeploy?

Only if the Tailscale address changed; `doctor` compares `BIND_ADDR` to `tailscale ip -4`, failing on drift.

### I already have a devbox at the old data path. What does `sudo ./bin/devbox docker setup` do to it?

Nothing while the container runs — it refuses, pointing to `./bin/devbox down` first. Stopped, it `mv`s the old
`DEVBOX_DATA_DIR` to `/home/dev`, chowned to `dev`. Keys, cloned repos, `~/.config/devbox/secrets.env` survive — a move,
not a recreate. Finish with `./bin/devbox rebuild`.

### Where does the data live on the host?

`${DEVBOX_DATA_DIR}` (default `/home/dev`), owned by `HOST_UID:HOST_GID`. See [Operations](operations.md) for
backup/restore.
