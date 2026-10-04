<div align="center">

# 📦 devbox

**Containerised remote development environment for an AI coding workstation.**

One Docker container with its own unprivileged `sshd`, published only on the node's Tailscale address.
A [herdr](https://herdr.dev) client on a laptop attaches to it as a saved machine and runs OMP and Claude Code
agents inside.

[Setup](docs/setup.md) · [Connecting](docs/connecting.md) · [Git identities](docs/git.md) ·
[Secrets](docs/secrets.md) · [CLI](docs/cli.md) · [Docker](docs/docker.md) · [Security](docs/security.md)

</div>

---

The container **is** the sandbox. Agents running with bypassed permissions reach the project tree, the
internet and a rootless project Docker daemon - never the host filesystem, never the host's root Docker
daemon, and never a private key: the box holds public keys only.

```mermaid
flowchart LR
  L["laptop<br/>herdr client"] -->|" ssh devbox<br/>Tailnet only "| H["<workstation><br/>BIND_ADDR:2223"]
  H -->|" DNAT "| C["container :2222<br/>sshd as dev"]
  C --> P["panes: OMP, Claude Code, node, gh, wt"]
  C --- V["/home/dev<br/>bind mount"]
```

## 🚀 60-second start

Workstation side, from the laptop:

```bash
./bin/devbox deploy <workstation>                                     # sync the repo to ~/devbox
ssh <workstation> 'cd ~/devbox && ./bin/devbox env'                   # .env from .env.example, BIND_ADDR from Tailscale
ssh -t <workstation> 'cd ~/devbox && sudo ./bin/devbox docker setup'  # once: project Docker, asks for a password
ssh <workstation> 'cd ~/devbox && ./bin/devbox up && ./bin/devbox doctor'
herdr machine add devbox --label "Devbox"                            # once the ~/.ssh/config blocks below exist
ssh <workstation> 'cd ~/devbox && ./bin/devbox skills'                # optional: agent skills + browser automation
./bin/devbox sync omp                                                 # optional: this laptop's OMP preset → devbox
ssh -t devbox claude                                                  # once, if you use Claude Code: /login
```

Not optional: the **Devbox Laptop key in 1Password** (only `~/.ssh/devbox.pub` on disk), the two **`~/.ssh/config`
blocks**, a non-empty **`BIND_ADDR`**, and **bash >= 4.2 on the laptop** (`brew install bash`; macOS ships 3.2,
which the generated `bin/devbox` refuses). The first three are in [Setup](docs/setup.md).

## 💻 Laptop setup

The laptop is the only place a private key or a 1Password session ever lives; the devbox borrows them per
connection. Two commands make the laptop match:

```bash
./bin/devbox agent install   # omp + claude launchers, gh shim, credential helper, fence, agent gitconfigs - same as the devbox
./bin/devbox doctor laptop   # acceptance test: keys, ~/.ssh/config, signing, the override, tokens, connections
```

- **Keys** - one `id_<slug>.pub`/`signing_<slug>.pub` pair per identity in
  `~/.config/devbox/identities.conf`, plus `devbox`: 1Password SSH items, public halves only in `~/.ssh`,
  selected per `Host` by `IdentityFile <name>.pub` + `IdentitiesOnly`.
- **Git** - your own commits sign through `op-ssh-sign`; agents run through the `omp`/`claude` launchers and
  get HTTPS remotes, per-operation tokens, a bot author and no signing, on the same clones. On the laptop
  the launchers need one `PATH` line, which `devbox agent install` prints.
- **Tokens** - one `GH_TOKEN_<SLUG>` per identity in `~/.config/devbox/secrets.env` (mode 600) and each
  identity's GitHub App credentials in its own `app` directory, read only by agent sessions.

`devbox doctor laptop` names what is missing; the [devbox-laptop](.agents/skills/devbox-laptop/SKILL.md) skill and
[Git identities](docs/git.md#laptop-install) walk the fixes.

## 📚 Documentation

| Doc                                | Read it when                                                                                                            |
|------------------------------------|-------------------------------------------------------------------------------------------------------------------------|
| [Setup](docs/setup.md)             | First deploy, `.env` reference, laptop key, `~/.ssh/config`, laptop agent install                                       |
| [Connecting](docs/connecting.md)   | Getting a shell: herdr panes, `ssh devbox`, Moshi, `devbox shell`                                                       |
| [Git identities](docs/git.md)      | Cloning repos, the identity registry, manual vs agent git, signing, laptop install                                      |
| [Toolchain](docs/toolchain.md)     | What is installed, versions, OMP, Claude Code, Moshi hooks, agent skills                                                |
| [Secrets](docs/secrets.md)         | Box-wide vs per-project, per-identity `gh` tokens, GCP ADC, App creds                                                   |
| [CLI reference](docs/cli.md)       | Every `bin/devbox` command and flag - workstation, laptop and `doctor` - and how to edit the CLI                        |
| [Networking](docs/networking.md)   | Exposure model, why UFW cannot help, port forwarding                                                                    |
| [Docker](docs/docker.md)           | Project containers, the rootless daemon, `devbox-ports`                                                                 |
| [Operations](docs/operations.md)   | Redeploy, restart, backup, `doctor`, troubleshooting                                                                    |
| [Security model](docs/security.md) | Boundaries, trust assumptions, what an escaped agent reaches                                                            |

## ⚡ Cheat sheet

```bash
./bin/devbox deploy <workstation> --up   # deploy + start (keeps state; asks before killing SSH sessions)
ssh devbox                           # shell in the container
ssh -A devbox                        # + push, pull, sign as yourself (forwards the 1Password agent)
herdr                                # attach panes; they survive client exit
ssh -N -L 5173:localhost:5173 devbox # reach a dev server
ssh devbox 'cd projects/app && docker compose up -d && devbox-ports'  # project containers on localhost
ssh <workstation> 'cd ~/devbox && ./bin/devbox doctor'
ssh <workstation> 'cd ~/devbox && ./bin/devbox sessions'   # who is connected (a recreate kills them)
./bin/devbox sync omp                # push this laptop's OMP preset into the devbox
./bin/devbox agent install           # laptop-side: same agent git override as the devbox
./bin/devbox doctor laptop           # laptop-side acceptance test: keys, configs, override, tokens
./bin/devbox sync identities         # push this laptop's identity registry into the devbox
```

## 🗺 Layout

```
.env.example          the only per-host configuration (.env is gitignored, never deployed)
Dockerfile            pinned toolchain; ends as USER dev
docker-compose.yml    ${BIND_ADDR}:${DEVBOX_SSH_PORT}:2222 is the whole network boundary
bashly-settings.yml   bashly settings: builds bin/devbox from cli/
cli/                  the CLI source: bashly.yml (commands), commands/ (bodies), lib/ (shared functions)
bin/devbox            the CLI, generated by bashly and committed - never hand-edited. Workstation: env, up, down,
                      rebuild, bootstrap, skills, shell, sessions, logs, hook, keys, docker setup. Laptop:
                      deploy, sync omp, sync identities, agent install. Both: doctor
container/            entrypoint.sh (PID 1), bootstrap.sh (user setup), skills.sh (optional), sshd_config
home/                                          templates installed into /home/dev by bootstrap (and onto the
                                                laptop by devbox agent install)
home/.config/devbox/identities.conf.example    identity registry template - you copy it to ~/.config/devbox/
                                                identities.conf; nothing seeds it for you
home/.local/libexec/devbox-identities          the one reader of identities.conf: sourceable library and CLI
home/.config/devbox/git/agent.gitconfig.tpl    template devbox-identities renders into the agent gitconfig
docs/                 this documentation
.agents/skills/       agent skills: devbox-basics, devbox-setup, devbox-laptop, devbox-deploy
.claude/skills/       symlinks to .agents/skills/ - the one skills directory Claude Code reads
CLAUDE.md             imports AGENTS.md for Claude Code
```

## 🤖 Working on this repo

[AGENTS.md](AGENTS.md) holds the conventions (Claude Code reads it through `CLAUDE.md`). Four skills in
`.agents/skills/` (mirrored into `.claude/skills/` by symlink) route an agent through the
same material: [devbox-basics](.agents/skills/devbox-basics/SKILL.md) (what it is, how it is isolated),
[devbox-setup](.agents/skills/devbox-setup/SKILL.md) (first install, connection failures),
[devbox-laptop](.agents/skills/devbox-laptop/SKILL.md) (keys, configs, the agent override on the laptop),
[devbox-deploy](.agents/skills/devbox-deploy/SKILL.md) (shipping a change and applying it).
