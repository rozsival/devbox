# 🔄 Operations

Day-to-day ops: redeploy, restart, persistence, backup, and the failure modes worth knowing.

## Redeploy

```bash
./bin/push <workstation> --up
```

Repeatable, non-destructive: `.env`, `${DEVBOX_DATA_DIR}`, identity public keys, and the sshd host key
survive; `bootstrap` re-runs as a no-op. Verify with `./bin/devbox keys` - public keys and host-key
fingerprint must match before and after.

Use `rebuild` over `up` for a cache-free image after a pinned version changes:

```bash
ssh <workstation> 'cd ~/devbox && ./bin/devbox rebuild && ./bin/devbox doctor'
```

## Persistence

`${DEVBOX_DATA_DIR}` bind-mounts at `/home/dev`: dotfiles, every SSH identity's public keys,
`~/.config/devbox` (`identities.conf`, `secrets.env`, the rendered agent and user gitconfigs),
the sshd host key, `~/.config/gh`, and the whole `~/projects` tree. A bind mount (not a named volume) lets
`tar` back it up and the host user (same UID) inspect it. Rebuilds keep everything, including the client's
`known_hosts` entry.

| Event                            | Filesystem | Running panes |
|----------------------------------|------------|---------------|
| herdr client killed / lid closed | kept       | **kept**      |
| `docker compose restart`         | kept       | lost          |
| `./bin/devbox down` + `up`       | kept       | lost          |
| `./bin/devbox rebuild`           | kept       | lost          |
| `${DEVBOX_DATA_DIR}` deleted     | lost       | lost          |

Panes survive client loss - herdr's server runs in the container - but not a container restart.

Images, build cache, and named volumes for project containers live on the same bind mount, under
`/home/dev/.local/share/docker`: survive `rebuild`, excluded from `bin/push` like the rest of the data dir.
Prune manually: `docker system prune`.

## Backup

```bash
ssh -t <workstation> 'sudo tar -C /home --exclude=dev/.local/share/docker -czf /tmp/devbox-home.tar.gz dev'
scp <workstation>:/tmp/devbox-home.tar.gz "devbox-home-$(date +%F).tar.gz"
ssh -t <workstation> 'sudo rm -f /tmp/devbox-home.tar.gz'
```

Carries `~/.config/devbox/identities.conf` and `secrets.env` along with the rest of `/home/dev`: restoring
the tarball restores every registered identity - no re-running the manual checklist per account.

`sudo` is needed - the tree belongs to the dedicated `dev` account, not your host user. The exclusion drops
the project daemon's images, build cache **and named volumes** - all of `~/.local/share/docker`. Images
rebuild from a `Dockerfile`; a named volume worth keeping should be dumped instead (`docker compose exec db pg_dump …`),
which is the portable copy anyway.

Restore: extract into place with ownership preserved (`HOST_UID:HOST_GID`, i.e. `dev:devbox`), then
`./bin/devbox up`. Copy the host's `.env` separately - it's in neither the repo nor the data dir.

## Health

```bash
ssh <workstation> 'cd ~/devbox && ./bin/devbox doctor'     # full check, non-zero on failure
ssh <workstation> 'cd ~/devbox && ./bin/devbox logs -f'    # follow sshd output
```

The compose healthcheck, `ss -ltn | grep -q ":2222"` every 30s with a 20s start period, reports
`unhealthy` (not silently broken) for a container up without a listening sshd.

`doctor` also probes `docker --version`, `docker compose version`, whether the project Docker daemon is
reachable from the container and rootless, and whether `host.docker.internal` resolves.

## Troubleshooting

**`Too many authentication failures`**
The agent offered more than six keys. Add `IdentitiesOnly yes` + `IdentityFile ~/.ssh/devbox.pub` to the
`Host` block.

**herdr machine flaps between `connecting` and `offline`**
The 1Password agent serving the devbox key is locked or hasn't approved it for herdr, which can't answer
background prompts. Unlock and approve; if it persists, use the documented file-key exception - see
[Setup](setup.md#1-create-the-laptop-key).

**`up` fails with `BIND_ADDR is empty`**
Preflight working as intended. Run `./bin/devbox env` (Tailscale must be up first).

**`doctor` reports `published on 0.0.0.0`**
A `ports` entry lost its address scope - the devbox is internet-exposed until fixed. Correct
`docker-compose.yml`, then `up`.

**Container is `unhealthy`**
sshd isn't listening. `./bin/devbox logs` - usually a failed `authorized_keys` fetch or wrong permissions
on `/home/dev/.ssh`.

**`Host key verification failed`**
Data dir was recreated, so the host key is new. `ssh-keygen -R '[<workstation>]:2223'`, reconnect, accept
once.

**Permission denied writing to `/home/dev`**
`${DEVBOX_DATA_DIR}` isn't owned by `HOST_UID:HOST_GID`. `sudo chown -R 1000:1000 <dir>`.

**A globally installed package "disappeared"**
The container's writable layer is lost on recreate (`rebuild`, or `down`/`up` onto a new image) -
`npm install -g <pkg>` and `nvm install <version>` write to `/opt`, not the bind mount. Pin it in the
`Dockerfile` instead - see [Toolchain](toolchain.md#adding-a-tool).

**`wt switch` does not change directory**
Run inside a pipeline, its `cd` happens in a subshell. Run it directly.

**`docker: Cannot connect to the Docker daemon`**
Project daemon is down or never provisioned. On the host: `sudo ./bin/rootless-docker --check`, then
`systemctl --user --machine=dev@.host status docker` for the daemon's own log.

**A project's bind mount is empty**
Path identity broke: the project must live under `/home/dev` and `DEVBOX_DATA_DIR` must equal it - the
daemon resolves bind-mount sources on the host. `sudo ./bin/rootless-docker --check` reports mismatches.

**`ssh devbox` closes mid-session with no error**
The container went away under the session, killing sshd with it - nothing sent a disconnect, so the client
just sees the socket close. Three things do that:

1. **A deploy.** `./bin/devbox up` after an `.env`, `docker-compose.yml` or `Dockerfile` change recreates
   the container; `rebuild`/`down` always do. All three count live sessions and prompt first;
   `./bin/devbox sessions` shows who's connected before deploying.
2. **A Docker restart on the host.** A manual `sudo apt upgrade` pulling `docker-ce` or `containerd.io`
   restarts the daemon and every container - `grep -h Upgrade /var/log/apt/history.log |
   grep -E 'docker|containerd'` dates it. `unattended-upgrades` alone won't: `Allowed-Origins` in
   `/etc/apt/apt.conf.d/50unattended-upgrades` lists only Ubuntu and ESM origins; Docker ships from
   `download.docker.com`. Verify before blaming it.
3. **A host reboot or OOM kill.** `docker inspect devbox --format '{{.State.StartedAt}} {{.State.OOMKilled}}
   {{.RestartCount}}'` separates the two.

A session that merely *hangs* is the opposite - the network; `ClientAliveInterval 30` with
`ClientAliveCountMax 6` in `container/sshd_config` ends it after ~3 minutes of an unreachable client.

## ❓ FAQ

**Does the container come back after a host reboot?**
Yes - `restart: unless-stopped`. Tailscale must be up for the published address to bind; boot without it,
run `up` again once it is.

**How do I stop everything without losing state?**
`./bin/devbox down`. State is on the bind mount; only running processes end.

**Can I run two devboxes on one host?**
Only with an override: `container_name: devbox` is hard-coded in `docker-compose.yml`, which `bin/devbox`
targets by name. A second checkout needs a `docker-compose.override.yml` changing `container_name`, plus
distinct `DEVBOX_SSH_PORT`, `DEVBOX_DATA_DIR`, and compose project name.

**How do I see what changed before deploying?**
Rehearse the sync with `-n`:

```bash
rsync -azni --delete --exclude .git --exclude .env --exclude 'data/' --exclude .DS_Store ./ <workstation>:devbox/
```

**Is `bootstrap` safe to run while I am working in a pane?**
Yes - every step is guarded, touching only config files; it doesn't restart sshd or kill sessions.

**Where do container logs live?**
Docker's json-file log for the `devbox` service - `./bin/devbox logs`. sshd logs to stderr (`-e`), so
authentication failures appear there.

**How do I move the devbox to another workstation?**
`bin/push` to the new host, `./bin/devbox env`, restore the data tarball (or start fresh, re-running the
[manual checklist](secrets.md#manual-checklist)), then `./bin/devbox up`. The SSH host key comes from the
data dir, so a restore keeps the laptop's `known_hosts` valid.
