# ⌨️ CLI reference

Two entrypoints, both hand-written bash with `set -euo pipefail`: `bin/devbox` runs **on the workstation**,
`bin/push` runs **on the laptop**. Log prefixes are `[INFO]`, `[OK]`, `[WARN]`, `[ERROR]`, matching
`workstation`.

## `bin/devbox`

```
Usage: ./bin/devbox <command>

  env               Create .env from .env.example and sync BIND_ADDR, HOST_UID, HOST_GID
  up                Preflight, then build and start the container
  down              Stop and remove the container
  rebuild           Rebuild the image from scratch and restart
  bootstrap         Re-run the in-container user setup
  shell             Open a login shell inside the container
  logs [-f]         Show container logs (last 100 lines; -f follows)
  keys              Print the devbox public keys and sshd host-key fingerprint
  doctor            Check host wiring, exposure, and the in-container toolchain
```

Every command loads `.env` first and fails with a pointer to `.env.example` if it is missing.

- **`env`** - never clobbers an existing `.env`; rewrites `BIND_ADDR` from `tailscale ip -4` and
  `HOST_UID`/`HOST_GID` from the current user.
- **`up`** - preflight (`BIND_ADDR` non-empty; `DEVBOX_DATA_DIR` present and owned by `HOST_UID:HOST_GID`,
  created with `install -d` when absent), then `docker compose up -d --build`.
- **`down`** - `docker compose down`. The bind mount and `.env` are untouched.
- **`rebuild`** - `docker compose build --no-cache && docker compose up -d`. Use after a `Dockerfile` change.
- **`bootstrap`** - `docker compose exec` of `container/bootstrap.sh`; idempotent and reprints the checklist.
- **`shell`** - `docker compose exec -it devbox bash -l`. Works even when sshd or Tailscale is broken.
- **`logs`** - `--tail 100` by default; `-f` follows.
- **`keys`** - `id_personal.pub`, `id_work.pub` and the sshd host-key fingerprint: the paste targets for
  GitHub.
- **`doctor`** - the checks below. It runs all of them, reports each one, and exits non-zero if any failed.

### What `doctor` checks

1. `docker` and `docker compose` v2 present
2. `BIND_ADDR` non-empty and equal to `tailscale ip -4`
3. Something listening on `BIND_ADDR:${DEVBOX_SSH_PORT}`, and **nothing** on `0.0.0.0`
4. Container health status is `healthy`
5. PID 1 runs as `dev` (no root process)
6. Ten toolchain probes, each with its real exit code: `herdr`, `omp`, `node`, `pnpm`, `gh`, `lazygit`, `wt`,
   `terraform`, `op`, `git`

## `bin/push`

```
Usage: ./bin/push [host] [--up]

  host    SSH host to deploy to (default: $DEVBOX_HOST, then 'workstation')
  --up    Run './bin/devbox up' on the host after syncing

Environment:
  DEVBOX_HOST         default SSH host
  DEVBOX_REMOTE_PATH  remote repo path (default: ~/devbox)
```

The sync is `rsync -az --delete` excluding `.git`, `.env`, `data/` and `.DS_Store`. It checks for `rsync` on
both sides first and prints the exact remedy if it is missing.

```bash
./bin/push workstation              # sync only
./bin/push workstation --up         # sync, then build and start
DEVBOX_REMOTE_PATH=~/devbox-test ./bin/push workstation
```

## ❓ FAQ

**Why plain bash instead of bashly, like `workstation`?**
Nine commands and no code-generation step. `bin/src` plus a `pnpm run build:cli` pipeline would be pure
overhead here. Keep it hand-written.

**Can I run `bin/devbox` from the laptop?**
No - it drives the local Docker daemon. Use `ssh workstation 'cd ~/devbox && ./bin/devbox <cmd>'`, or
`./bin/push workstation --up` for the common case.

**Is `--delete` dangerous?**
It only applies to paths that are synced, and `.env`, `data/` and `.git` are excluded. Files you added to the
remote copy of a *tracked* directory will be removed - that is intentional, the remote is a mirror.

**`up` vs `rebuild` - which do I need?**
`up` after a compose, `.env`, `container/` or `home/` change (it rebuilds layers that changed). `rebuild` when
you need a cache-free image, e.g. after bumping a pinned version.

**Does `bootstrap` overwrite my dotfiles?**
Only `~/.bashrc.d/devbox.sh`, which is generated. `~/.gitconfig`, `~/.ssh/config`, `secrets.env` and the OMP
config are created if absent and then left alone; derived Git identity values are re-applied with
`git config --global` on each run.

**`doctor` says `BIND_ADDR is X but Tailscale reports Y`.**
The node's Tailscale address changed. `./bin/devbox env && ./bin/devbox up`.
