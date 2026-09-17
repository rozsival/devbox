# 🔌 Networking

One published port, bound to one address. Everything else goes through SSH.

## Exposure model

| Layer     | Behavior                                                                                    |
|-----------|-----------------------------------------------------------------------------------------------|
| Docker    | Publishes `2223` on `127.0.0.1` and `BIND_ADDR` (the node's Tailscale IP) - never `0.0.0.0` |
| Tailscale | The only route to `BIND_ADDR`                                                               |
| Result    | Reachable from the Tailnet, invisible from the public internet                              |

```
laptop ──Tailnet──▶ <workstation>  BIND_ADDR:2223 ──DNAT──▶ container :2222 (sshd as dev)
                                   127.0.0.1:2223 ──DNAT──▶ container :2222
```

The compose mapping is the entire network boundary:

```yaml
ports:
  - '${BIND_ADDR}:${DEVBOX_SSH_PORT}:2222'
  - '127.0.0.1:${DEVBOX_SSH_PORT}:2222'
```

## Why UFW cannot help

Docker publishes via `nat/PREROUTING` DNAT: packets reaching the container are *forwarded*, bypassing
`INPUT`, so `ufw deny 2223` can't block a published port
([moby/moby#17496](https://github.com/moby/moby/issues/17496)). The DNAT rule itself enforces the address
scope, so `BIND_ADDR` - not a firewall rule - is the control. That is why it's mandatory: left unset,
`./bin/devbox up` refuses to start rather than fall back to `0.0.0.0`.

Conversely, for project containers: traffic *from* the container *to* a host address is delivered locally,
traversing `INPUT`, which UFW's default deny would drop - why `sudo ./bin/rootless-docker` adds one rule,
`allow in on docker0 to <gateway>` (no source clause: arriving there means a bridge container). The only
host service reachable from the container is the workstation's sshd, on `0.0.0.0`.

Project ports mirror this: the rootless daemon's listeners *are* plain host-namespace sockets, so `INPUT`
applies - a netfilter table, not the publish address, is the boundary. See [Docker](docker.md).

## Verifying exposure

```bash
ssh <workstation> 'ss -ltnp | grep 2223'
```

Expect two lines: `<tailscale-ip>:2223` and `127.0.0.1:2223` - a `0.0.0.0:2223` line means the devbox is
internet-exposed, and `doctor` fails on it explicitly.

## Dev servers and other ports

Nothing else is published from the devbox container; forward per port, per session:

```bash
ssh -N -L 5173:localhost:5173 devbox &          # dev server
ssh -N -L 8080:localhost:8080 -L 5432:localhost:5432 devbox &   # several at once
```

`AllowTcpForwarding yes` in `container/sshd_config` enables this; `PermitTunnel no` limits it to port
forwards. `AllowAgentForwarding yes` is separate, forwarding the laptop's 1Password SSH agent only for an
explicit `ssh -A devbox` connection, never automatically - see
[Git identities](git.md#manual-work-on-the-devbox---the-escape-hatch).

Project containers (see [Docker](docker.md)) publish onto `docker0` - the devbox's bridge gateway - by
default, reachable at `host.docker.internal:<port>`; `devbox-ports` mirrors it to `127.0.0.1:<port>`.
Naming an address in `ports:` overrides that: `0.0.0.0` still can't reach off-host (boundary table drops
it), while `127.0.0.1` binds the *host's* loopback, invisible to the devbox. Tunnel either way:

```bash
ssh -N -L 5432:localhost:5432 devbox &                  # after `devbox-ports` mirrors the port
ssh -N -L 5432:host.docker.internal:5432 devbox &        # directly, without the mirror
```

## ❓ FAQ

**Why 2223 and not 22?**
`2222` is the workstation's sshd; `2223` is the container's - both live on one node without collision, and
inside it sshd always listens on `2222`.

**Can I reach the devbox from another Tailnet device?**
Yes - any device on the Tailnet can reach `BIND_ADDR:2223`, given an authorized key. Copy the `Host devbox`
block and the key.

**What if the Tailscale address changes?**
`up` binds to whatever `BIND_ADDR` says: a stale value fails to bind, or binds a dead address. Re-run
`./bin/devbox env` and `up`; `doctor` flags the mismatch.

**Can I publish a dev server properly instead of tunnelling?**
Possible, not recommended: needs a second address-scoped `ports` entry and a container recreate
(`./bin/devbox up`) - a new boundary to audit each time. SSH forwarding needs no configuration and
inherits existing auth.

**Does the container get its own IP on the Tailnet?**
No - it sits on Docker's default bridge (`docker0`); the Tailnet terminates on the host, DNATing in.
Outbound internet works normally.

**Is IPv6 published?**
No - only the IPv4 Tailscale address from `tailscale ip -4` and `127.0.0.1`.

**Are project containers on the Tailnet?**
No - the rootless daemon publishes on the devbox bridge gateway, not `0.0.0.0`; `devbox-docker-firewall`
blocks `INPUT` outside loopback and that bridge (see *Why UFW cannot help*), overriding even a port spec's
default. So `ports: ['5432:5432']` reaches only the devbox and host - see [Docker](docker.md).
