# 📚 devbox Documentation

> Entry point to the devbox documentation. Each page covers **one domain**, opens with a one-paragraph summary, links
> its related pages, and ends with an FAQ where one is useful.

New here? Start with [Architecture](architecture.md), then [Installation](installation.md). The project overview and
quick start live in the [root README](../README.md).

---

## 🗂️ Document index

| Document                        | Read when you want to…                                      | Key topics                                                                         |
|---------------------------------|-------------------------------------------------------------|------------------------------------------------------------------------------------|
| [Architecture](architecture.md) | Understand what runs where and why                          | System map, container startup, ways in, repository layout                          |
| [Installation](installation.md) | Set up the laptop and the workstation for the first time    | Laptop key, `~/.ssh/config`, deploy, `.env` reference, laptop agent install        |
| [Connecting](connecting.md)     | Get a shell in the devbox                                   | herdr panes, `ssh devbox`, Moshi, `devbox shell`, cloning, dev servers             |
| [Git identities](git.md)        | Clone repos and commit as the right account                 | Identity registry, manual vs agent git, credential helper, signing, laptop install |
| [Secrets](secrets.md)           | Place tokens and keys where the right process reads them    | Three layers, `secrets.env`, per-identity `gh` tokens, Claude login, GCP ADC       |
| [Toolchain](toolchain.md)       | See what is installed and add a tool                        | Pinned versions, install locations, OMP, Claude Code, Moshi hooks, agent skills    |
| [Networking](networking.md)     | Know who can reach the devbox and how to reach a dev server | `BIND_ADDR`, why UFW cannot help, verifying exposure, port forwarding              |
| [Docker](docker.md)             | Run a project's containers from inside the devbox           | Rootless project daemon, path identity, published ports, `devbox-ports`            |
| [Operations](operations.md)     | Redeploy, back up or troubleshoot a running devbox          | Redeploy, persistence, backup, health, troubleshooting                             |
| [Security model](security.md)   | Know what an escaped agent reaches and what is accepted     | Boundaries, no root, accepted limits, trust assumptions                            |
| [CLI reference](cli.md)         | Look up a `./bin/devbox` command                            | Workstation, laptop and `doctor` commands, `devbox-identities`, maintainer flow    |
| [Development](development.md)   | Change this repository                                      | Toolchain, rules, regenerating the CLI, agent assets                               |

## 🛤️ Reading paths

### First installation

1. [Architecture](architecture.md) — the container-as-sandbox model and the one published port
2. [Installation](installation.md) — laptop key, `~/.ssh/config`, deploy, `docker setup`, herdr
3. [Git identities](git.md#-laptop-install) and [Secrets](secrets.md#-manual-checklist) — identities, tokens, App
   credentials
4. [Connecting](connecting.md) — panes, cloning, dev servers

### Daily use

- [Connecting](connecting.md) for every way in and port forwarding
- [Docker](docker.md) when a project runs its own containers
- [Operations](operations.md) for redeploys, backups and troubleshooting

### Maintainers

- [Development](development.md) for rules, commit conventions and agent assets
- [CLI reference](cli.md#-maintainer-workflow) before touching `cli/`
- [Security model](security.md) before changing any boundary

## ✍️ Documentation conventions

| Rule            | Detail                                                                                                                                                                                                             |
|-----------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Location        | All user and maintainer docs live in `docs/`, one domain per file, kebab-case names                                                                                                                                |
| Page shape      | `# Title` → summary quote → **Related** line → sections → `## ❓ FAQ` (when useful)                                                                                                                                |
| Source of truth | Config and scripts (`.env.example`, `docker-compose.yml`, `Dockerfile`, `container/*`, `cli/`) win; docs explain them                                                                                              |
| Agent context   | `AGENTS.md`, `CLAUDE.md` and `.agents/skills/*/SKILL.md` stay where their tools look; skills mirror these docs                                                                                                     |
| Formatting      | Prettier via `npx prettier@3 --print-width 120 --single-quote --trailing-comma none --write README.md 'docs/*.md' '.agents/skills/*/SKILL.md'` (not `AGENTS.md`); GitHub-flavored Markdown with alerts and Mermaid |
| Versions        | Pinned versions live in the `Dockerfile` (`ARG <TOOL>_VERSION`) and `container/skills.sh`; docs name them, the code wins                                                                                           |
