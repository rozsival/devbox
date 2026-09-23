# 🛡 Security model

What this container is for: running agents with bypassed permissions where the worst case is a lost
project tree, not a lost host. The threat model: an agent (or dependency) executing arbitrary code inside
the devbox.

## Boundaries

| Boundary                   | Enforced by                                                                                                                                            |
|----------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------|
| No host filesystem access  | Only `${DEVBOX_DATA_DIR}` mounted, at `/home/dev` (see limit 5)                                                                                        |
| No host root Docker daemon | `/var/run/docker.sock` not mounted; reachable daemon is rootless                                                                                       |
| No privilege escalation    | `user: ${HOST_UID}:${HOST_GID}`, `cap_drop: [ALL]`, `no-new-privileges:true`                                                                           |
| No public network exposure | `${BIND_ADDR}:${DEVBOX_SSH_PORT}:2222` - Tailnet address only                                                                                          |
| No password auth           | `PubkeyAuthentication yes`, `PasswordAuthentication no`, `UsePAM no`                                                                                   |
| No private keys at rest    | Devbox holds no SSH private key; `AllowAgentForwarding yes` only lets `ssh -A devbox` borrow the laptop's forwarded 1Password agent for one connection |

## No root process at runtime

The image ends as `USER dev`; `sshd` runs unprivileged, only ever authenticating the user it already is -
with `UsePAM no` and pubkey-only auth, needing neither `/etc/shadow` nor setuid.

This is the isolation that matters: user namespaces aren't configured on the workstation, so container
root would be **host UID 0** in a runtime escape. Running as the dedicated `dev` account (UID 1001) means
an escape lands as a host user with no password, no sudo, no files outside `/home/dev`.

Verify:

```bash
ssh <workstation> 'cd ~/devbox && docker compose exec -T devbox ps -o user= -p 1'   # dev
ssh <workstation> 'cd ~/devbox && ./bin/devbox logs | grep "Server listening"'      # no "must be run as root"
```

## What the container holds

Authority is enumerated, not ambient: each credential is scoped, separately revocable, separately
attributable:

| Purpose                               | Credential                                                               | Reach                                                      |
|---------------------------------------|--------------------------------------------------------------------------|------------------------------------------------------------|
| Agent git (clone, pull, push, commit) | per-repository GitHub App installation token, else a fine-grained PAT    | App: one repo, 1h. PAT: its named repos, `contents: write` |
| Manual git, incl. signing (you)       | the laptop's 1Password agent, forwarded per connection (`ssh -A devbox`) | same as your laptop; the container stores no private key   |
| Dashboards, CI, issues                | one fine-grained PAT per GitHub account                                  | named repos, scoped per token                              |
| LLM inference                         | per-project GCP service-account key                                      | one dev project, predict-only                              |
| Project secrets                       | that project's `.env`                                                    | one project                                                |

Notably absent: any 1Password account (`op` isn't installed), any GitHub private key, any Google user
credential. See [Secrets](secrets.md).

## What an agent inside the devbox can reach

**Can**: the whole `/home/dev` tree - every identity's public keys (useless without the laptop's forwarded
agent), every identity's `gh` token, each configured App's private key, every project's `.env` and GCP
key - plus the internet, the container's Tailnet namespace, and the rootless project Docker daemon
([Docker](docker.md)).

**Cannot**: the host filesystem outside the data dir and world-readable paths, the host's **root** Docker
daemon, the devbox container's own lifecycle, root inside the container, any unpublished port, and any
1Password vault.

The consequence: an agent with shell access can push through the same App token or PAT `git`/`gh` already
resolve, and read each configured App's private key, every identity's PAT, and every project's `.env` and GCP key
directly. Your
own GitHub push authority stays out of reach - no private key to steal - unless it's inside a `ssh -A
devbox` connection you forwarded yourself (accepted limit 2). Treat a compromise as "revoke every
identity's PAT and App key, plus the service-account key," not "rebuild a laptop."

## Accepted limits

These are known and deliberate, not gaps to be closed later:

1. **No egress filtering.** Outbound network is unrestricted - the box needs internet access. An agent
   reading a poisoned issue or README can send whatever it holds anywhere: IAM and token scoping limit
   what it can *reach*, not *send*. The container is a containment boundary for authority, **not**
   confidentiality - assume anything inside can leave.
2. **A forwarded agent is reachable by anything in that one connection.** `ssh -A devbox` exposes the
   1Password agent socket for the connection's lifetime; a hand-started process inside it - not through
   `git`, fenced to HTTPS by the `omp` launcher - could call `ssh` directly, requesting a signature.
   1Password's per-use laptop approval is the backstop: nothing signs without it. Plain `herdr` panes,
   `./bin/devbox shell`, and a bare `ssh devbox` never forward it.
3. **No isolation between projects.** One container, one `dev` user, one bind mount: an agent in project
   A can read project B's `.env` and GCP key. Cloning something less trusted is where per-project
   containers or separate users stop being over-engineering.
4. **Secrets are plaintext at rest.** `.env` files, `gh` tokens and key files are unencrypted on the
   workstation's disk, readable by the host user. Workstation disk encryption and host account hygiene
   are part of this security model, not separate.
5. **The project Docker daemon widens reach to the `dev` account.** Anything in the container can start a
   container through that socket, including one bind-mounting a host path - but only as unprivileged
   `dev`: world-readable host files to read, only `dev`-owned files to write, never host root, the root
   daemon, or your home directory (`750`, untraversable by `dev`). The price of `docker compose up`
   inside the box - why the daemon gets its own dedicated account.
6. **A project port is one firewall rule away from the Tailnet.** Rootless Docker binds every published
   port on `0.0.0.0`, with no way to change that - `devbox-docker-firewall`, an nftables table dropping
   input to that daemon's sockets outside loopback and the devbox bridge, confines them.
   `./bin/devbox doctor` fails if inactive; removed, every project port reaches the Tailnet and LAN. See
   [Docker](docker.md).

An agent's own command allowlist - forbidding `op`, `gcloud` and similar - is a useful guardrail, not a
control: a subverted agent can call the same APIs through an SDK without either binary. The boundary is
what each credential can do.

## Deliberate boundaries

- **No host *root* Docker socket.** Mounting `/var/run/docker.sock` would hand the sandbox host root,
  voiding the container's point. Projects needing containers get a sibling rootless daemon owned by a
  dedicated unprivileged host user, reached through `DOCKER_HOST` - see [Docker](docker.md) for why
  nesting one needs the container's `CAP_SETUID` back.
- **No root process at runtime.** See above.
- **No 1Password in the container.** A live `op` session is readable by any agent in that shell, turning
  a one-project leak into every vault the account can read - while project secrets sit in a plaintext
  `.env` regardless, since the app must read them. Secrets render on the laptop, then copy in.
- **No Google user credential.** `gcloud auth application-default login` writes a non-expiring refresh
  token for your whole Google identity; projects get a service-account key scoped to their own GCP
  project instead.

## Trust assumptions

1. **The Tailnet is the perimeter.** Any Tailnet device with an authorized key can reach the devbox - no
   second factor on the SSH port.
2. **`authorized_keys` trusts a GitHub account.** Every key on the `DEVBOX_GITHUB_USER` account can log
   in - the same trust model the workstation's host sshd uses. Narrow it: clear `DEVBOX_GITHUB_USER`,
   list keys explicitly in `DEVBOX_EXTRA_AUTHORIZED_KEYS`.
3. **The `dev` host user owns the data, and root can read everything.** The bind mount belongs to the
   dedicated `dev` account, which also owns the project Docker daemon; your host account reaches it only
   via `sudo`. The container protects the host from the agent, not the files from its owner.

## ❓ FAQ

**Why not gVisor, Firecracker, or a VM?**
Overkill for the actual risk (a hostile dependency, not a targeted attacker), and it breaks herdr's
attach model. The cheap, high-value controls - non-root, no socket, dropped capabilities, address-scoped
port - are already in place.

**Should I enable user namespace remapping on the host?**
It would let the container run as root safely, but nothing here needs container root, and `userns-remap`
breaks the UID-matched bind mount that makes the data dir inspectable from the host - not worth it.

**Is `cap_drop: ALL` compatible with sshd?**
Yes: sshd never changes user. Dropping `CHOWN`/`SETUID`/`SETGID` is exactly what a root-launched sshd
would have needed.

**What if unprivileged sshd stops working after an OpenSSH update?**
Fix the unprivileged path - it's the whole design. `cap_add` and a root-launched sshd are off the table
per [AGENTS.md](../AGENTS.md) rule 4; `./bin/devbox shell` still gets you in while sshd is broken, so
there's no lock-out risk to trade the boundary away for.

**Can I give an agent a narrower key?**
Already the default: agents commit through each identity's own GitHub App where one is installed, scoped
to specific repositories
and permissions, and `gh` uses a fine-grained PAT rather than an account-wide OAuth token. The forwarded
1Password agent stays broad for manual work because it's yours - see accepted limit 2.

**Would per-repo deploy keys be tighter than the fine-grained PAT?**
Yes - but the primary path is already that tight: an installed GitHub App mints a token scoped to
exactly one repository for one hour. Deploy keys matter only for the fallback case - repos without the
App installed - where the fine-grained PAT trades the same breadth as any multi-repo PAT: it pushes
everywhere granted `contents: write`, readable by any agent, not just by you at a prompt. Install the App
on repos that matter instead of adding a deploy key.

**How do I revoke access from a lost laptop?**
The SSH keys are 1Password items, not files, so the laptop carries no key - but remove the *Devbox
Laptop* item from GitHub or `DEVBOX_EXTRA_AUTHORIZED_KEYS` anyway, restart the container (`authorized_keys` rebuilds on
every start), and drop it from the workstation's own
`~/.ssh/authorized_keys`. What the laptop **does** hold in plaintext, if `./bin/install-agent` ran there,
is the agent's own credentials: one `GH_TOKEN_<SLUG>` per identity in `~/.config/devbox/secrets.env`, and
each configured identity's App pem under its own `app` directory. Revoke every identity's PAT, rotate
every App private key - same list as a container compromise above.
