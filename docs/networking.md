# 🔌 Networking

One published port, bound to one address. Everything else goes through SSH.

## Exposure model

| Layer     | Behavior                                                                                    |
|-----------|---------------------------------------------------------------------------------------------|
| Docker    | Publishes `2223` on `127.0.0.1` and `BIND_ADDR` (the node's Tailscale IP) - never `0.0.0.0` |
| Tailscale | The only route to `BIND_ADDR`                                                               |
| Result    | Reachable from the Tailnet, invisible from the public internet                              |

```
laptop ──Tailnet──▶ workstation  BIND_ADDR:2223 ──DNAT──▶ container :2222 (sshd as dev)
                                   127.0.0.1:2223 ──DNAT──▶ container :2222
```

The compose mapping is the entire network boundary:

```yaml
ports:
  - '${BIND_ADDR}:${DEVBOX_SSH_PORT}:2222'
  - '127.0.0.1:${DEVBOX_SSH_PORT}:2222'
```

## Why UFW cannot help

Docker publishes ports with `nat/PREROUTING` DNAT, so packets reaching the container are *forwarded*, not
delivered locally - they never traverse the `INPUT` chain UFW manages, and `ufw deny 2223` cannot block a
published port ([moby/moby#17496](https://github.com/moby/moby/issues/17496)). An address-scoped published
port is enforced by the DNAT rule itself, which is why `BIND_ADDR` - not a firewall rule - is the control.

`BIND_ADDR` is mandatory: unset, `./bin/devbox up` refuses to start rather than silently falling back to
`0.0.0.0`.

## Verifying exposure

```bash
ssh workstation 'ss -ltnp | grep 2223'
```

Expect exactly two lines - `<tailscale-ip>:2223` and `127.0.0.1:2223`. A `0.0.0.0:2223` line means the devbox
is internet-exposed; `./bin/devbox doctor` fails on that condition explicitly.

## Dev servers and other ports

Nothing else is published. Forward per port, per session:

```bash
ssh -N -L 5173:localhost:5173 devbox &          # dev server
ssh -N -L 8080:localhost:8080 -L 5432:localhost:5432 devbox &   # several at once
```

`AllowTcpForwarding yes` in `container/sshd_config` enables this; `PermitTunnel no` and
`AllowAgentForwarding no` keep the rest closed. Remote (`-R`) forwards work the same way if the devbox needs
to reach something on the laptop.

## ❓ FAQ

**Why 2223 and not 22?**
`2222` on the workstation is the host's own sshd. `2223` is the container's, so both live on one node without
collision. Inside the container sshd always listens on `2222`.

**Can I reach the devbox from another Tailnet device?**
Yes - any device on the Tailnet can reach `BIND_ADDR:2223`, given an authorized key. Copy the `Host devbox`
block and the key.

**What if the Tailscale address changes?**
`up` binds to whatever `BIND_ADDR` says, so a stale value fails to bind or binds to a dead address. Re-run
`./bin/devbox env` and `./bin/devbox up`; `doctor` flags the mismatch.

**Can I publish a dev server properly instead of tunnelling?**
Possible, not recommended - it would need a second address-scoped `ports` entry and a container recreate
(`./bin/devbox up`), and every such
entry is a new boundary to audit. SSH forwarding needs no configuration and inherits the existing auth.

**Does the container get its own IP on the Tailnet?**
No. It uses Docker's default bridge network; the Tailnet terminates on the host, which DNATs into the
container. Outbound internet access from the container works normally.

**Is IPv6 published?**
No - only the IPv4 Tailscale address from `tailscale ip -4` and `127.0.0.1`.
