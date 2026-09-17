---
name: devbox-setup
description: Sets up the devbox end to end - the dedicated laptop SSH key, the two ~/.ssh/config host blocks, the first deploy and .env on the workstation, herdr machine registration, and the in-container manual steps (filling ~/.config/devbox/identities.conf, one GH_TOKEN_<SLUG> per identity in secrets.env, GitHub App credentials per identity). Use this whenever someone is installing or re-installing the devbox, onboarding a new laptop, says they cannot connect, gets "Too many authentication failures", "Permission denied (publickey)", an empty BIND_ADDR preflight failure, or a herdr machine stuck offline, or asks which manual steps are still outstanding.
---

# devbox setup

Five phases, strict order: laptop key → `~/.ssh/config` → deploy/`.env` on the workstation → project
Docker → in-container identity steps. Each ends with a check that must pass before moving on - a failure two
phases later is almost always an earlier phase left unverified.

Command/config blocks live in `docs/setup.md` - read the section pointed to, not from memory, so a changed
default gets picked up. Phases 1-2 are the laptop's share of a larger layout (GitHub keys, gitconfigs, the
agent git override, tokens) owned by `devbox-laptop`; `./bin/laptop-doctor` checks it.

## Phase 1 - the laptop key (on the laptop)

The key is a 1Password SSH item served by its agent; only the public half lands in `~/.ssh/devbox.pub`,
which `IdentityFile` selects. Steps: `docs/setup.md#1-create-the-laptop-key`:

```bash
ssh-copy-id -i ~/.ssh/devbox.pub -p 2222 <user>@<workstation>  # host sshd, needed by ./bin/push
cat ~/.ssh/devbox.pub                                        # goes into .env in phase 3
```

herdr's saved-machine connections run in background, needing 1Password unlocked, the key approved - a
machine flapping between `connecting` and `offline` while locked is that, not a devbox fault. Fallback if
unworkable: a dedicated passphrase-less file key (documented).

## Phase 2 - `~/.ssh/config` (on the laptop)

Two `Host` entries, same machine, different ports: `2222` the workstation's sshd (needed by
`bin/push`), `2223` the container's. Copy both blocks verbatim from
`docs/setup.md#2-add-the-sshconfig-blocks`; the field people drop and debug for an hour is
`IdentitiesOnly yes` - without it the agent offers every key it holds and the server rejects with
`Too many authentication failures` before the right one.

Check: `ssh -G devbox | grep -E '^(hostname|port|user|identityfile|identitiesonly) '` then
`ssh <workstation> true`.

## Phase 3 - deploy and configure (from the laptop)

```bash
./bin/push <workstation>
ssh <workstation> 'cd ~/devbox && ./bin/devbox env'
```

`env` creates `.env` from `.env.example` (never clobbers an existing), filling `BIND_ADDR` from
`tailscale ip -4` plus `HOST_UID`/`HOST_GID` - the dedicated `dev` host user if it exists, else the invoking
user. Tailscale must be up first: down means no address to write, and `up` refuses the empty value. Then
edit `~/devbox/.env` on the workstation - at minimum, the phase-1 public key in
`DEVBOX_EXTRA_AUTHORIZED_KEYS` (newline-separated).

Do phase 4 **before** the first `up`: it moves the data directory, refuses while the container's up.

```bash
ssh <workstation> 'cd ~/devbox && ./bin/devbox up && ./bin/devbox doctor'
```

`doctor` is phase 3's acceptance test: compose; `BIND_ADDR` vs Tailscale; something on
`BIND_ADDR:${DEVBOX_SSH_PORT}` and **nothing** on `0.0.0.0`; container health; PID 1 `dev`; project Docker
daemon answering, rootless; `host.docker.internal` resolving; project-port boundary service active; toolchain
probes - exits non-zero on any failure.

`.env` is gitignored **and** excluded from `bin/push`, so later deploys never touch it.

If the node's Tailscale address changes later, `doctor` reports `BIND_ADDR is X but Tailscale reports Y`;
re-run `./bin/devbox env && ./bin/devbox up`.

## Phase 4 - project Docker (on the workstation, once)

```bash
ssh -t <workstation> 'cd ~/devbox && sudo ./bin/rootless-docker'
```

Needs `sudo`, idempotent; `--check` reports state, no changes made. Installs `uidmap`, `slirp4netns`;
creates unprivileged host user `dev:devbox`, daemon owner; moves `DEVBOX_DATA_DIR` to `/home/dev`, chowns
the tree; installs the nftables table and `devbox-docker-firewall.service`, keeping project ports off the
Tailnet and LAN; enables a lingering rootless `dockerd` on `/run/devbox/docker.sock`.

Two caveats (`docs/docker.md`):

- **Run it before the first `up`, or after `./bin/devbox down`.** It refuses while the container runs - it
  moves the bind mount out from under it. Nothing's destroyed - just `mv` plus `chown`; keys, repos, `gh`
  login survive.
- **`DEVBOX_DATA_DIR` must end up as `/home/dev`.** The daemon resolves a project's bind mounts as host
  paths - both sides must agree, or every relative mount silently resolves to an empty directory.

Check: the Docker probes in `./bin/devbox doctor`, then `ssh devbox 'docker run --rm hello-world'`.

## Phase 5 - attach herdr and finish the identity steps

```bash
ssh devbox true                                # accept the container host key once
herdr machine add devbox --label "Devbox"      # interactive terminal: it verifies the remote binary
herdr                                          # "Devbox" appears next to "Local"
```

Bootstrap runs every container start, fully idempotent, printing outstanding steps at the end - so
`./bin/devbox bootstrap` answers "what's left" authoritatively, never a guess:

```bash
ssh <workstation> 'cd ~/devbox && ./bin/devbox keys'       # installed public keys + host-key fingerprint
```

The devbox generates no keys - it installs only the laptop's public keys from
`~/.config/devbox/identities.conf` (`pubkey` for authentication, `signing_pubkey` for signing). Nothing to
register on GitHub - already your normal, registered laptop keys.

1. Create `~/.config/devbox/identities.conf` - `cp /opt/devbox/home/.config/devbox/identities.conf.example
   ~/.config/devbox/identities.conf` (bootstrap never writes it for you: the example validates, so seeding
   it would give agent commits the placeholder author) - then fill it in: one `[slug]` block per account, `pubkey`/`signing_pubkey` set to
   the public keys `git config user.signingkey` prints for that account on the laptop, then
   `./bin/devbox up` - until then, manual git over a forwarded agent (`ssh -A devbox`) can't pick a key,
   commits sign with nothing. A prior bootstrap's private key is deleted this run, fingerprint printed to
   revoke.
2. Put one fine-grained GitHub token per identity in `~/.config/devbox/secrets.env`: `GH_TOKEN_<SLUG>`
   (e.g. `GH_TOKEN_PERSONAL`, `GH_TOKEN_WORK`) - `contents: write` on repos agents push to without the
   GitHub App, plus `actions`/`checks` read, `issues`/`pull-requests` write only if agents should post.
   Working directory picks which (the `dir` prefixes in `identities.conf`, same rule as git identities);
   `devbox-gh-token --account` reports it. Skip `gh auth login`: its web flow can't scope below `repo` +
   `read:org` + `gist` - non-expiring, account-wide, plaintext (no keyring here). A box-wide `GH_TOKEN`
   works but overrides every identity's own, killing the per-directory choice.
3. Fill the rest of `~/.config/devbox/secrets.env` (mode 600) with project-shared `KEY=value` pairs - model
   API keys for OMP. Every shell sources it, interactive or not. Never put one project's secrets here;
   those go in that project's `.env`.
4. Place each identity's GitHub App credentials in *that identity's own* `app` directory from
   `identities.conf` (`app-id`, `app.pem`, mode 600) if it needs one. Bootstrap creates the directory,
   never fetches secrets; once present, the credential helper mints a repo-scoped installation token per
   agent git op for that identity, ahead of the PAT.

No `op` step: the container holds no 1Password account or `op` binary. Project secrets render on the
laptop (`op inject -i .env.tpl -o .env`), copy in; Google APIs need a per-project service-account key, never
`gcloud auth application-default login`. Reasoning, commands: `docs/secrets.md`.

Manual git and signing need the agent forwarded (`ssh -A devbox`, not plain `ssh devbox`, herdr, or
`./bin/devbox shell`): `ssh -T git@github.com` → `Hi <your-github-username>!`, `ssh -T git@work.github.com`
→ `Hi <your-work-username>!`. Agent sessions (`omp` launcher) skip this, pushing HTTPS with a token minted
per operation. Full mechanism: `docs/git.md`.

## Optional but recommended, after the phases pass

```bash
ssh <workstation> 'cd ~/devbox && ./bin/devbox skills'   # agent skills + agent-browser + Chrome
./bin/sync-omp                                           # laptop ~/.omp/agent/config.yml → devbox
```

`skills` installs `agent-browser`, `skill-creator`, `find-skills` into `~/.agents/skills` (OMP's skills
dir), plus its CLI and Chrome build. Separate from bootstrap since the first run downloads ~180 MB, needs
Chrome shared libraries the `Dockerfile` provides - run after an `up` on the current image, not stale. Both
idempotent; details: `docs/toolchain.md#agent-skills-and-browser-automation`.

## When setup does not work

| Symptom                                 | Cause and fix                                                                                                                                                                  |
|-----------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `up` aborts on empty `BIND_ADDR`        | Preflight by design - Tailscale up, then `env`                                                                                                                                |
| `Too many authentication failures`      | Missing `IdentitiesOnly yes` in `Host devbox` block                                                                                                                           |
| `Permission denied (publickey)`         | Key not in `DEVBOX_EXTRA_AUTHORIZED_KEYS` or on GitHub; restart                                                                                                               |
| herdr machine stuck `offline`           | `~/.ssh/config` no longer parses (`ssh -G devbox` names the line; herdr's system `ssh -o BatchMode=yes` logs only `connection was lost`), or 1Password locked / key not approved |
| `Host key verification failed`          | Data dir was wiped; `ssh-keygen -R '[<workstation>]:2223'`                                                                                                                    |
| `Permission denied` writing `/home/dev` | `${DEVBOX_DATA_DIR}` not owned by `HOST_UID:HOST_GID`                                                                                                                         |
| SSH itself is the broken thing          | `./bin/devbox shell` on host bypasses container's sshd                                                                                                                        |
| `git push` hangs on a host-key prompt   | Key seeding failed; `ssh-keyscan github.com >> ~/.ssh/known_hosts`                                                                                                            |

`authorized_keys` is rebuilt on every container start from `https://github.com/<DEVBOX_GITHUB_USER>.keys` plus
`DEVBOX_EXTRA_AUTHORIZED_KEYS`, so key changes take a restart, not a manual edit.
