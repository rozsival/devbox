# 🔄 Operations

Day-to-day running: redeploy, restart, persistence, backup, and the failure modes worth knowing.

## Redeploy

```bash
./bin/push workstation --up
```

Repeatable by design and non-destructive: `.env`, `${DEVBOX_DATA_DIR}`, the generated SSH keys and the sshd
host key all survive, and `bootstrap` re-runs as a no-op. Verify with `./bin/devbox keys` - the fingerprints
must be identical before and after.

Use `rebuild` instead of `up` when a pinned version changed and you want a cache-free image:

```bash
ssh workstation 'cd ~/devbox && ./bin/devbox rebuild && ./bin/devbox doctor'
```

## Persistence

`${DEVBOX_DATA_DIR}` on the host is bind-mounted at `/home/dev`: dotfiles, both SSH identities, the sshd host
key, `~/.config/gh`, and the whole `~/projects` tree. A bind mount rather than a named volume so `tar` can
back it up and the host user (same UID) can inspect it. Container and image rebuilds keep everything,
including the client's `known_hosts` entry.

| Event                            | Filesystem | Running panes |
|----------------------------------|------------|---------------|
| herdr client killed / lid closed | kept       | **kept**      |
| `docker compose restart`         | kept       | lost          |
| `./bin/devbox down` + `up`       | kept       | lost          |
| `./bin/devbox rebuild`           | kept       | lost          |
| `${DEVBOX_DATA_DIR}` deleted     | lost       | lost          |

Panes survive client loss because the herdr server runs in the container; they do not survive the container
restarting with it.

## Backup

```bash
ssh workstation 'tar -C /home/vit -czf - devbox-data' > devbox-data-$(date +%F).tar.gz
```

Restore by extracting into place with the ownership preserved (`HOST_UID:HOST_GID`), then `./bin/devbox up`.
The `.env` file on the host is worth copying separately - it is not in the repo and not in the data dir.

## Health

```bash
ssh workstation 'cd ~/devbox && ./bin/devbox doctor'     # full check, non-zero on failure
ssh workstation 'cd ~/devbox && ./bin/devbox logs -f'    # follow sshd output
```

The compose healthcheck is `ss -ltn | grep -q ":2222"` every 30s with a 20s start period, so a container that
comes up without a listening sshd is reported `unhealthy` rather than silently broken.

## Troubleshooting

**`Too many authentication failures`**
The agent offered more than six keys. Add `IdentitiesOnly yes` + `IdentityFile ~/.ssh/devbox` to the `Host`
block.

**herdr machine flaps between `connecting` and `offline`**
The key needs interactive approval (1Password agent) and background connections cannot answer. Use the
dedicated file key - see [Setup](setup.md#1-create-the-laptop-key).

**`up` fails with `BIND_ADDR is empty`**
The preflight working as intended. Run `./bin/devbox env` (Tailscale must be up first).

**`doctor` reports `published on 0.0.0.0`**
A `ports` entry lost its address scope. The devbox is internet-exposed until fixed: correct
`docker-compose.yml`, then `up`.

**Container is `unhealthy`**
sshd is not listening. `./bin/devbox logs` - usually a failed `authorized_keys` fetch or wrong permissions on
`/home/dev/.ssh`.

**`Host key verification failed`**
The data dir was recreated, so the host key is new. `ssh-keygen -R '[workstation]:2223'`, reconnect, accept
once.

**Permission denied writing to `/home/dev`**
`${DEVBOX_DATA_DIR}` is not owned by `HOST_UID:HOST_GID`. `sudo chown -R 1000:1000 <dir>`.

**A tool "disappeared" after a rebuild**
It was installed by hand into the old image. Add it to the `Dockerfile` - see
[Toolchain](toolchain.md#adding-a-tool).

**`wt switch` does not change directory**
It was run inside a pipeline, so its `cd` happened in a subshell. Run it directly.

## ❓ FAQ

**Does the container come back after a host reboot?**
Yes - `restart: unless-stopped`. Tailscale must be up for the published address to bind; if the host boots
without it, `up` again once it is.

**How do I stop everything without losing state?**
`./bin/devbox down`. State is on the bind mount; only running processes end.

**Can I run two devboxes on one host?**
Yes, with a second checkout: different `DEVBOX_SSH_PORT`, different `DEVBOX_DATA_DIR`, and a different compose
project name. `DEVBOX_REMOTE_PATH` in `bin/push` controls where it lands.

**How do I see what changed before deploying?**
Rehearse the sync with `-n`:

```bash
rsync -azn --delete --exclude .git --exclude .env --exclude 'data/' ./ workstation:devbox/
```

**Is `bootstrap` safe to run while I am working in a pane?**
Yes. Every step is guarded and it only touches config files; it does not restart sshd or kill sessions.

**Where do container logs live?**
Docker's json-file log for the `devbox` service - `./bin/devbox logs`. sshd logs to stderr (`-e`), so
authentication failures appear there.

**How do I move the devbox to another workstation?**
`bin/push` to the new host, `./bin/devbox env`, restore the data tarball (or start fresh and re-run the
[manual checklist](secrets.md#manual-checklist)), then `./bin/devbox up`. The SSH host key comes from the data
dir, so a restore keeps the laptop's `known_hosts` valid.
