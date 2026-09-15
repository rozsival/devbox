# 🛡 Security model

What this container is for: running agents with bypassed permissions where the worst case is a lost project
tree, not a lost host. The threat model is an agent (or dependency) that executes arbitrary code inside the
devbox.

## Boundaries

| Boundary                   | Enforced by                                                                  |
|----------------------------|------------------------------------------------------------------------------|
| No host filesystem access  | Only `${DEVBOX_DATA_DIR}` is mounted, at `/home/dev` (but see limit 5)       |
| No host root Docker daemon | `/var/run/docker.sock` is not mounted; the reachable daemon is rootless      |
| No privilege escalation    | `user: ${HOST_UID}:${HOST_GID}`, `cap_drop: [ALL]`, `no-new-privileges:true` |
| No public network exposure | `${BIND_ADDR}:${DEVBOX_SSH_PORT}:2222` - Tailnet address only                |
| No password auth           | `PubkeyAuthentication yes`, `PasswordAuthentication no`, `UsePAM no`         |
| No private keys at rest    | The devbox holds no SSH private key; `AllowAgentForwarding yes` only lets `ssh -A devbox` borrow the laptop's forwarded 1Password agent for one connection |

## No root process at runtime

The image ends as `USER dev`, and `sshd` runs unprivileged: it only ever authenticates the user it already
runs as, so with `UsePAM no` and pubkey-only auth it needs neither `/etc/shadow` nor setuid.

This is the isolation that matters here: user namespaces are not configured on the workstation, so container
root would be **host UID 0** in a runtime escape. Running as the dedicated `dev` account (UID 1001) means an
escape lands as a host user with no password, no sudo and no files outside `/home/dev`.

Verify:

```bash
ssh workstation 'cd ~/devbox && docker compose exec -T devbox ps -o user= -p 1'   # dev
ssh workstation 'cd ~/devbox && ./bin/devbox logs | grep "Server listening"'      # no "must be run as root"
```

## What the container holds

Authority is enumerated, not ambient. Each credential is scoped, separately revocable, and separately
attributable:

| Purpose                             | Credential                                                | Reach                                                      |
|---------------------------------------|--------------------------------------------------------------|----------------------------------------------------------------|
| Agent git (clone, pull, push, commit) | per-repository GitHub App installation token, else a fine-grained PAT | App: one repo, 1h. PAT: its named repos, `contents: write` |
| Manual git, incl. signing (you)       | the laptop's 1Password agent, forwarded per connection (`ssh -A devbox`) | same as your laptop; the container stores no private key |
| Dashboards, CI, issues                | one fine-grained PAT per GitHub account                     | named repos, scoped per token                                  |
| LLM inference                         | per-project GCP service-account key                          | one dev project, predict-only                                  |
| Project secrets                       | that project's `.env`                                        | one project                                                     |

Notably absent: any 1Password account (`op` is not installed), any private key for GitHub, and any Google
user credential. See [Secrets](secrets.md).

## What an agent inside the devbox can reach

**Can**: the whole `/home/dev` tree - both public keys (useless without the laptop's forwarded agent), both
`gh` tokens, the App private key, every project's `.env` and every GCP key - plus the internet, the Tailnet
from the container's network namespace, and the rootless project Docker daemon ([Docker](docker.md)).

**Cannot**: the host filesystem outside the data dir and world-readable paths, the host's **root** Docker
daemon, the devbox container's own lifecycle, root inside the container, any port that is not published, and
any 1Password vault.

The consequence to plan for: an agent with shell access can push through the same App token or PAT that
`git` and `gh` already resolve, and read the App private key, both PATs and every project's `.env` and GCP
key directly. Your own GitHub push authority is out of its reach - there is no private key to steal - unless
it happens to be running inside a `ssh -A devbox` connection you forwarded yourself (accepted limit 2). Treat
a compromise as "revoke two PATs, one App key and one service-account key", not "rebuild a laptop".

## Accepted limits

These are known and deliberate, not gaps to be closed later:

1. **No egress filtering.** Outbound network is unrestricted, because the box needs the internet to work. An
   agent that reads a poisoned issue or README can send whatever it holds anywhere. IAM and token scoping
   limit what it can *reach*; nothing limits what it can *send*. This is why the container is a containment
   boundary for authority and **not** a confidentiality boundary - assume anything inside can leave.
2. **A forwarded agent is reachable by anything in that one connection.** `ssh -A devbox` exposes the
   1Password agent socket for that connection's lifetime; a process started by hand inside it - not through
   `git`, which the `omp` launcher fences to HTTPS - could call `ssh` directly and request a signature.
   1Password's own per-use approval on the laptop is the backstop: nothing signs without it. Plain `herdr`
   panes and `./bin/devbox shell` never forward the agent at all, and neither does a bare `ssh devbox`.
3. **No isolation between projects.** One container, one `dev` user, one bind mount: an agent in project A can
   read project B's `.env` and GCP key. Cloning something less trusted is the point at which per-project
   containers or separate users stop being over-engineering.
4. **Secrets are plaintext at rest.** `.env` files, the `gh` tokens and key files are unencrypted on the
   workstation's disk, readable by the host user. Workstation disk encryption and host account hygiene are
   part of this security model, not separate from it.
5. **The project Docker daemon widens reach to the `dev` account.** Anything in the container can start a
   container through that socket, including one that bind-mounts a host path. It runs as the unprivileged
   `dev` user, so it reads only world-readable host files and writes only what `dev` owns - never host root,
   never the root daemon that runs the devbox itself, and never your own home directory, which stays `750`
   and is not traversable by `dev`. This is the price of `docker compose up` inside the box, and the reason
   the daemon has its own dedicated account.
6. **A project port is one firewall rule away from the Tailnet.** Rootless Docker binds every published port
   on `0.0.0.0` and offers no way to change that, so `devbox-docker-firewall` - an nftables table dropping
   input to that daemon's sockets outside loopback and the devbox bridge - is what confines them.
   `./bin/devbox doctor` fails if it is not active; if it is ever removed, every project port becomes
   reachable from the Tailnet and the LAN. See [Docker](docker.md).

An agent's own command allowlist - forbidding `op`, `gcloud` and similar - is a useful guardrail but not a
control: a subverted agent can call the same APIs through an SDK without either binary. The boundary is what
each credential is permitted to do.

## Deliberate boundaries

- **No host *root* Docker socket.** Mounting `/var/run/docker.sock` would hand the sandbox host root and void
  the point of the container. Projects that need containers get a sibling rootless daemon owned by a
  dedicated unprivileged host user instead, reached through `DOCKER_HOST` - see [Docker](docker.md) for why
  a nested daemon is impossible here without giving the container back `CAP_SETUID`.
- **No root process at runtime.** See above.
- **No 1Password in the container.** A live `op` session is readable by any agent in that shell, turning a
  one-project leak into every vault the account can read - while the project's secrets sit in a plaintext
  `.env` regardless, because the app must read them. Secrets are rendered on the laptop and copied in.
- **No Google user credential.** `gcloud auth application-default login` writes a non-expiring refresh token
  for your whole Google identity. Projects get a service-account key scoped to their own GCP project instead.

## Trust assumptions

1. **The Tailnet is the perimeter.** Any Tailnet device with an authorized key can reach the devbox. There is
   no second factor on the SSH port.
2. **`authorized_keys` trusts a GitHub account.** Every key on the `DEVBOX_GITHUB_USER` account can log in -
   the same trust model the workstation's host sshd uses. To narrow it, clear `DEVBOX_GITHUB_USER` and list
   keys explicitly in `DEVBOX_EXTRA_AUTHORIZED_KEYS`.
3. **The `dev` host user owns the data, and root can read everything.** The bind mount belongs to the
   dedicated `dev` account, which also owns the project Docker daemon; your own host account reaches it only
   through `sudo`. The container protects the host from the agent, not the files from the host's owner.

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
That is already the default: agents commit through the work-app GitHub App, which is scoped to specific
repositories and permissions, and `gh` uses a fine-grained PAT rather than an account-wide OAuth token. The
forwarded 1Password agent remains broad for manual work because it is yours - see accepted limit 2.

**Would per-repo deploy keys be tighter than the fine-grained PAT?**
Yes - but the primary path is already that tight: the work-app GitHub App mints a token scoped to
exactly one repository for one hour. Deploy keys only become relevant for the fallback case, repos without
the App installed, where the fine-grained PAT is the same breadth trade as any multi-repo PAT: it can push
everywhere it is granted `contents: write`, and it is readable by any agent in the container, not just by
you at a prompt. Install the App on the repos that matter instead of adding a deploy key.

**How do I revoke access from a lost laptop?**
Remove the key from GitHub (or from `DEVBOX_EXTRA_AUTHORIZED_KEYS`) and restart the container -
`authorized_keys` is rebuilt on every start. Also remove it from the workstation's own
`~/.ssh/authorized_keys`.
