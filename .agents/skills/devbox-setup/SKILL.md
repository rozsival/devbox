---
name: devbox-setup
description: Sets up the devbox end to end - the dedicated laptop SSH key, the two ~/.ssh/config host blocks, the first deploy and .env on the workstation, herdr machine registration, and the in-container manual steps (GitHub keys, the per-account GH_TOKEN_PERSONAL/GH_TOKEN_WORK tokens in secrets.env, GitHub App credentials). Use this whenever someone is installing or re-installing the devbox, onboarding a new laptop, says they cannot connect, gets "Too many authentication failures", "Permission denied (publickey)", an empty BIND_ADDR preflight failure, or a herdr machine stuck offline, or asks which manual steps are still outstanding.
---

# devbox setup

Setup has five phases with a hard ordering: laptop key → `~/.ssh/config` → deploy and `.env` on the
workstation → project Docker → in-container identity steps. Each phase ends with a check that must pass
before moving on, because a failure two phases later is almost always an unverified earlier phase.

The literal command and config blocks live in `docs/setup.md` - read the section this skill points you at
rather than retyping them from memory, so a changed default is picked up instead of being reintroduced.
Phases 1 and 2 are the laptop's share of a larger laptop layout (GitHub keys, gitconfigs, the agent git
override, tokens); the `devbox-laptop` skill owns that and `./bin/laptop-doctor` checks all of it.

## Phase 1 - the laptop key (on the laptop)

The key is a 1Password SSH item served by the 1Password agent; only its public half is written to
`~/.ssh/devbox.pub`, which `IdentityFile` uses to select it. Steps and the authorize commands are in
`docs/setup.md#1-create-the-laptop-key`:

```bash
ssh-copy-id -i ~/.ssh/devbox.pub -p 2222 vit@workstation   # host sshd, needed by ./bin/push
cat ~/.ssh/devbox.pub                                        # goes into .env in phase 3
```

herdr's saved-machine connections run in the background, so they need 1Password unlocked and the key
approved for herdr; a machine flapping between `connecting` and `offline` while 1Password is locked is that,
not a devbox fault. A dedicated passphrase-less file key is the documented fallback if that ever proves
unworkable.

## Phase 2 - `~/.ssh/config` (on the laptop)

Two `Host` entries for the same machine on different ports: `2222` is the workstation's own sshd (needed by
`bin/push`), `2223` is the container's. Copy both blocks verbatim from
`docs/setup.md#2-add-the-sshconfig-blocks`; the field that people drop and then debug for an hour is
`IdentitiesOnly yes`, because without it the agent offers every key it holds and the server rejects the
connection with `Too many authentication failures` before reaching the right one.

Check: `ssh -G devbox | grep -E '^(hostname|port|user|identityfile|identitiesonly) '` then
`ssh workstation true`.

## Phase 3 - deploy and configure (from the laptop)

```bash
./bin/push workstation
ssh workstation 'cd ~/devbox && ./bin/devbox env'
```

`env` creates `.env` from `.env.example`, never clobbers an existing one, and fills `BIND_ADDR` from
`tailscale ip -4` plus `HOST_UID`/`HOST_GID` - from the dedicated `dev` host user when it exists, otherwise
from the invoking user. Tailscale must be up first - with it down there is no address to write, and `up` then
refuses on the empty value. Then edit `~/devbox/.env` on the workstation - at minimum put the phase-1 public
key in `DEVBOX_EXTRA_AUTHORIZED_KEYS`, which takes newline-separated keys.

Do phase 4 **before** the first `up`: it moves the data directory and refuses to run while the container is
up. Then start it:

```bash
ssh workstation 'cd ~/devbox && ./bin/devbox up && ./bin/devbox doctor'
```

`doctor` is the acceptance test for this phase: it checks compose, `BIND_ADDR` against Tailscale, that
something listens on `BIND_ADDR:${DEVBOX_SSH_PORT}` and **nothing** on `0.0.0.0`, container health, that PID 1
is `dev`, that the project Docker daemon answers and is rootless, that `host.docker.internal` resolves, that
the project-port boundary service is active, and the toolchain probes. It exits non-zero if any check fails.

`.env` is gitignored **and** excluded from `bin/push`, so later deploys never touch it.

If the node's Tailscale address later changes, `doctor` reports
`BIND_ADDR is X but Tailscale reports Y`; re-run `./bin/devbox env && ./bin/devbox up`.

## Phase 4 - project Docker (on the workstation, once)

```bash
ssh -t workstation 'cd ~/devbox && sudo ./bin/rootless-docker'
```

Needs `sudo`, is idempotent, and `--check` reports state without changing anything. It installs `uidmap` and
`slirp4netns`, creates the unprivileged `dev:devbox` host user that owns the daemon, moves `DEVBOX_DATA_DIR`
to `/home/dev`, chowns the tree, installs the nftables table and `devbox-docker-firewall.service` that keep
published project ports off the Tailnet and the LAN, and enables a lingering rootless `dockerd` on
`/run/devbox/docker.sock`.

Two things to get right, both explained in `docs/docker.md`:

- **Run it before the first `up`, or after `./bin/devbox down`.** It refuses while the container is running,
  because it moves the bind mount out from under it. Nothing is destroyed - a `mv` plus a `chown`, so keys,
  repos and the `gh` login survive.
- **`DEVBOX_DATA_DIR` has to end up as `/home/dev`.** The daemon resolves a project's bind mounts as host
  paths, so both sides must agree on the path or every relative mount silently resolves to an empty
  directory.

Check: the Docker probes in `./bin/devbox doctor`, then `ssh devbox 'docker run --rm hello-world'`.

## Phase 5 - attach herdr and finish the identity steps

```bash
ssh devbox true                                    # accept the container host key once
herdr machine add devbox --label "Workstation devbox"  # interactive terminal: it verifies the remote binary
herdr                                              # "Workstation devbox" appears next to "Local"
```

Bootstrap runs on every container start, is fully idempotent, and prints the outstanding steps at the end -
so `./bin/devbox bootstrap` is the authoritative answer to "what is left to do", never a guess:

```bash
ssh workstation 'cd ~/devbox && ./bin/devbox keys'       # installed public keys + host-key fingerprint
```

The devbox generates no keys of its own - it only installs the laptop's public keys from `.env`
(`GIT_*_PUBKEY` for authentication, `GIT_*_SIGNINGKEY` for signing). There is nothing to register on GitHub
for the devbox: they are already your normal laptop keys, already registered there.

1. Set `GIT_PERSONAL_PUBKEY` / `GIT_WORK_PUBKEY` to the authentication public keys and
   `GIT_PERSONAL_SIGNINGKEY` / `GIT_WORK_SIGNINGKEY` to the signing public keys (`git config
   user.signingkey` on the laptop prints each one), then `./bin/devbox up` - until then manual git as that
   identity over a forwarded agent (`ssh -A devbox`) cannot pick its key, and commits sign with nothing. If a
   previous bootstrap generated a private key, this run deletes it and prints its fingerprint to revoke.
2. Put **two fine-grained** GitHub tokens in `~/.config/devbox/secrets.env`: `GH_TOKEN_PERSONAL` and
   `GH_TOKEN_WORK` - `contents: write` on any repository agents push to without the GitHub App installed,
   plus `actions`/`checks` read, plus `issues`/`pull-requests` write only if agents should post. The working
   directory picks which one is used (`~/projects/work/**` is work, as with git identities);
   `devbox-gh-token --account` reports the choice. Do **not** use `gh auth login`: its web flow cannot
   request less than `repo` + `read:org` + `gist`, i.e. non-expiring account-wide write, stored in plaintext (no keyring
   in the container). A plain box-wide `GH_TOKEN` still works but overrides both and disables the
   per-directory choice.
3. Fill the rest of `~/.config/devbox/secrets.env` (mode 600) with plain `KEY=value` pairs for credentials
   every project shares - model API keys for OMP. It is sourced by every shell, interactive or not. Never
   put a single project's secrets there; those go in that project's own `.env`.
4. Place the work-app GitHub App credentials in `~/.config/work/work-app/` (`app-id` and
   `app.pem`, mode 600) if agents need them. Bootstrap creates that directory and never fetches secrets; the
   credential helper mints a repository-scoped installation token from them on every agent git operation
   once they exist, taking priority over the PAT.

There is no `op` step: the container holds no 1Password account and the binary is not installed. Project
secrets are rendered on the laptop (`op inject -i .env.tpl -o .env`) and copied in; a project needing Google
APIs gets a per-project service-account key, never `gcloud auth application-default login`. Reasoning and
commands: `docs/secrets.md`.

Manual git and signing need the agent forwarded (`ssh -A devbox`, not plain `ssh devbox`, herdr, or
`./bin/devbox shell`): `ssh -T git@github.com` → `Hi rozsival!`, `ssh -T git@work.github.com` →
`Hi rozsival-work!`. Agent sessions (the `omp` launcher) never need any of this - they push over HTTPS
with a token minted per operation. Full mechanism: `docs/git.md`.

## Optional but recommended, after the phases pass

```bash
ssh workstation 'cd ~/devbox && ./bin/devbox skills'   # agent skills + agent-browser + Chrome
./bin/sync-omp                                           # laptop ~/.omp/agent/config.yml → devbox
```

`skills` installs `agent-browser`, `skill-creator` and `find-skills` into `~/.agents/skills` (the directory
OMP reads), plus the `agent-browser` CLI and its Chrome build. It is separate from bootstrap because the
first run downloads ~180 MB, and it needs the Chrome shared libraries that the `Dockerfile` provides - so run
it after an `up` that includes the current image, not against a stale one. Both commands are idempotent;
details in `docs/toolchain.md#agent-skills-and-browser-automation`.

## When setup does not work

| Symptom                                 | Cause and fix                                                                                                                                                                               |
|-----------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `up` aborts on empty `BIND_ADDR`        | Preflight working as designed. Tailscale up, then `env`                                                                                                                                     |
| `Too many authentication failures`      | Missing `IdentitiesOnly yes` in the `Host devbox` block                                                                                                                                     |
| `Permission denied (publickey)`         | Key not in `DEVBOX_EXTRA_AUTHORIZED_KEYS` or on GitHub; restart                                                                                                                             |
| herdr machine stuck `offline`           | `~/.ssh/config` no longer parses (`ssh -G devbox` names the line; herdr runs the system `ssh -o BatchMode=yes` and only logs `connection was lost`), or 1Password locked / key not approved |
| `Host key verification failed`          | Data dir was wiped; `ssh-keygen -R '[workstation]:2223'`                                                                                                                                  |
| `Permission denied` writing `/home/dev` | `${DEVBOX_DATA_DIR}` not owned by `HOST_UID:HOST_GID`                                                                                                                                       |
| SSH itself is the broken thing          | `./bin/devbox shell` on the host bypasses the container's sshd                                                                                                                              |
| `git push` hangs on a host-key prompt   | Key seeding failed; `ssh-keyscan github.com >> ~/.ssh/known_hosts`                                                                                                                          |

`authorized_keys` is rebuilt on every container start from `https://github.com/<DEVBOX_GITHUB_USER>.keys` plus
`DEVBOX_EXTRA_AUTHORIZED_KEYS`, so key changes take a restart, not a manual edit.
