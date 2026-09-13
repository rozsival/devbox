# 🐳 Docker

Projects that bring their own containers work inside the devbox. The container speaks to a **second, rootless
Docker daemon owned by a dedicated unprivileged host user**, never to the host's root daemon and never to a
nested daemon of its own.

## The shape of it

```
workstation
├── root dockerd (host)             runs the devbox container itself
│   └── devbox container            docker CLI + compose, DOCKER_HOST=/run/devbox/docker.sock
└── rootless dockerd (user dev)     runs the project's containers
    ├── socket   /run/devbox/docker.sock      bind-mounted into the devbox
    ├── home     /home/dev                    the same path on both sides
    └── publish  <docker0 gateway>:<port>      the devbox bridge gateway, alias host.docker.internal
```

One command provisions the whole left-hand side, once:

```bash
sudo ./bin/rootless-docker      # then, as your own user:
./bin/devbox rebuild
```

`sudo ./bin/rootless-docker --check` reports state and changes nothing. Inside the devbox, `docker` and
`docker compose` then work with no flags, no `sudo`, and no socket path to remember.

## Why not the two obvious options

| Option                              | What it actually grants                                                       |
|-------------------------------------|-------------------------------------------------------------------------------|
| Mount `/var/run/docker.sock`        | Host root. The API can start a container that bind-mounts `/` and adds caps   |
| Nested daemon in the devbox         | Needs setuid `newuidmap`, which `cap_drop: ALL` + `no-new-privileges` prevent |
| Privileged sidecar `dind`           | Same as the first row, one indirection later                                  |
| **Rootless sibling, dedicated uid** | Only what the `dev` host user can reach: `/home/dev` and world-readable paths |

The nested case is worth spelling out, because "docker-in-docker" usually means exactly that. Rootless
`dockerd` maps a range of subordinate ids with the setuid helpers `newuidmap`/`newgidmap`. Those need
`CAP_SETUID` and the ability to gain privileges - both deliberately removed from this container (rule 4 in
`AGENTS.md`). Restoring them to get Docker would cost more than Docker is worth. Sharing the *host's* rootless
daemon keeps the container's own hardening untouched: nothing in `docker-compose.yml` had to be relaxed.

## What the prep script does

- **`uidmap`, `slirp4netns`** - `newuidmap` maps subordinate ids. Without it the daemon is limited to a
  single uid and images that drop privileges (postgres, redis, node) cannot start.
- **host user `dev:devbox`, uid 1001** - the daemon's authority ceiling. A dedicated account keeps your own
  home directory, SSH keys and sudo rights out of reach.
- **`DEVBOX_DATA_DIR` → `/home/dev`** - path identity, see below. The move refuses while the container is
  running; it is a `mv` plus a `chown`, so nothing is recreated or lost.
- **`chown -R dev:devbox /home/dev`** - the daemon and the container are the same uid, so files written
  either way are owned by `dev`.
- **one `ufw` rule** - `allow in on docker0 to <gateway>`. Traffic from the container
  to a host address is *delivered locally*, so unlike a published port it does traverse `INPUT`, where UFW's
  default deny would drop it. Scoped to that one bridge and that one destination address, which is all the
  daemon publishes on.
- **`/etc/tmpfiles.d/devbox-docker.conf`** - `/run/devbox` must exist *before* the daemon starts, because
  rootlesskit copy-ups `/run` and only symlinks entries that already exist. tmpfiles recreates it on boot.
- **`loginctl enable-linger dev`** - a never-logged-in account gets no systemd user manager, so the daemon
  could neither start at boot nor survive.
- **unit written to `/etc/systemd/user`, owned by root** - `dockerd-rootless-setuptool.sh install` would put
  it in `~/.config/systemd/user`, inside the bind mount, where anything in the container could rewrite the
  daemon's own command line. The script uses the tool only for its prerequisite `check` and owns the unit
  itself.
- **`/etc/nftables.d/devbox-docker.nft` plus `devbox-docker-firewall.service`** - the publish boundary, and
  the one non-obvious piece. See below.

`./bin/devbox doctor` checks that `host.docker.internal` resolves inside the container and that the boundary
service is active, so a project port silently exposed on every interface is reported rather than discovered.

## Where a published port is bound

Two mechanisms, because the first one is a default and not a boundary.

**1. The daemon's publish address.** `--ip <gateway>` sets the host binding for the *default* bridge only, so
a compose project - which always creates its own user-defined bridge - ignores it and publishes on
`0.0.0.0`. Measured on this host: `-p 8098:80` on `bridge` bound `172.17.0.1:8098`, while the identical spec
on a compose network bound `0.0.0.0:8099`, reachable from the Tailnet *and* the LAN. The unit therefore also
passes

```
--default-network-opt bridge=com.docker.network.bridge.host_binding_ipv4=<gateway>
```

which applies the same option to every bridge network the daemon creates. `docker ps` then shows the gateway
address, which is the honest thing for it to show.

**2. The boundary.** That default still loses to an explicit `ports: ['0.0.0.0:8099:80']`, and a network
created before the flag keeps its stored option. Leaving the security boundary to per-project port specs is
not a boundary, so it is enforced in netfilter as well:

```
table inet devbox {
  chain input {
    type filter hook input priority filter - 10; policy accept;
    ct state established,related accept
    iifname { "lo", "docker0" } accept
    socket cgroupv2 level 2 "user.slice/user-1001.slice" drop
  }
}
```

The conntrack rule is not decoration. `dockerd-rootless.sh` passes `--detach-netns`, so the daemon itself
runs in the *host* network namespace and only its containers get the detached one - which means every reply
to an image pull or a DNS lookup also arrives on a socket in that slice. Without `ct state established`
the daemon has no outbound connectivity at all. An inbound connection to a published port is `ct state new`,
so it still meets the drop.

Matching is by the **listening socket's cgroup**, so it covers every port that daemon will ever publish, at
any address, without knowing the port numbers. Input is accepted on loopback and on the devbox bridge and
dropped everywhere else - so `ports: ['5432:5432']` works from the devbox and from the host and is invisible
from the Tailnet and the LAN, whatever the compose file asks for. Unlike the DNAT case in
[Networking](networking.md), these listeners are ordinary host sockets, so `INPUT` genuinely applies.

It lives in its own `inet` table at a lower priority than ufw's chains, so neither touches the other's rules.
ufw still needs its one allow rule: a table accepting a packet does not exempt it from later tables.

The devbox deliberately sits on the *default* bridge (`network_mode: bridge`). `docker0` exists whenever the
host docker daemon does, whereas a compose-managed bridge is removed by `./bin/devbox down` and recreated
with a new address - and both the publish address and the one interface the boundary table admits are keyed
to it.

## Path identity

The daemon resolves bind-mount sources **on the host**. A compose file saying

```yaml
volumes:
  - ./data:/var/lib/postgresql/data
```

sends the container's path (`/home/dev/projects/app/data`) to the daemon, which opens it as a host path. That
only works because the bind mount sits at `/home/dev` on the host too - hence `DEVBOX_DATA_DIR=/home/dev` and
the uid switch to the `dev` account. Keep projects under `/home/dev`; a bind mount from `/tmp` or `/opt`
resolves against the host's version of that path.

Ownership follows the same alignment: the rootless daemon maps container `root` to uid 1001, which is `dev`
inside the container, so files a container writes into a bind mount are yours. A container that drops to its
own unprivileged user (postgres runs as uid 999) writes files owned by a subordinate id instead, which `dev`
cannot read. That is normal rootless behaviour - keep database data directories in **named volumes**, which
live inside the daemon's own storage and never hit this problem.

## Reaching a service

Three ways, in order of preference:

1. **From another container in the same stack** - unchanged. Compose networks and service DNS work exactly as
   they do on a laptop; `postgres:5432` resolves.
2. **From a devbox shell, via `host.docker.internal`** - every port published *on the gateway*, meaning a
   `ports:` entry with no explicit host address, is reachable there: the name resolves to the devbox bridge
   gateway, the one interface the boundary table admits. An entry that names `127.0.0.1` is not - see *A
   compose file that binds 127.0.0.1* below.
3. **From a devbox shell, via `localhost`** - run `devbox-ports`, which forwards `127.0.0.1:<port>` to
   `host.docker.internal:<port>` for every port the daemon publishes, with one `socat` per port:

```bash
docker compose up -d
devbox-ports            # sync (default); re-run only when new ports appear
devbox-ports status
devbox-ports stop
```

That last one exists so a project whose `.env` says `postgres://localhost:5432` needs no devbox-specific
edit. Each forward is a detached `socat`, so it outlives the shell that created it, every `docker compose
restart` and every container rebuild - the port number is what it binds to, not the container. It dies only
with the devbox container itself, and `container/entrypoint.sh` re-syncs on start, so a `./bin/devbox
rebuild` restores the forwards before sshd accepts a connection. In practice `devbox-ports` is a command you
run once after adding a service, not once per session.

From the laptop, tunnel as usual - `ssh -N -L 5432:localhost:5432 devbox &` reaches a mirrored port,
and `ssh -N -L 5432:host.docker.internal:5432 devbox &` reaches one without the mirror.

## A compose file that binds 127.0.0.1

A project that publishes with an explicit loopback prefix - `'127.0.0.1:5432:5432'`, common and correct on a
laptop - is **unreachable from the devbox**. The daemon is a sibling, so that address is the *host's*
loopback, and the devbox has no route to it; neither `host.docker.internal` nor `devbox-ports` can see the
port, because nothing was published on the bridge gateway.

Make the address a variable in the project's compose file, defaulting to today's behaviour:

```yaml
ports:
  - '${DOCKER_BIND_IP:-127.0.0.1}:${POSTGRES_PORT:-5432}:5432'
```

Then set `DOCKER_BIND_IP=172.17.0.1` in that project's `.env` inside the devbox - the gateway address, which
`./bin/devbox doctor` prints and `host.docker.internal` resolves to. Laptops leave it unset and are
unaffected. This is not a weaker bind: the boundary table drops connections to a published port from every
interface except `lo` and `docker0`, including ports published to `0.0.0.0` (see *Where a published port is
bound*).

`work/agents` needs exactly this, plus one `devbox-ports` run:

```bash
cd ~/projects/work-agents
echo 'DOCKER_BIND_IP=172.17.0.1' >>.env
pnpm run docker:start
devbox-ports
pnpm dev                # apps on localhost:3000/4000-4002, natively in the box
```

The apps' own `localhost` URLs (`NEXT_PUBLIC_GATEWAY_URL`, `CORS_ORIGINS`, `AGENT_UPSTREAMS`, `AUTH_URL`)
need no change: those processes run in the devbox, so its loopback is theirs. Renaming the two
container-facing values to `host.docker.internal` instead of mirroring works for Postgres but breaks
Langfuse: compose feeds `LANGFUSE_BASE_URL` to `NEXTAUTH_URL`, which must match the address the operator's
browser uses over the tunnel. Leave it `localhost:3001` and mirror. A wrong value there fails silently -
the OTel span processor drops spans rather than raising.

`.env.local` holds the vault-injected credentials and cannot be generated in the devbox, which ships no `op`
by design (see `docs/secrets.md`). Generate it on the laptop with `pnpm run env:inject` and copy it in once;
`.worktreeinclude` then carries it into every `wt` worktree.

## Building images

`docker build` and `docker compose build` work; `buildx` is installed as a CLI plugin. Builds run on the
rootless daemon with the kernel's unprivileged overlayfs, so there is no `--privileged` build step and no
`fuse-overlayfs` dependency. The image cache lives in `/home/dev/.local/share/docker`, on the bind mount,
which means it survives every `./bin/devbox rebuild` and counts against the host disk like any project file.

## Versions

| Piece          | Pin                                   | Where                      |
|----------------|---------------------------------------|----------------------------|
| Docker CLI     | `DOCKER_CLI_VERSION` (static tarball) | `Dockerfile`               |
| Compose plugin | `DOCKER_COMPOSE_VERSION` (+ checksum) | `Dockerfile`               |
| Buildx plugin  | `DOCKER_BUILDX_VERSION` (+ checksum)  | `Dockerfile`               |
| Daemon         | The host's `docker-ce`                | `apt-get` on workstation |

Keep `DOCKER_CLI_VERSION` equal to the host daemon's version (`docker version` on the host). A CLI older than
the daemon is fine; compose refuses to talk to an API newer than the server.

## ❓ FAQ

**Is this "docker-in-docker"?**
No, and deliberately so. It is docker *beside* docker: a sibling daemon reached over a socket. True nesting
needs the container to create user namespaces with setuid helpers, which this container's `cap_drop: ALL` and
`no-new-privileges` rule out.

**Does the container now have host root?**
No. The socket belongs to `dev`, an account with no password, no keys, no sudo and no files outside
`/home/dev`. A container started through it can bind-mount host paths, but only reads what is world-readable
and only writes what `dev` owns. The host's own root daemon is not exposed.

**Why a separate user instead of my own account?**
Because the daemon's user *is* the authority ceiling. Running it as the deploying user would let anything with
the socket mount `/home/<you>/.ssh` as that uid and read the host's private keys.

**Can an agent in the devbox stop the devbox container?**
No - the devbox container runs on the host's root daemon, which the container cannot reach. It can stop and
start project containers, which is the point.

**Do project ports end up on the Tailnet?**
No, and by two independent mechanisms: the daemon publishes on the bridge gateway by default (`--default-network-opt`,
so `docker ps` shows `172.17.0.1:5432`), and `devbox-docker-firewall` drops input
to that daemon's sockets outside loopback and the devbox bridge even when a port spec overrides the default.
`./bin/devbox doctor` fails if the boundary service is not active or the publish address has drifted.

**`docker pull` hangs, then fails with an i/o timeout.**
Almost certainly the boundary table dropping the daemon's *reply* traffic - check that
`/etc/nftables.d/devbox-docker.nft` still carries its `ct state established,related accept` rule, and that
the running table matches the file (`sudo nft list table inet devbox`). The error names whichever address
Go dialled last, which makes it look like an IPv6 problem; it is not.

**`docker` says "Cannot connect to the Docker daemon".**
The daemon is down or unprovisioned. On the host: `sudo ./bin/rootless-docker --check`, then
`systemctl --user --machine=dev@.host status docker` for the daemon's own log.

**A service is running but nothing in the devbox can reach its port.**
Check what the daemon bound: `docker port <container>`. An address of `127.0.0.1:<port>` is the *host's*
loopback and unreachable from here - the project's compose file publishes with an explicit loopback prefix.
Parameterise it and set `DOCKER_BIND_IP` (see *A compose file that binds 127.0.0.1*). An address of
`172.17.0.1:<port>` is correct; if `localhost` still fails there, the mirror is missing - run `devbox-ports`.

**A bind mount is empty inside a project container.**
Path identity was broken - either the project lives outside `/home/dev`, or `DEVBOX_DATA_DIR` is not
`/home/dev`. `sudo ./bin/rootless-docker --check` reports the second case.

**Does a redeploy wipe images and volumes?**
No. They live under `/home/dev/.local/share/docker` on the bind mount, which `bin/push` never touches and
`rebuild` never deletes. Removing them is `docker system prune`, by hand.

**Can I use the host's root daemon for something else?**
It still runs the devbox container itself, and it is yours over `ssh workstation`. Nothing inside the devbox
can reach it.
