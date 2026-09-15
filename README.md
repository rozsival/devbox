# 📦 devbox

Containerised remote development environment for the `workstation` AI workstation: a single Docker
container running its own unprivileged `sshd`, published only on the node's Tailscale address, so a
[herdr](https://herdr.dev) client on a laptop can attach to it as a saved machine and run OMP agents inside
it.

The container **is** the sandbox. Agents running with bypassed permissions reach the project tree, the
internet and a rootless project Docker daemon - never the host filesystem and never the host's root Docker
daemon.

```mermaid
flowchart LR
  L["laptop<br/>herdr client"] -->|" ssh devbox<br/>Tailnet only "| H["workstation<br/>BIND_ADDR:2223"]
  H -->|" DNAT "| C["container :2222<br/>sshd as dev"]
  C --> P["panes: OMP, node, gh, wt"]
  C --- V["/home/dev<br/>bind mount"]
```

## 🚀 60-second start

```bash
./bin/push workstation # sync the repo to ~/devbox
ssh workstation 'cd ~/devbox && ./bin/devbox env'
ssh -t workstation 'cd ~/devbox && sudo ./bin/rootless-docker' # once: project Docker, asks for a password
ssh workstation 'cd ~/devbox && ./bin/devbox up'
herdr machine add devbox --label "Workstation devbox" # once the SSH setup below is done
ssh workstation 'cd ~/devbox && ./bin/devbox skills' # optional: agent skills + browser automation
./bin/sync-omp # optional: push this laptop's OMP preset into the devbox
```

The three things that are not optional: the **Devbox Laptop key in 1Password** with only `~/.ssh/devbox.pub`
on disk, the two **`~/.ssh/config` blocks**, and a non-empty **`BIND_ADDR`**. All three are in
[Setup](docs/setup.md); `./bin/laptop-doctor` checks the laptop side.

## 📚 Documentation

| Doc                                | Read it when                                                      |
|------------------------------------|-------------------------------------------------------------------|
| [Setup](docs/setup.md)             | First deploy, `.env` reference, laptop key, `~/.ssh/config`       |
| [Connecting](docs/connecting.md)   | Getting a shell: herdr panes, `ssh devbox`, Moshi, `devbox shell` |
| [Git identities](docs/git.md)      | Cloning repos, personal vs work, manual vs agent git, signing  |
| [Toolchain](docs/toolchain.md)     | What is installed, versions, OMP, Moshi hooks, agent skills       |
| [Secrets](docs/secrets.md)         | Box-wide vs per-project, the two `gh` tokens, GCP ADC, App creds  |
| [CLI reference](docs/cli.md)       | Every `bin/devbox`, `bin/push`, `bin/sync-omp`, `bin/install-agent` and `bin/laptop-doctor` flag |
| [Networking](docs/networking.md)   | Exposure model, why UFW cannot help, port forwarding              |
| [Docker](docs/docker.md)           | Project containers, the rootless daemon, `devbox-ports`           |
| [Operations](docs/operations.md)   | Redeploy, restart, backup, `doctor`, troubleshooting              |
| [Security model](docs/security.md) | Boundaries, trust assumptions, what an escaped agent reaches      |

Working on this repo rather than in it? [AGENTS.md](AGENTS.md) holds the conventions, and
`.agents/skills/` holds four skills that route an agent through the same material:
[devbox-basics](.agents/skills/devbox-basics/SKILL.md) (what it is and how it is isolated),
[devbox-setup](.agents/skills/devbox-setup/SKILL.md) (first install and connection failures),
[devbox-laptop](.agents/skills/devbox-laptop/SKILL.md) (keys, configs and the agent override on the laptop), and
[devbox-deploy](.agents/skills/devbox-deploy/SKILL.md) (shipping a change and applying it).

## 🗺 Layout

```
.env.example          the only per-host configuration (.env is gitignored, never pushed)
Dockerfile            pinned toolchain; ends as USER dev
docker-compose.yml    ${BIND_ADDR}:${DEVBOX_SSH_PORT}:2222 is the whole network boundary
bin/devbox            host-side CLI: env, up, down, rebuild, bootstrap, skills, shell, logs, keys, doctor
bin/rootless-docker   host-side, one-time: provisions the rootless project Docker daemon
bin/push              laptop-side rsync deploy
bin/sync-omp          laptop-side OMP preset sync (~/.omp/agent/config.yml → devbox)
bin/install-agent     laptop-side: installs the omp launcher, gh shim and agent git config
bin/laptop-doctor     laptop-side: checks keys, ssh/git config, the override, tokens and connections
container/            entrypoint.sh (PID 1), bootstrap.sh (user setup), skills.sh (optional), sshd_config
home/                 templates installed into /home/dev by bootstrap (and onto the laptop by install-agent)
docs/                 this documentation
.agents/skills/       agent skills: devbox-basics, devbox-setup, devbox-laptop, devbox-deploy
```

## ⚡ Cheat sheet

```bash
./bin/push workstation --up        # deploy + start (keeps state; asks before killing SSH sessions)
ssh devbox                           # shell in the container
ssh -A devbox                        # + push, pull, sign as yourself (forwards the 1Password agent)
herdr                                # attach panes; they survive client exit
ssh -N -L 5173:localhost:5173 devbox # reach a dev server
ssh devbox 'cd projects/app && docker compose up -d && devbox-ports'  # project containers on localhost
ssh workstation 'cd ~/devbox && ./bin/devbox doctor'
ssh workstation 'cd ~/devbox && ./bin/devbox sessions'   # who is connected (a recreate kills them)
./bin/sync-omp                       # push this laptop's OMP preset into the devbox
./bin/install-agent                  # laptop-side: same agent git override as the devbox
./bin/laptop-doctor                  # laptop-side acceptance test: keys, configs, override, tokens
```
