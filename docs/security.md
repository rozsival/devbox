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

## What the container holds

Authority is enumerated, not ambient. Each credential is scoped, separately revocable, and separately
attributable:

| Purpose                 | Credential                                | Reach                              |
|-------------------------|-------------------------------------------|------------------------------------|
| Clone, pull, push       | `~/.ssh/id_personal`, `~/.ssh/id_work` | what those GitHub accounts can push |
| Commit author + signing | the same keys + the two-identity config   | verification only, grants nothing   |
| Agent commits           | work-app GitHub App                 | the App's repos and permissions     |
| Dashboards, CI, issues  | fine-grained PAT in `GH_TOKEN`            | named repos, read-mostly, expiring  |
| LLM inference           | per-project GCP service-account key       | one dev project, predict-only       |
| Project secrets         | that project's `.env`                     | one project                         |

Notably absent: any 1Password account (`op` is not installed) and any Google user credential. See
[Secrets](secrets.md).

## What an agent inside the devbox can reach

**Can**: the whole `/home/dev` tree - both SSH keys, `GH_TOKEN`, the App private key, every project's `.env`
and every GCP key - plus the internet, and the Tailnet from the container's network namespace.

**Cannot**: the host filesystem outside the data dir, the host Docker daemon, other containers' filesystems,
root inside the container, any port that is not published, and any 1Password vault.

The consequence to plan for: an agent with shell access has the same GitHub push reach as you do through those
keys. Treat a compromise as "revoke two SSH keys, one token, one App key and one service-account key", not
"rebuild a laptop".

## Accepted limits

These are known and deliberate, not gaps to be closed later:

1. **No egress filtering.** Outbound network is unrestricted, because the box needs the internet to work. An
   agent that reads a poisoned issue or README can send whatever it holds anywhere. IAM and token scoping
   limit what it can *reach*; nothing limits what it can *send*. This is why the container is a containment
   boundary for authority and **not** a confidentiality boundary - assume anything inside can leave.
2. **SSH keys can push wherever the accounts can.** Token scoping does not help: `git push` goes over SSH.
   The backstop is server-side - branch protection with required reviews on the repos agents work in.
3. **No isolation between projects.** One container, one `dev` user, one bind mount: an agent in project A can
   read project B's `.env` and GCP key. Cloning something less trusted is the point at which per-project
   containers or separate users stop being over-engineering.
4. **Secrets are plaintext at rest.** `.env` files, `GH_TOKEN` and key files are unencrypted on the
   workstation's disk, readable by the host user. Workstation disk encryption and host account hygiene are
   part of this security model, not separate from it.

An agent's own command allowlist - forbidding `op`, `gcloud` and similar - is a useful guardrail but not a
control: a subverted agent can call the same APIs through an SDK without either binary. The boundary is what
each credential is permitted to do.

## Deliberate boundaries

- **No host Docker socket.** Mounting `/var/run/docker.sock` would hand the sandbox host root and void the
  point of the container. Project-level containers are therefore unavailable inside the devbox; if they are
  ever needed, the answer is a `docker:dind-rootless` sidecar plus `DOCKER_HOST`, not a socket mount.
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
That is already the default: agents commit through the work-app GitHub App, which is scoped to specific
repositories and permissions, and `gh` uses a fine-grained PAT rather than an account-wide OAuth token. The
SSH keys remain broad because they are yours, for manual work - see accepted limit 2.

**Would per-repo deploy keys be tighter than the account SSH keys?**
Yes. A deploy key can push to exactly one repository, whereas these keys reach everything the accounts can -
and they are readable by any agent in the container, not just by you at a prompt (accepted limit 2). They
were rejected on friction, not because the exposure is hypothetical: a public key can be a deploy key on only
one repository, so it means one generated key plus one `~/.ssh/config` alias per repo, alias-based clone URLs,
and manual enrollment needing repo admin every time. Branch protection is the backstop chosen instead.

**How do I revoke access from a lost laptop?**
Remove the key from GitHub (or from `DEVBOX_EXTRA_AUTHORIZED_KEYS`) and restart the container -
`authorized_keys` is rebuilt on every start. Also remove it from the workstation's own
`~/.ssh/authorized_keys`.
