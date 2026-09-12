---
name: devbox-deploy
description: Pushes repo changes out to the devbox and applies them - ./bin/push, choosing between up, rebuild and bootstrap for the file you actually changed, rehearsing the rsync, and verifying with doctor. Use this whenever someone wants to deploy, redeploy, sync or "push to the devbox", has edited the Dockerfile, docker-compose.yml, container/, home/ or .env and wants it live, is bumping a pinned tool version, asks whether a redeploy will wipe their keys or projects, or needs to restart, roll back or back up the devbox.
---

# devbox deploy

Deploying is two steps that are easy to conflate: **sync the repo** to the workstation (`bin/push`, from the
laptop) and **apply it** to the running container (`bin/devbox`, on the workstation). Picking the wrong apply
step is the usual reason a change appears to have no effect.

Full reference: `docs/cli.md` for flags, `docs/operations.md` for restart, backup and troubleshooting.

## The common case

```bash
./bin/push workstation --up     # rsync, then ./bin/devbox up on the host
```

`bin/push` is `rsync -az --delete` excluding `.git`, `.env`, `data/` and `.DS_Store`. Host defaults to
`$DEVBOX_HOST` then `workstation`; remote path to `$DEVBOX_REMOTE_PATH` then `~/devbox`.

`bin/devbox` only ever runs on the workstation - it drives the local Docker daemon. From the laptop that is
`ssh workstation 'cd ~/devbox && ./bin/devbox <cmd>'`, or just `--up`.

## Which apply step does the change need

| Changed                               | Apply with                       | Why                               |
|---------------------------------------|----------------------------------|-----------------------------------|
| `docker-compose.yml`, `.env`          | `up`                             | Config hash change recreates      |
| `Dockerfile`, apt list, install block | `up`                             | Rebuilds changed layers           |
| A pinned `ARG <TOOL>_VERSION`         | `up`, or `rebuild` for no cache  | The `ARG` invalidates that layer  |
| `container/*`, `home/*`               | `up`                             | In the build context, so recreate |
| Re-apply user setup only              | `bootstrap`                      | No restart, no lost panes         |
| Only a `bin/*` script                 | nothing                          | Read at invocation, on the host   |
| `container/skills.sh`                 | `up`, then `./bin/devbox skills` | Script is only run on demand      |
| `~/.omp/agent/config.yml` (laptop)    | `./bin/sync-omp`                 | Personal state, not repo content  |

`up` = `docker compose build` then `docker compose up -d` behind a preflight (`BIND_ADDR` non-empty;
`${DEVBOX_DATA_DIR}` present and owned by `HOST_UID:HOST_GID`). `rebuild` = `docker compose build --no-cache
&& docker compose up -d`.

A recreate kills every live SSH session instantly, and the client prints no reason at all - it looks like
`ssh devbox` closed itself. `up`, `down` and `rebuild` therefore count established sessions first: with any
connected they prompt on a terminal and refuse in a script, and `--force` skips that. Check first with
`./bin/devbox sessions`, which also prints sshd's recent `Accepted`/`Disconnected` lines. Only `bootstrap`
and `skills` are safe with panes attached: both are `docker compose exec` into the running container.

`container/` and `home/` are both bind-mounted `:ro` *and* `COPY`d into the image as a fallback (the
`COPY container/` / `COPY home/` lines in the `Dockerfile`). The mount means the new bytes are visible
immediately; the `COPY` means editing them changes the build context, so `up` produces a new image id and
compose recreates the container - which re-runs the entrypoint and therefore bootstrap. That is why `up` is
the single answer for both. `up` with no changes at all is idempotent: compose reports
`Container devbox Running` and nothing restarts.

One caveat for `home/` specifically. Bootstrap rewrites two files unconditionally - `~/.bashrc.d/devbox.sh`
and `~/.ssh/config` - because both are generated, not hand-edited, so template edits land on the next run.
`~/.gitconfig`, both `secrets*.env` files and the OMP config are create-if-absent: editing those templates
does not reach a home that already has them, so delete the file under `${DEVBOX_DATA_DIR}` first or apply it
by hand. Derived Git identity values are re-applied with `git config --global` on every run regardless.

## What a redeploy cannot destroy

This matters because the answer to "will I lose my keys / repos / gh login" is a flat no, by construction:

- `.env` is gitignored **and** rsync-excluded, so host-local config survives every push.
- `${DEVBOX_DATA_DIR}` is a bind mount and is not part of the sync at all: `~/.ssh/id_personal`,
  `id_work`, the sshd host key under `~/.ssh/host/`, `~/.config/gh`, `~/.gitconfig` and every project
  checkout persist across `up`, `rebuild` and image changes.
- `--delete` applies only to synced paths. It *will* remove files added by hand to the remote copy of a
  tracked directory - the remote is a mirror, deliberately.

What does **not** survive a recreate: anything written to the container's writable layer, e.g.
`npm install -g <pkg>` or `nvm install <version>`, which land in `/opt`. Pin those in the `Dockerfile`
instead.

## Rehearse when unsure

```bash
rsync -azni --delete --exclude .git --exclude .env --exclude 'data/' --exclude .DS_Store \
  ./ workstation:devbox/
```

`-n` is the dry run, `-i` itemizes what would change. Without `-i` a dry run prints almost nothing, which
reads as "no changes" and is not.

## Verify after every deploy

```bash
ssh workstation 'cd ~/devbox && ./bin/devbox doctor'
```

`doctor` runs all its checks, reports each, and exits non-zero if any failed: compose present, `BIND_ADDR`
equal to `tailscale ip -4`, the port listening on `BIND_ADDR` and **nothing** on `0.0.0.0`, container
`healthy`, PID 1 running as `dev`, and ten toolchain probes with their real exit codes.

If `doctor` reports `BIND_ADDR is X but Tailscale reports Y`, the node's address changed:
`./bin/devbox env && ./bin/devbox up`.

For a failed start, `./bin/devbox logs` (last 100 lines, `-f` follows) shows the entrypoint's own output -
host-key generation, `authorized_keys` assembly, bootstrap, then `Server listening on 0.0.0.0 port 2222`.

## Rolling back and backing up

A rollback is an ordinary deploy of an earlier commit - the image is built from the repo, so there is no
separate artifact to revert. `bin/push` syncs the working tree, so commit or stash first, otherwise the
in-flight edits are what ships:

```bash
git stash                                                      # or commit
git switch --detach <good-commit> && ./bin/push workstation --up
git switch - && git stash pop                                  # back to where you were
```

State lives outside the repo, so back it up from the host and stream it to the laptop:

```bash
ssh workstation 'tar -C /home/vit -czf - devbox-data' > devbox-data-$(date +%F).tar.gz
```

Restore by extracting into place with `HOST_UID:HOST_GID` ownership preserved, then `./bin/devbox up`. Copy
the host's `.env` separately - it is in neither the repo nor the data dir. The sshd host key *is* in the
archive, so a restore keeps the laptop's `known_hosts` valid.

## Repo conventions when the change is yours

`AGENTS.md` is authoritative. The parts that bite most often: `apt-get` only, never `apt`; every external
binary comes from an explicit `ARG <TOOL>_VERSION` and is checksum-verified where upstream publishes a
checksum file (never invent a hash); no root, no `cap_add`, no Docker socket; `BIND_ADDR` on every published
port; bootstrap steps stay individually guarded so a re-run is a no-op; commits are lowercase Conventional
Commits, no final punctuation, 100 characters max.
