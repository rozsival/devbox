---
name: devbox-deploy
description: Pushes repo changes out to the devbox and applies them - ./bin/push, choosing between up, rebuild and bootstrap for the file you actually changed, rehearsing the rsync, and verifying with doctor. Use this whenever someone wants to deploy, redeploy, sync or "push to the devbox", has edited the Dockerfile, docker-compose.yml, container/, home/ or .env and wants it live, is bumping a pinned tool version, asks whether a redeploy will wipe their keys or projects, or needs to restart, roll back or back up the devbox.
---

# devbox deploy

Deploying is two easily-conflated steps: **sync the repo** to the workstation (`bin/push`, laptop side),
**apply it** to the running container (`bin/devbox`, workstation side) - picking the wrong one is usually
why a change seems to do nothing.

Full reference: `docs/cli.md` (flags), `docs/operations.md` (restart, backup, troubleshooting).

## The common case

```bash
./bin/push workstation --up     # rsync, then ./bin/devbox up on the host
```

`bin/push` is `rsync -az --delete` excluding `.git`, `.env`, `data/`, `.DS_Store` - host defaults to
`$DEVBOX_HOST` then `workstation`, remote to `$DEVBOX_REMOTE_PATH` then `~/devbox`.

`--up` runs remote `up` over `ssh -t` so the live-session prompt reaches a human; an agent has none, so
`up` refuses instead - correct, not an obstacle. Check `./bin/devbox sessions` first; if connected, sync
files, report the pending step and whose session dies, let the user decide. `--force` needs an explicit
go-ahead: it kills shells/panes with no client-side message.

`bin/devbox` only runs on the workstation, driving the local Docker daemon. From the laptop that's
`ssh workstation 'cd ~/devbox && ./bin/devbox <cmd>'`, or just `--up`.

## Which apply step does the change need

| Changed                               | Apply with                       | Why                               |
|---------------------------------------|----------------------------------|-----------------------------------|
| `docker-compose.yml`, `.env`          | `up`                             | Config hash change recreates      |
| `Dockerfile`, apt list, install block | `up`                             | Rebuilds changed layers           |
| A pinned `ARG <TOOL>_VERSION`         | `up`, or `rebuild` for no cache  | `ARG` invalidates that layer      |
| `container/*`, `home/*`               | `up`                             | In build context, recreate        |
| Re-apply user setup only              | `bootstrap`                      | No restart, no lost panes         |
| Only a `bin/*` script                 | nothing                          | Read at invocation, on host       |
| `container/skills.sh`                 | `up`, then `./bin/devbox skills` | Only run on demand                |
| `~/.omp/agent/config.yml` (laptop)    | `./bin/sync-omp`                 | Personal state, not repo content  |
| `bin/rootless-docker` on a new host   | `sudo ./bin/rootless-docker`     | Host provisioning, needs sudo     |

`up` = `docker compose build` then `docker compose up -d` behind a preflight (`BIND_ADDR` non-empty,
`${DEVBOX_DATA_DIR}` present and owned by `HOST_UID:HOST_GID`); missing project Docker socket only warns -
devbox works without it. `rebuild` = `docker compose build --no-cache && docker compose up -d`.

A recreate kills every live SSH session instantly, no client-side reason - looks like `ssh devbox` closed
itself. `up`/`down`/`rebuild` count sessions first: connected ones prompt on a terminal, refuse in a
script - `--force` overrides, needing say-so. `./bin/devbox sessions` also shows sshd's recent
`Accepted`/`Disconnected` lines. Only `bootstrap`, `skills`, `hook` are pane-safe: all `docker compose exec`
into the container. `hook` restarts `moshi-hook` (after `moshi-hook pair`, or crashing) without
costing anyone their session.

`container/` and `home/` are bind-mounted `:ro` *and* `COPY`d into the image (`COPY container/` / `COPY
home/` in the `Dockerfile`, as fallback): the mount makes new bytes visible immediately; editing also
changes the build context - `up` produces a new image id, compose recreates the container, re-running
entrypoint and bootstrap. That's why `up` answers both; unchanged, it's idempotent: compose reports
`Container devbox Running`, nothing restarts.

One caveat for `home/`: bootstrap rewrites several files unconditionally - `~/.bashrc.d/devbox.sh`,
`~/.ssh/config`, `~/.local/libexec/devbox-agent/{omp,gh,devbox-git-credential,devbox-git-no-ssh}`,
`~/.config/devbox/agent*.gitconfig` - all generated, not hand-edited, so template edits land next run.
`~/.gitconfig`, `~/.config/devbox/secrets.env`, OMP config are create-if-absent: editing those templates
doesn't reach an existing home - delete the file under `${DEVBOX_DATA_DIR}`, or apply by hand. Git
identity re-applies via `git config --global` regardless.

## What a redeploy cannot destroy

This matters: "will I lose my keys / repos / gh login" is a flat no, by construction:

- `.env` is gitignored **and** rsync-excluded, so host-local config survives every push.
- `${DEVBOX_DATA_DIR}` is a host bind mount, not the image: `~/.ssh/id_*.pub`,
  `~/.ssh/signing_*.pub` (public keys only - devbox holds no private key), sshd host key under
  `~/.ssh/host/`, `~/.config/gh`, `~/.config/devbox/secrets.env`, `~/.config/devbox/agent*.gitconfig`,
  `~/.local/libexec/devbox-agent` (`omp` launcher, `gh` shim, credential helper, fence), `~/.gitconfig`,
  every project checkout, project daemon's images, build cache, named volumes under
  `~/.local/share/docker` - all persist across `up`, `rebuild`, image changes.
- `--delete` applies only to synced paths; it *will* remove hand-added files from a tracked directory's
  remote copy - the remote is a mirror, deliberately.

What does **not** survive a recreate: anything in the container's writable layer, e.g.
`npm install -g <pkg>` or `nvm install <version>`, landing in `/opt`. Pin those in `Dockerfile`.

## Rehearse when unsure

```bash
rsync -azni --delete --exclude .git --exclude .env --exclude 'data/' --exclude .DS_Store \
  ./ workstation:devbox/
```

`-n` is the dry run, `-i` itemizes changes. Without `-i` a dry run prints almost nothing - reads as "no
changes" when it's not.

## Verify after every deploy

```bash
ssh workstation 'cd ~/devbox && ./bin/devbox doctor'
```

`doctor` runs all checks, reports each, exits non-zero on any failure: compose present, `BIND_ADDR` equal
to `tailscale ip -4`, port listening on `BIND_ADDR`, **nothing** on `0.0.0.0`, container `healthy`, PID 1
as `dev`, eleven toolchain probes, real exit codes, `moshi-hook` running (unpaired warns, stopped fails -
`./bin/devbox hook` restarts it), project Docker daemon reachable and rootless, `host.docker.internal`
resolving to publish address, and `devbox-docker-firewall` active.

If `doctor` reports `BIND_ADDR is X but Tailscale reports Y`, the node's address changed:
`./bin/devbox env && ./bin/devbox up`.

For a failed start, `./bin/devbox logs` (100 lines, `-f` follows) shows the entrypoint's output:
host-key generation, `authorized_keys` assembly, bootstrap, then `Server listening on 0.0.0.0 port 2222`.

## Rolling back and backing up

A rollback is just deploying an earlier commit - the image builds from the repo, no separate artifact to
revert. `bin/push` syncs the working tree; commit or stash first, or in-flight edits ship instead:

```bash
git stash                                                      # or commit
git switch --detach <good-commit> && ./bin/push workstation --up
git switch - && git stash pop                                  # back to where you were
```

State lives outside the repo, in a tree owned by dedicated `dev`, so backup needs `sudo` on the
host:

```bash
ssh -t workstation 'sudo tar -C /home --exclude=dev/.local/share/docker -czf /tmp/devbox-home.tar.gz dev'
scp workstation:/tmp/devbox-home.tar.gz "devbox-home-$(date +%F).tar.gz"
ssh -t workstation 'sudo rm -f /tmp/devbox-home.tar.gz'
```

The exclusion drops the project daemon's images, cache, named volumes; dump a database you care about,
don't tar its volume. Restore: extract into place, preserve `HOST_UID:HOST_GID` ownership, then
`./bin/devbox up`. Copy the host's `.env` separately - in neither repo nor data dir. The sshd host
key *is* in the archive, so restore keeps the laptop's `known_hosts` valid.

## Repo conventions when the change is yours

`AGENTS.md` is authoritative. Parts biting most often: `apt-get` only, never `apt`; every external binary
comes from an explicit `ARG <TOOL>_VERSION`, checksum-verified where upstream publishes one (never invent a
hash); no root, no `cap_add`, no Docker socket; `BIND_ADDR` on every published port;
bootstrap steps stay individually guarded, so re-runs are no-ops; commits are lowercase Conventional
Commits, no final punctuation, 100 characters max.
