<div align="center">

# 📦 devbox

### Containerised remote development environment for an AI coding workstation

![Platform](https://img.shields.io/badge/Platform-Ubuntu%2026.04%20LTS-0A84FF)
![Runtime](https://img.shields.io/badge/Runtime-Docker%20%2B%20rootless%20project%20daemon-2496ED)
![Network](https://img.shields.io/badge/Network-Tailscale%20only-4CAF50)
![Agents](https://img.shields.io/badge/Agents-OMP%20%2B%20Claude%20Code-F46800)

One Docker container with its own unprivileged `sshd`, published only on the node's Tailscale address. A
[herdr](https://herdr.dev) client on a laptop attaches to it as a saved machine and runs **OMP** and **Claude Code**
agents inside — the container is the agent sandbox.

**[📚 Documentation](docs/README.md)** · [Installation](docs/installation.md) · [Connecting](docs/connecting.md) ·
[Git identities](docs/git.md) · [CLI](docs/cli.md)

</div>

---

## ✨ Highlights

| Feature                  | What it gives you                                                                                                |
|--------------------------|------------------------------------------------------------------------------------------------------------------|
| **Agent sandbox**        | Agents with bypassed permissions reach the project tree, the internet and a rootless project Docker daemon only  |
| **Tailnet-only access**  | One `sshd` port, published on the Tailscale address (`BIND_ADDR`) and loopback — never `0.0.0.0`                 |
| **No private keys**      | Public keys only; manual git borrows the laptop's 1Password agent, agent git gets HTTPS and per-operation tokens |
| **Multiple identities**  | One `identities.conf` routes git author, signing key and GitHub token by directory and GitHub owner              |
| **Project Docker**       | `docker compose` against a rootless sibling daemon, with path identity and project ports kept off the Tailnet    |
| **Persistent workspace** | herdr panes survive client exit; `/home/dev` is a host bind mount that survives every rebuild                    |
| **One CLI, both sides**  | `./bin/devbox` for workstation and laptop, with a `doctor` acceptance test on each                               |

> [!IMPORTANT]
> The container **is** the sandbox: agents never reach the host filesystem, the host's root Docker daemon or a private
> key — the box holds public keys only. It contains authority, not data: outbound network is unrestricted, so assume
> anything inside can leave. See [Security model](docs/security.md).

## 🚀 Quick start

**Requires** a workstation running Ubuntu 26.04 LTS with Docker and Tailscale, the **Devbox Laptop key in 1Password**
(only `~/.ssh/devbox.pub` on disk), the two **`~/.ssh/config` blocks**, a non-empty **`BIND_ADDR`** and **bash >= 4.2
on the laptop** (`brew install bash`; macOS ships 3.2, which the generated `bin/devbox` refuses) — see
[Installation](docs/installation.md).

From the laptop:

```bash
./bin/devbox deploy <workstation>                                     # sync the repo to ~/devbox
ssh <workstation> 'cd ~/devbox && ./bin/devbox env'                   # .env from .env.example, BIND_ADDR from Tailscale
ssh -t <workstation> 'cd ~/devbox && sudo ./bin/devbox docker setup'  # once: project Docker, asks for a password
ssh <workstation> 'cd ~/devbox && ./bin/devbox up && ./bin/devbox doctor'
herdr machine add devbox --label "Devbox"                             # once the ~/.ssh/config blocks exist
ssh <workstation> 'cd ~/devbox && ./bin/devbox skills'                # optional: agent skills + browser automation
./bin/devbox sync omp                                                 # optional: this laptop's OMP preset → devbox
ssh -t devbox claude                                                  # once, if you use Claude Code: /login
./bin/devbox agent install                                            # laptop: the same agent git override
./bin/devbox doctor laptop                                            # laptop: acceptance test
```

Then run `herdr` and open panes on the **Devbox** machine, or `ssh devbox` for a plain shell.

> [!WARNING]
> `up`, `down` and `rebuild` recreate the container and drop every live SSH session and herdr pane; they ask first
> unless `--force` is given.

## 📚 Documentation

Everything else — architecture, installation, connecting, git identities, secrets, toolchain, networking, project
Docker, operations, security, CLI and development — lives in **[docs/](docs/README.md)**.

## 👤 Ownership

| Item       | Details                                                                   |
|------------|---------------------------------------------------------------------------|
| Maintainer | [@rozsival](https://github.com/rozsival) (see [`CODEOWNERS`](CODEOWNERS)) |
| Issues     | [GitHub Issues](https://github.com/rozsival/devbox/issues)                |
| License    | [MIT](LICENSE)                                                            |
