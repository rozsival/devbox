# 🛠 Setup

First deploy, per-host configuration, and the laptop-side SSH wiring. Do these in order; each step is
verifiable on its own.

## Prerequisites

| Where       | Requirement                                                                     |
|-------------|---------------------------------------------------------------------------------|
| Workstation | Ubuntu 26.04, Docker with compose v2, Tailscale up, `rsync`, host user UID 1000 |
| Laptop      | `rsync`, an SSH client, `herdr` (`brew install herdr`)                          |

Check the workstation in one call:

```bash
ssh workstation 'docker --version && docker compose version && tailscale ip -4 && id -u && command -v rsync'
```

A different host UID is fine - set `HOST_UID`/`HOST_GID` in `.env` before the first `up`, because the
bind-mounted home must be owned by the user the container runs as.

## 1. Create the laptop key

Access uses a dedicated, passphrase-less key rather than the 1Password SSH agent. That is not a preference:
1Password asks for per-use authorization, and herdr's background saved-machine connections are
non-interactive - they cannot answer that prompt, so the machine would flap between `connecting` and
`offline`.

```bash
ssh-keygen -t ed25519 -N '' -C laptop-devbox -f ~/.ssh/devbox
```

Authorize it in both places:

```bash
# workstation host (needed by ./bin/push)
ssh-copy-id -i ~/.ssh/devbox.pub -p 2222 vit@workstation

# devbox container: paste the same public key into DEVBOX_EXTRA_AUTHORIZED_KEYS in .env (step 3)
cat ~/.ssh/devbox.pub
```

## 2. Add the `~/.ssh/config` blocks

Two hosts, same machine, different ports: `2222` is the workstation's own sshd, `2223` is the container's.

```
Host workstation
  HostName workstation
  Port 2222
  User vit
  IdentitiesOnly yes
  IdentityFile ~/.ssh/devbox
  ServerAliveInterval 30

Host devbox
  HostName workstation
  Port 2223
  User dev
  IdentitiesOnly yes
  IdentityFile ~/.ssh/devbox
  ServerAliveInterval 30
```

`IdentitiesOnly yes` is load-bearing: without it the agent offers every key it holds and the server rejects
the connection with `Too many authentication failures` before reaching the right one.

Verify the resolved parameters, then the connection:

```bash
ssh -G devbox | grep -E '^(hostname|port|user|identityfile|identitiesonly) '
ssh workstation true
```

## 3. Deploy and configure

```bash
./bin/push workstation
ssh workstation 'cd ~/devbox && ./bin/devbox env'
```

`env` creates `.env` from `.env.example` and fills `BIND_ADDR` from `tailscale ip -4`, plus `HOST_UID` and
`HOST_GID` from the current user. Then edit `~/devbox/.env` on the workstation - at minimum
`DEVBOX_EXTRA_AUTHORIZED_KEYS` with the key from step 1 - and start it:

```bash
ssh workstation 'cd ~/devbox && ./bin/devbox up && ./bin/devbox doctor'
```

`.env` is gitignored **and** excluded from `bin/push`, so every later deploy leaves it untouched.

## 4. Attach herdr

```bash
ssh devbox true                                    # accept the host key once
herdr machine add devbox --label "Workstation devbox"  # interactive terminal; verifies the remote binary
herdr                                              # `Workstation devbox` appears next to `Local`
```

## `.env` reference

| Variable                        | Default                 | Purpose                                   |
|---------------------------------|-------------------------|-------------------------------------------|
| `BIND_ADDR`                     | *(empty)*               | Publish address; empty = `up` refuses     |
| `DEVBOX_SSH_PORT`               | `2223`                  | Host port (container always uses `2222`)  |
| `DEVBOX_DATA_DIR`               | `/home/vit/devbox-data` | Host path mounted at `/home/dev`          |
| `HOST_UID` / `HOST_GID`         | `1000`                  | Container UID/GID; must own the data dir  |
| `TZ`                            | `Europe/Prague`         | Container timezone                        |
| `DEVBOX_GITHUB_USER`            | `rozsival`              | Seeds keys from `github.com/<user>.keys`  |
| `DEVBOX_EXTRA_AUTHORIZED_KEYS`  | *(empty)*               | Extra keys, newline-separated             |
| `GIT_PERSONAL_NAME` / `_EMAIL`  | personal identity       | Applied to `~/.gitconfig`                 |
| `GIT_WORK_NAME` / `_EMAIL`   | work identity        | Applied to `~/.config/work/.gitconfig` |
| `OP_ACCOUNT_ADDRESS` / `_EMAIL` | 1Password account       | Printed in the `op account add` hint      |

## ❓ FAQ

**Why does `authorized_keys` come from GitHub?**
It is rebuilt on every container start from `https://github.com/<DEVBOX_GITHUB_USER>.keys` plus
`DEVBOX_EXTRA_AUTHORIZED_KEYS`, so rotating a key on GitHub is a restart rather than a manual edit. To narrow
the trust, clear `DEVBOX_GITHUB_USER` and list keys explicitly instead.

**Can I use the 1Password agent anyway?**
For interactive `ssh devbox`, yes - any key the agent holds works if it is authorized. Only herdr's
background connections need the file key, so both can coexist.

**`up` failed with an empty `BIND_ADDR`. Is that a bug?**
No, it is the preflight doing its job. Run `./bin/devbox env` (Tailscale must be up first), or set the address
by hand. The alternative - falling back to `0.0.0.0` - would publish the devbox to the public internet.

**Does `bin/push` overwrite my host configuration?**
No. It excludes `.git`, `.env`, `data/` and `.DS_Store`, and `--delete` applies only to synced paths.

**Do I need to re-run `env` after a redeploy?**
Only if the Tailscale address changed. `doctor` compares `BIND_ADDR` against `tailscale ip -4` and fails when
they diverge.

**Where does the data live on the host?**
`${DEVBOX_DATA_DIR}` (default `/home/vit/devbox-data`), owned by `HOST_UID:HOST_GID`. See
[Operations](operations.md) for backup and restore.
