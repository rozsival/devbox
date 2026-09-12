# 🛡 Security model

What this container is for: running agents with bypassed permissions where the worst case is a lost project
tree, not a lost host. The threat model is an agent (or dependency) that executes arbitrary code inside the
devbox.

## Boundaries

| Boundary                   | Enforced by                                                                  |
|----------------------------|------------------------------------------------------------------------------|
| No host filesystem access  | Only `${DEVBOX_DATA_DIR}` is mounted, at `/home/dev`                         |
| No host Docker daemon      | `/var/run/docker.sock` is not mounted; no `privileged`                       |
| No privilege escalation    | `user: ${HOST_UID}:${HOST_GID}`, `cap_drop: [ALL]`, `no-new-privileges:true` |
| No public network exposure | `${BIND_ADDR}:${DEVBOX_SSH_PORT}:2222` - Tailnet address only                |
| No password auth           | `PubkeyAuthentication yes`, `PasswordAuthentication no`, `UsePAM no`         |
| No agent forwarding        | `AllowAgentForwarding no` - signing keys live inside the devbox              |

## No root process at runtime

The image ends as `USER dev`, and `sshd` runs unprivileged: it only ever authenticates the user it already
runs as, so with `UsePAM no` and pubkey-only auth it needs neither `/etc/shadow` nor setuid.

This is the isolation that matters here: user namespaces are not configured on the workstation, so container
root would be **host UID 0** in a runtime escape. Running as UID 1000 means an escape lands as the ordinary
host user instead.

Verify:

```bash
ssh workstation 'cd ~/devbox && docker compose exec -T devbox ps -o user= -p 1'   # dev
ssh workstation 'cd ~/devbox && ./bin/devbox logs | grep "Server listening"'      # no "must be run as root"
```

## What an agent inside the devbox can reach

**Can**: the whole `/home/dev` tree (both SSH keys, `gh` tokens, every project), the internet, the Tailnet
from the container's network namespace, and anything a running `op` session unlocks.

**Cannot**: the host filesystem outside the data dir, the host Docker daemon, other containers' filesystems,
root inside the container, and any port that is not published.

The consequence to plan for: an agent with shell access has the same GitHub reach as you do through those
keys. Keep the keys per-host and revocable (they are - both are generated in the devbox and registered
individually), and treat a compromise as "revoke two keys and one `gh` token", not "rebuild a laptop".

## Deliberate boundaries

- **No host Docker socket.** Mounting `/var/run/docker.sock` would hand the sandbox host root and void the
  point of the container. Project-level containers are therefore unavailable inside the devbox; if they are
  ever needed, the answer is a `docker:dind-rootless` sidecar plus `DOCKER_HOST`, not a socket mount.
- **No root process at runtime.** See above.
- **1Password stays interactive.** `op` sessions expire, so anything an agent needs unattended must be a
  long-lived credential written once into the devbox (the `gh` token, `~/.terraformrc`) rather than fetched per
  run through `op`. The escape hatch is an `OP_SERVICE_ACCOUNT_TOKEN` plus a dedicated shared vault (service
  accounts cannot read Private vaults).

## Trust assumptions

1. **The Tailnet is the perimeter.** Any Tailnet device with an authorized key can reach the devbox. There is
   no second factor on the SSH port.
2. **`authorized_keys` trusts a GitHub account.** Every key on the `DEVBOX_GITHUB_USER` account can log in -
   the same trust model the workstation's host sshd uses. To narrow it, clear `DEVBOX_GITHUB_USER` and list
   keys explicitly in `DEVBOX_EXTRA_AUTHORIZED_KEYS`.
3. **The host user can read everything.** The bind mount is owned by `HOST_UID`. The container protects the
   host from the agent, not the files from the host owner.
4. **Passphrase-less keys are intentional.** Unattended agents must push without a prompt; the mitigation is
   scope and revocability, not a passphrase.

## ❓ FAQ

**Why not gVisor, Firecracker, or a VM?**
Overkill for the actual risk (a hostile dependency, not a targeted attacker) and it breaks the herdr
attach model. The cheap, high-value controls - non-root, no socket, dropped capabilities, address-scoped port
- are all in place.

**Should I enable user namespace remapping on the host?**
It would let the container run as root safely, but nothing here needs container root, and `userns-remap`
breaks the UID-matched bind mount that makes the data dir inspectable from the host. Not worth it.

**Is `cap_drop: ALL` compatible with sshd?**
Yes, because sshd never changes user. Dropping `CHOWN`/`SETUID`/`SETGID` is exactly what a root-launched sshd
would have needed.

**What if unprivileged sshd stops working after an OpenSSH update?**
Fix the unprivileged path - it is the whole design. `cap_add` and a root-launched sshd are off the table per
[AGENTS.md](../AGENTS.md) rule 4, and `./bin/devbox shell` still gets you in while sshd is broken, so there is
no lock-out risk to trade the boundary away for.

**Can I give an agent a narrower key?**
Yes - use a GitHub App installation token or a fine-grained PAT for that agent's repos instead of the shared
`gh` token. Nothing in the design assumes the account-wide token.

**How do I revoke access from a lost laptop?**
Remove the key from GitHub (or from `DEVBOX_EXTRA_AUTHORIZED_KEYS`) and restart the container -
`authorized_keys` is rebuilt on every start. Also remove it from the workstation's own
`~/.ssh/authorized_keys`.
