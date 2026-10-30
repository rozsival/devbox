<div align="center">

# 📦 devbox

### Containerised remote development environment for an AI coding workstation

![Platform](https://img.shields.io/badge/Platform-Ubuntu%2026.04%20LTS-0A84FF)
![Runtime](https://img.shields.io/badge/Runtime-Docker%20%2B%20rootless%20project%20daemon-2496ED)
![Network](https://img.shields.io/badge/Network-Tailscale%20only-4CAF50)
![Agents](https://img.shields.io/badge/Agents-OMP%20%2B%20Claude%20Code%20%2B%20Codex-F46800)

One Docker container with its own unprivileged `sshd`, published only on the node's Tailscale address. A
[herdr](https://herdr.dev) client on a laptop attaches to it as a saved machine and runs **OMP**, **Claude Code** and
**Codex** agents inside — the container is the agent sandbox.

**[📚 Documentation](docs/README.md)** · [Installation](docs/installation.md) · [Connecting](docs/connecting.md) ·
[Git identities](docs/git.md) · [CLI](docs/cli.md)

</div>

---

## ✨ Highlights

| Feature                  | What it gives you                                                                                                        |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------ |
| **Agent sandbox**        | Agents with bypassed permissions reach the project tree, the internet and LAN, and a rootless project Docker daemon only |
| **Tailnet-only access**  | One `sshd` port, published on the Tailscale address (`BIND_ADDR`) and loopback — never `0.0.0.0`                         |
| **No private keys**      | Public keys only; manual git borrows the laptop's 1Password agent, agent git gets HTTPS and per-operation tokens         |
| **Multiple identities**  | One `identities.conf` routes git author, signing key and GitHub token by directory and GitHub owner                      |
| **Project Docker**       | `docker compose` against a rootless sibling daemon, with path identity and project ports kept off the Tailnet            |
| **Persistent workspace** | herdr panes survive client exit; `/home/dev` is a host bind mount that survives every rebuild                            |
| **One CLI, both sides**  | `./bin/devbox` for workstation and laptop, with a `doctor` acceptance test on each                                       |

> [!IMPORTANT]
> The container **is** the sandbox: agents never reach the host filesystem, the host's root Docker daemon or a private
> key — the box holds public keys only. It contains authority, not data: outbound internet is unrestricted and the LAN
> is reachable — only the host's own services and the Tailnet overlay are blocked — so assume anything inside can
> leave. See [Security model](docs/security.md).

## 🚀 Quick start

Setup spans the laptop, the workstation and 1Password, so let an agent drive it. You need a workstation running
Ubuntu 26.04 LTS with Docker and Tailscale ≥ 1.98, and a laptop with 1Password and
[OMP](https://github.com/can1357/oh-my-pi), [Claude Code](https://claude.com/claude-code) or
[Codex](https://github.com/openai/codex).

Clone this repo on the laptop, start the agent in the checkout (each loads the repo's `devbox-setup` and
`devbox-laptop` skills) and paste:

```text
Set up the devbox from this checkout. My workstation is <workstation>, reachable over Tailscale.
Follow the devbox-setup skill phase by phase and run each phase's check before moving on, then set up
the laptop side with the devbox-laptop skill. Stop and hand me every step that needs me: 1Password
items and approvals, sudo passwords, interactive logins, tokens and identities.conf values.
Done means `./bin/devbox doctor` passes on the workstation and `./bin/devbox doctor laptop` here.
```

Then run `herdr` and open panes on the **Devbox** machine, or `ssh devbox` for a plain shell. Prefer doing it by hand?
Every step is in [Installation](docs/installation.md).

> [!WARNING]
> `start`, `stop` and `rebuild` recreate or stop the container and drop every live SSH session and herdr pane; they ask
> first unless `--force` is given. `update` upgrades the agent tools in place and never does.

## 📚 Documentation

Everything else — architecture, installation, connecting, git identities, secrets, toolchain, networking, project
Docker, operations, security, CLI and development — lives in **[docs/](docs/README.md)**.

## 👤 Ownership

| Item       | Details                                                                   |
| ---------- | ------------------------------------------------------------------------- |
| Maintainer | [@rozsival](https://github.com/rozsival) (see [`CODEOWNERS`](CODEOWNERS)) |
| Issues     | [GitHub Issues](https://github.com/rozsival/devbox/issues)                |
| License    | [MIT](LICENSE)                                                            |
