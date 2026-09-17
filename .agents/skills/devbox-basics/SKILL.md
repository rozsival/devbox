---
name: devbox-basics
description: Explains how the devbox works - the container-as-sandbox model, the Tailnet-only exposure boundary, the four ways in, which machine owns which files, and how the identity registry routes Git identities by directory. Use this whenever someone asks what the devbox is, how it is isolated, "where do I actually work", why a repo or tool is missing from the laptop, whether the devbox is reachable from the internet, or is reading this repo for the first time. Also use it before answering any devbox question from memory, so the answer matches what the repo actually does.
---

# devbox basics

`devbox` provisions one Docker container on `<workstation>`: its own unprivileged `sshd`, published only on
its Tailscale address. A [herdr](https://herdr.dev) laptop client attaches to it as a saved machine, running
OMP agents inside.

**The container is the sandbox.** A bypassed-permission agent reaches the project tree, internet, and a
rootless project Docker daemon - never the host filesystem or its root Docker daemon.

## The mental model

```
laptop                    <workstation> (host)              container "devbox"
herdr client   --ssh-->   BIND_ADDR:2223  --DNAT-->          :2222  sshd running as dev
./bin/push     --rsync->  ~/devbox (the repo)                /home/dev  <- bind mount of
                          ${DEVBOX_DATA_DIR}                 ${DEVBOX_DATA_DIR}
```

Four facts:

1. **Work happens inside the container.** Laptop, workstation `~/projects` differ from the container's
   `/home/dev/projects` - clone repos there for agents to see them.
2. **`/home/dev` is a host bind mount** (`${DEVBOX_DATA_DIR}`, also `/home/dev` on the host). Surviving a
   rebuild: keys, dotfiles, `~/.config/gh`, project checkouts, sshd host key, Docker images, volumes. Not
   surviving: installed packages, `/opt/nvm` (writable layer, lost on recreate).
3. **The published port is the entire network boundary**: `${BIND_ADDR}:2223:2222` in `docker-compose.yml`
   plus `127.0.0.1:2223`. Docker's DNAT matches the bound address, so UFW can't restrict it - binding to the
   Tailscale IP keeps devbox off the public internet. An empty `BIND_ADDR` makes `./bin/devbox up` refuse to
   start rather than publish on `0.0.0.0`.
4. **No root, no root socket.** `USER dev`, PID 1 `dev`, `cap_drop: [ALL]`, `no-new-privileges`; the host's
   root Docker socket is never mounted. Project containers come from a *second* daemon: a rootless
   `dockerd` owned by the dedicated host user `dev`, socket `/run/devbox/docker.sock`, provisioned once by
   `sudo ./bin/rootless-docker` - after which `docker` and `docker compose` work in the box. That daemon
   publishes project ports on the devbox bridge gateway (`--ip` plus `--default-network-opt`, since `--ip`
   alone covers only the default bridge). `devbox-docker-firewall` - nftables matching the daemon's socket
   cgroup - holds the line regardless: even an explicit `0.0.0.0:` port never reaches the Tailnet or the
   LAN (`docs/docker.md`).

## The four ways in

| Route                | Run from    | Use it for                                                  |
|----------------------|-------------|-------------------------------------------------------------|
| `herdr`              | Laptop      | Normal work; panes survive client exit, network loss        |
| `ssh devbox`         | Laptop      | One-off commands, scripts, tunnels, `rsync`, `git`          |
| Moshi                | Phone       | Watching, steering an agent away from the desk               |
| `./bin/devbox shell` | Workstation | Recovery when SSH, `authorized_keys`, or Tailscale broken    |

All four land as `dev` in `/home/dev`. `devbox` is an **SSH config alias**, not a shell alias: a
`Host devbox` block (`Port 2223`, `User dev`, `IdentityFile ~/.ssh/devbox.pub`) that anything reading
`~/.ssh/config` honours - so `rsync`, `git` and `ssh -L` work unchanged.

Moshi is a plain SSH client plus `moshi-hook` (daemon `bootstrap` installs, `entrypoint.sh` starts) - without
it the phone gets a terminal but no notifications or approvals. Its phone key belongs in
`DEVBOX_EXTRA_AUTHORIZED_KEYS`: `authorized_keys` gets rewritten every start (`docs/toolchain.md`).

Dev servers are never published. Forward them: `ssh -N -L 5173:localhost:5173 devbox`.

## Identity registry: any number of accounts, one file

`~/.config/devbox/identities.conf` is the single source of identity truth, held on both machines
(`./bin/sync-identities` copies the laptop's copy to the devbox). One `[slug]` block per account, routed by
directory prefix - the longest match wins, and exactly one block with no `dir` is the default that catches
every tree no other block claims:

- Everywhere else - the identity with no `dir`, the default; clone with `git@github.com:…`
- `~/projects/work/` - the `work` identity, via `includeIf gitdir:`; clone with
  `git@work.github.com:<org>/<repo>`

New clones need the alias: `includeIf` rewriting can't apply before the repo directory exists, so a first
clone into a non-default tree needs `git@<slug>.<host>:` explicitly; `insteadOf` rewrites existing
`git@<host>:` remotes in that tree afterward.

The devbox holds no private key for any identity: manual git (pane push, signed commit) borrows the
laptop's 1Password agent, forwarded per connection with `ssh -A devbox`; agent sessions never touch it - the
`omp` launcher rewrites their git to HTTPS with a per-operation token (GitHub App installation token or
fine-grained PAT) and bot author, unsigned. Full mechanism: `docs/git.md`.

## Two optional extras, not installed by default

`./bin/devbox skills` (workstation) installs `agent-browser`, `skill-creator`, `find-skills` into
`~/.agents/skills`, plus its CLI and a Chrome build, so panes can drive a headless browser. `./bin/sync-omp`
(laptop) copies `~/.omp/agent/config.yml` into the devbox so panes share the laptop's OMP preset. Neither
runs during bootstrap; both are idempotent.

## What credentials live in the box

Authority is enumerated, never ambient: **no 1Password account** (`op` not installed), **no GitHub private
key**, **no Google user credential** (`gcloud` not installed). Three layers:

- **Identity** - public keys only, from `~/.config/devbox/identities.conf` (`pubkey` for authentication,
  `signing_pubkey` for signing - GitHub registers them separately); no private key at rest - same
  borrow/token split as above.
- **Box-wide tool credentials** - `~/.config/devbox/secrets.env`, plain `KEY=value` mode 600, sourced by
  every shell including non-interactive `ssh devbox <cmd>`; holds model API keys, one fine-grained GitHub
  token per identity (`GH_TOKEN_<SLUG>`, e.g. `GH_TOKEN_PERSONAL`). Nothing exports `GH_TOKEN` - the `gh`
  shim in `~/.local/libexec/devbox-agent` resolves it per invocation from the working directory, same rule
  as git identity (`devbox-gh-token --account` reports it)
- **Per project** - that project's `.env`, rendered on the laptop, copied in, so a leak stays scoped there;
  GCP keys are per-project too, via `GOOGLE_APPLICATION_CREDENTIALS`

The container isolates the host filesystem, contains authority - not a confidentiality boundary. Outbound
network is unrestricted; assume anything inside can leave.

## Where to look things up

Answer from these files, not memory - each ends with an FAQ of real failures.

| Question                                             | File                 |
|------------------------------------------------------|----------------------|
| First deploy, `.env`, laptop key, SSH cfg           | `docs/setup.md`      |
| Getting a shell, cloning, port forwarding            | `docs/connecting.md` |
| Identity split, signing, verification                | `docs/git.md`        |
| Installed tools, pinned versions, agent skills       | `docs/toolchain.md`  |
| Secret layers, `secrets.env`, `gh` tokens, GCP ADC   | `docs/secrets.md`    |
| Every `bin/devbox` / `bin/push` / `bin/sync-omp` cmd | `docs/cli.md`        |
| Exposure model, why UFW cannot help                  | `docs/networking.md` |
| Redeploy, restart, backup, `doctor`, troubleshooting | `docs/operations.md` |
| Project containers, path identity, `devbox-ports`    | `docs/docker.md`     |
| Boundaries; what an escaped agent reaches            | `docs/security.md`   |
| Conventions for this repo                            | `AGENTS.md`          |

## Misconceptions worth correcting on sight

- "I'll clone it on the laptop and push it over" - no; clone in the container, the bind mount does the rest.
- "Let's open another port for the dev server" - no; `ssh -L` exists so `docker-compose.yml` stays a
  one-port file.
- "Add the Docker socket so agents can run containers" - the host's *root* socket is the one thing
  forbidden. Project containers come from the rootless sibling daemon; nesting a daemon here is impossible:
  rootless needs setuid `newuidmap` and this container has `cap_drop: ALL` plus `no-new-privileges`.
- "`ssh devbox` is a shell alias in `.bashrc`" - it is `~/.ssh/config`.
- "Firewall the port" - `ufw deny` cannot see Docker's DNAT; `BIND_ADDR` is the control.
