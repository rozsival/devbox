---
name: devbox-basics
description: Explains how the devbox works - the container-as-sandbox model, the Tailnet-only exposure boundary, the three ways in, which machine owns which files, and where the two Git identities apply. Use this whenever someone asks what the devbox is, how it is isolated, "where do I actually work", why a repo or tool is missing from the laptop, whether the devbox is reachable from the internet, or is reading this repo for the first time. Also use it before answering any devbox question from memory, so the answer matches what the repo actually does.
---

# devbox basics

`devbox` provisions one Docker container on the `workstation` workstation. The container runs its own
unprivileged `sshd`, published only on the node's Tailscale address, so a [herdr](https://herdr.dev) client on
the laptop attaches to it as a saved machine and runs OMP agents inside it.

The point of the design: **the container is the sandbox**. An agent running with bypassed permissions reaches
the project tree, the internet and a rootless project Docker daemon, never the host filesystem and never the
host's root Docker daemon. Explaining any part of the devbox well means explaining which of those boundaries
it protects.

## The mental model

```
laptop                    workstation (host)              container "devbox"
herdr client   --ssh-->   BIND_ADDR:2223  --DNAT-->          :2222  sshd running as dev
./bin/push     --rsync->  ~/devbox (the repo)                /home/dev  <- bind mount of
                          ${DEVBOX_DATA_DIR}                 ${DEVBOX_DATA_DIR}
```

Four facts that answer most questions:

1. **Work happens inside the container.** The laptop's `~/projects` and the workstation's `~/projects` are
   different trees from the container's `/home/dev/projects`. A repo must be cloned in the container to be
   visible to agents there.
2. **`/home/dev` is a host bind mount** (`${DEVBOX_DATA_DIR}`, which must be `/home/dev` on the host too).
   Everything that must survive an image rebuild - keys, dotfiles, `~/.config/gh`, project checkouts, the
   sshd host key, Docker images and volumes - lives there. Everything else (installed packages, `/opt/nvm`)
   is in the container's writable layer and is lost on recreate.
3. **The published port is the entire network boundary.** `${BIND_ADDR}:2223:2222` in
   `docker-compose.yml` plus `127.0.0.1:2223`. Docker's DNAT rules match the bound address, so UFW cannot
   restrict a published port - binding to the Tailscale IP is what keeps the devbox off the public internet.
   An empty `BIND_ADDR` makes `./bin/devbox up` refuse to start rather than publish on `0.0.0.0`.
4. **No root, no root socket.** The image ends as `USER dev`, PID 1 is `dev`, `cap_drop: [ALL]`,
   `no-new-privileges`, and the host's root Docker socket is deliberately not mounted. Projects that need
   containers talk to a *second* daemon: a rootless `dockerd` owned by the dedicated unprivileged host user
   `dev`, socket `/run/devbox/docker.sock`, provisioned once with `sudo ./bin/rootless-docker`. Inside the
   box, `docker` and `docker compose` then just work. Published project ports land on the devbox bridge
   gateway (`--ip` plus `--default-network-opt`, since the first covers only the default bridge) and are
   held there by `devbox-docker-firewall`, an nftables table matching that daemon's own socket cgroup, so an
   explicit `0.0.0.0:` port spec cannot reach the Tailnet or the LAN either (`docs/docker.md`).

## The three ways in

| Route                | Run from    | Use it for                                                  |
|----------------------|-------------|-------------------------------------------------------------|
| `herdr`              | Laptop      | Normal work; panes survive client exit and network loss     |
| `ssh devbox`         | Laptop      | One-off commands, scripts, tunnels, `rsync`, `git`          |
| `./bin/devbox shell` | Workstation | Recovery when SSH, `authorized_keys` or Tailscale is broken |

All three land as `dev` in the same `/home/dev`. `devbox` is an **SSH config alias**, not a shell alias: a
`Host devbox` block with `Port 2223`, `User dev` and `IdentityFile ~/.ssh/devbox`. Anything that reads
`~/.ssh/config` honours it, which is why `rsync`, `git` and `ssh -L` work unchanged.

Dev servers are never published. Forward them: `ssh -N -L 5173:localhost:5173 devbox`.

## Two Git identities, chosen by directory

- `~/projects/rozsival/` - personal identity, key `~/.ssh/id_personal`, clone with `git@github.com:…`
- `~/projects/work/` - work identity via `includeIf gitdir:`, key `~/.ssh/id_work`, clone with
  `github-work:<org>/<repo>`

The alias matters for new clones: URL rewriting configured in an `includeIf` file cannot apply before the repo
directory exists, so the first clone into `~/projects/work/` must use `github-work:` explicitly.
Existing `git@github.com:` remotes inside that tree are rewritten by `insteadOf` afterwards.

Both keys are generated inside the container and are registered on GitHub twice - once as an Authentication
key, once as a Signing key - so commits from agents are verified.

## Two optional extras, not installed by default

`./bin/devbox skills` (on the workstation) installs `agent-browser`, `skill-creator` and `find-skills`
globally under `~/.agents/skills`, plus the `agent-browser` CLI and a Chrome build - so panes can drive a
real headless browser. `./bin/sync-omp` (on the laptop) copies `~/.omp/agent/config.yml` into the devbox so
its panes share the laptop's OMP preset. Neither runs during bootstrap; both are idempotent.

## What credentials live in the box

Authority is enumerated, never ambient. The container has **no 1Password account** (`op` is not installed)
and **no Google user credential** (`gcloud` is not installed either). Three layers:

- **Identity** - the two SSH keys, generated in the container, for clone/pull/push and signing
- **Box-wide tool credentials** - `~/.config/devbox/secrets.env`, plain `KEY=value` at mode 600, sourced by
  every shell including non-interactive `ssh devbox <cmd>`; holds `GH_TOKEN` (fine-grained, read-mostly) and
  model API keys
- **Per project** - that project's own `.env`, rendered on the laptop and copied in, so a leak stays scoped
  to one project. GCP keys are per-project too, via `GOOGLE_APPLICATION_CREDENTIALS`

The container is an isolation boundary for the host filesystem and a containment boundary for authority - it
is **not** a confidentiality boundary. Outbound network is unrestricted, so assume anything inside can leave.

## Where to look things up

Answer from these files rather than from memory; each ends with an FAQ section covering the failures actually
hit in practice.

| Question                                             | File                 |
|------------------------------------------------------|----------------------|
| First deploy, `.env` reference, laptop key, SSH cfg  | `docs/setup.md`      |
| Getting a shell, cloning, port forwarding            | `docs/connecting.md` |
| Identity split, signing, verification                | `docs/git.md`        |
| Installed tools, pinned versions, agent skills       | `docs/toolchain.md`  |
| Secret layers, `secrets.env`, `GH_TOKEN`, GCP ADC    | `docs/secrets.md`    |
| Every `bin/devbox` / `bin/push` / `bin/sync-omp` cmd | `docs/cli.md`        |
| Exposure model, why UFW cannot help                  | `docs/networking.md` |
| Redeploy, restart, backup, `doctor`, troubleshooting | `docs/operations.md` |
| Project containers, path identity, `devbox-ports`    | `docs/docker.md`     |
| Boundaries and what an escaped agent reaches         | `docs/security.md`   |
| Conventions for changing this repo                   | `AGENTS.md`          |

## Misconceptions worth correcting on sight

- "I'll clone it on the laptop and push it over" - no; clone in the container, the bind mount does the rest.
- "Let's open another port for the dev server" - no; `ssh -L` exists precisely so `docker-compose.yml` stays
  a one-port file.
- "Add the Docker socket so agents can run containers" - the host's *root* socket is the one thing the design
  forbids. Project containers come from the rootless sibling daemon; a nested daemon is impossible here at
  all, because rootless needs setuid `newuidmap` and this container has `cap_drop: ALL` plus
  `no-new-privileges`.
- "`ssh devbox` is a shell alias in `.bashrc`" - it is `~/.ssh/config`.
- "Firewall the port" - `ufw deny` cannot see Docker's DNAT; `BIND_ADDR` is the control.
