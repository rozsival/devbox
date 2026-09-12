---
name: devbox-basics
description: Explains how the devbox works - the container-as-sandbox model, the Tailnet-only exposure boundary, the three ways in, which machine owns which files, and where the two Git identities apply. Use this whenever someone asks what the devbox is, how it is isolated, "where do I actually work", why a repo or tool is missing from the laptop, whether the devbox is reachable from the internet, or is reading this repo for the first time. Also use it before answering any devbox question from memory, so the answer matches what the repo actually does.
---

# devbox basics

`devbox` provisions one Docker container on the `workstation` workstation. The container runs its own
unprivileged `sshd`, published only on the node's Tailscale address, so a [herdr](https://herdr.dev) client on
the laptop attaches to it as a saved machine and runs OMP agents inside it.

The point of the design: **the container is the sandbox**. An agent running with bypassed permissions reaches
the project tree and the internet, never the host filesystem and never the host Docker daemon. Explaining any
part of the devbox well means explaining which of those boundaries it protects.

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
2. **`/home/dev` is a host bind mount** (`${DEVBOX_DATA_DIR}`, default `/home/vit/devbox-data`). Everything
   that must survive an image rebuild - keys, dotfiles, `~/.config/gh`, project checkouts, the sshd host key -
   lives there. Everything else (installed packages, `/opt/nvm`) is in the container's writable layer and is
   lost on recreate.
3. **The published port is the entire network boundary.** `${BIND_ADDR}:2223:2222` in
   `docker-compose.yml` plus `127.0.0.1:2223`. Docker's DNAT rules match the bound address, so UFW cannot
   restrict a published port - binding to the Tailscale IP is what keeps the devbox off the public internet.
   An empty `BIND_ADDR` makes `./bin/devbox up` refuse to start rather than publish on `0.0.0.0`.
4. **No root, no socket.** The image ends as `USER dev`, PID 1 is `dev`, `cap_drop: [ALL]`,
   `no-new-privileges`, and the host Docker socket is deliberately not mounted - mounting it would hand the
   sandbox host root and void the whole design.

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

## Where to look things up

Answer from these files rather than from memory; each ends with an FAQ section covering the failures actually
hit in practice.

| Question                                             | File                 |
|------------------------------------------------------|----------------------|
| First deploy, `.env` reference, laptop key, SSH cfg  | `docs/setup.md`      |
| Getting a shell, cloning, port forwarding            | `docs/connecting.md` |
| Identity split, signing, verification                | `docs/git.md`        |
| What is installed and at which pinned version        | `docs/toolchain.md`  |
| `op`, `devenv`, `gh` tokens, App credentials         | `docs/secrets.md`    |
| Every `bin/devbox` / `bin/push` command              | `docs/cli.md`        |
| Exposure model, why UFW cannot help                  | `docs/networking.md` |
| Redeploy, restart, backup, `doctor`, troubleshooting | `docs/operations.md` |
| Boundaries and what an escaped agent reaches         | `docs/security.md`   |
| Conventions for changing this repo                   | `AGENTS.md`          |

## Misconceptions worth correcting on sight

- "I'll clone it on the laptop and push it over" - no; clone in the container, the bind mount does the rest.
- "Let's open another port for the dev server" - no; `ssh -L` exists precisely so `docker-compose.yml` stays
  a one-port file.
- "Add the Docker socket so agents can run containers" - that is the one thing the design forbids; a
  `docker:dind-rootless` sidecar with `DOCKER_HOST` is the only acceptable answer.
- "`ssh devbox` is a shell alias in `.bashrc`" - it is `~/.ssh/config`.
- "Firewall the port" - `ufw deny` cannot see Docker's DNAT; `BIND_ADDR` is the control.
