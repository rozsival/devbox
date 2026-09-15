# 🔑 Git identities

Two identities, personal and work, chosen by directory. The devbox holds no private key for either, and
there are two distinct modes of using them: you, and an agent session.

|                                             | Personal (everywhere)                                                                                                            | work (`~/projects/work/**`)                                                                                      |
|---------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------|
| **You** (manual, `ssh -A devbox` or laptop) | SSH `git@github.com:`, laptop's forwarded key (`id_personal.pub`), author `${GIT_PERSONAL_NAME} <${GIT_PERSONAL_EMAIL}>`, signed | SSH `git@work.github.com:`, forwarded `id_work.pub`, author `${GIT_WORK_NAME} <${GIT_WORK_EMAIL}>`, signed |
| **Agent session** (`omp` launcher)          | HTTPS, token from `devbox-git-credential`, author `rozsival-agent <rozsival-agent@users.noreply.github.com>`, unsigned           | HTTPS, same helper, author `work-app[bot] <00000000+work-app[bot]@users.noreply.github.com>`, unsigned    |

The `~/projects/work/**` directory rule picks the identity in both modes: git's own `includeIf gitdir:` for
you, the same prefix inside `agent.gitconfig`'s `includeIf` for an agent.

## Cloning

SSH URLs, chosen by directory, from a pane with the 1Password agent forwarded (`ssh -A devbox`, next
section):

```bash
git clone git@github.com:rozsival/<repo> ~/projects/rozsival/<repo>      # personal
git clone git@work.github.com:<org>/<repo> ~/projects/work/<repo>  # work
```

`work.github.com` is a `Host` alias in the container's `~/.ssh/config` pointing at `github.com` with
`IdentityFile ~/.ssh/id_work.pub` and `IdentitiesOnly yes` - it picks the work key out of whatever the
forwarded agent offers.

**The work alias cannot be skipped at clone time.** The
`url."git@work.github.com:".insteadOf=git@github.com:`
rewrite lives inside the `includeIf` file, and Git only loads that file once the repo directory exists. A
`git@github.com:` URL would therefore go out over the personal key. Repos already inside
`~/projects/work/` have their remotes rewritten automatically from then on.

`gh repo clone` works for personal repos (`gh config` sets `git_protocol ssh`); for work, clone by alias so
the remote URL is right from the start.

Confirm which identity a repo picked up (this reflects your manual identity in `~/.gitconfig`, not what an
agent session uses - see [Agent sessions](#agent-sessions) below):

```bash
cd ~/projects/work/<repo>
git config user.email        # you@work.example
git config user.signingkey   # /home/dev/.ssh/signing_work.pub
git remote -v
```

## Manual work on the devbox - the escape hatch

The devbox generates no keys and holds no private key for GitHub. A push, a signed commit, or cloning a
private repo as *you* borrows the 1Password agent already running on the laptop, forwarded for one
connection:

```bash
ssh -A devbox
```

`container/sshd_config` sets `AllowAgentForwarding yes` for exactly this. `~/.ssh/config` inside the devbox (rendered by
`bootstrap` from `home/.ssh/config.tpl`) does the picking: each `Host` block names a *public* key
with `IdentityFile` and `IdentitiesOnly yes`, so `ssh` offers exactly that one key out of whatever the
forwarded agent holds - without it the agent would offer every key it has and GitHub would accept whichever
comes first.

Without `-A`, a manual `git push` or a signed commit fails: there is no key to answer with, on purpose.
Ordinary `herdr` panes and `./bin/devbox shell` do **not** forward the agent - herdr's own SSH connection
never sets `ForwardAgent`, and the laptop's `Host devbox` block in `~/.ssh/config` keeps it off too. Only an
explicit `ssh -A devbox` does.

**Accepted limit.** For the lifetime of that one forwarded connection, anything running inside it - not just
git - can reach the agent socket with a raw `ssh` call and request a signature. Git itself cannot do this
from an agent session (the next section fences it to HTTPS), but a shell command run by hand inside
`ssh -A devbox` is not fenced. 1Password's own per-use approval prompt on the laptop is the backstop: nothing
signs without it. See [Security](security.md#accepted-limits).

## Agent sessions

Every agent session - an `omp`-launched OMP process, and everything it shells out to (`gh`, `wt`, `lazygit`,
git itself) - runs under five exports the `omp` launcher (`~/.local/libexec/devbox-agent/omp`) sets for its
own process tree only, before `exec`-ing the real `omp`:

| Export                | Value                              | What it does                                                 |
|-----------------------|------------------------------------|--------------------------------------------------------------|
| `GIT_CONFIG_GLOBAL`   | `~/.config/devbox/agent.gitconfig` | replaces `~/.gitconfig`, not merged with it                  |
| `GIT_SSH_COMMAND`     | `…/devbox-git-no-ssh`              | refuses every SSH remote, exit 255                           |
| `GIT_TERMINAL_PROMPT` | `0`                                | a missing credential is an error, never a hang               |
| `GH_CONFIG_DIR`       | `~/.config/devbox/gh`              | `gh` sees no stored login: a token from the shim, or nothing |
| `PATH`                | launcher's directory prepended     | puts the `gh` shim ahead of the real `gh`                    |

Nothing outside that process tree sees any of it - the same clone opened in a pane or an IDE keeps its SSH
remote, the forwarded 1Password agent and signed commits.

`GIT_CONFIG_GLOBAL` was chosen over `includeIf` selected by `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_*` env vars:
the latter does not honor `includeIf gitdir:` at all, so it cannot follow the repo tree the way
`agent.gitconfig`'s own `includeIf` does. Pointing `GIT_CONFIG_GLOBAL` at a file - and letting that file
`includeIf` into a second one - is what makes the directory rule work under an env override.

**Caveat:** a repository's own `.git/config` `user.email` still wins over `GIT_CONFIG_GLOBAL` - local config
always outranks global in git. That is stock behavior, not something this setup papers over.

### `agent.gitconfig`

- **Author**: `rozsival-agent <rozsival-agent@users.noreply.github.com>` - deliberately not a real, linked
  account: the pusher is a token, and the author is visibly not you.
- **Unsigned**: `commit.gpgsign = false`, `tag.gpgsign = false`. The signing keys are yours and never within
  an agent's reach.
- **HTTPS rewrite**: `url."https://github.com/".insteadOf` covers `git@github.com:`, `git@work.github.com:`,
  the user-less `github.com:` / `work.github.com:` forms an ssh config with `User git` allows,
  `ssh://git@github.com/` and the personal `gh:` shorthand - every GitHub remote goes over HTTPS regardless of
  how the clone was made.
- **Credential helper**: `[credential] helper =` first resets the helper list inherited from the system
  config (so an agent can never reach `osxkeychain` or a `gh` login stored for you), then
  `[credential "https://github.com"] helper = !devbox-git-credential, useHttpPath = true` - see below (`!`
  runs it as a command on the launcher's PATH; a bare name would mean `git credential-<name>`). Any
  non-GitHub HTTPS remote is left with no helper at all and fails outright (`GIT_TERMINAL_PROMPT=0` turns that
  into an immediate error, not a hang).
- **`includeIf gitdir:~/projects/work/`** pulls in `agent-work.gitconfig`, which re-sets
  `user.name`/`user.email` to `work-app[bot] <00000000+work-app[bot]@users.noreply.github.com>` -
  the same bot whose App installation token pushes the commit.
- **Self-contained on purpose**: it does not include `~/.gitconfig`. Both files carry `insteadOf` rewrites for
  the same prefixes, and when two rewrites tie on length git keeps the first one it read - including
  `~/.gitconfig` would let an SSH rewrite win over the HTTPS one.

### `devbox-git-credential`

Configured with `useHttpPath`, so every request names the repository. A token is minted **per git operation,
never cached, nothing stored**:

1. If `~/.config/work/work-app/{app-id,app.pem}` exist: sign a JWT (RS256, `openssl`), call
   `GET /repos/{owner}/{repo}/installation`. `200` → mint a repository-scoped installation token
   (`POST /app/installations/{id}/access_tokens` with `repositories:[repo]`, valid one hour) and use it.
   `404` → fall through to step 2. Any other HTTP status → hard failure, never a silent downgrade to the PAT.
2. Otherwise, the fine-grained PAT for the account the working directory belongs to - `devbox-gh-token`, the
   same `~/projects/work/**` rule `gh` and git's `includeIf` use.

`store` and `erase` are accepted and ignored - there is nothing to keep.
`devbox-git-credential explain owner/repo [dir]` prints which path a request would take (`app:<installation-id>` or
`pat:<account>`) without minting anything.

Because the App is scoped per repository by its own installation, there is no allowlist to maintain here -
installing the App on a repo (or not) is the only configuration. One consequence: a repo without the App
installed is pushed with the PAT, so that PAT now needs `contents: write` on it, not read-only - see
[Secrets](secrets.md#gh).

### The fence

`GIT_SSH_COMMAND` points at `devbox-git-no-ssh`, which prints a one-line explanation and exits 255 (ssh's own
"could not connect") for *any* remote the HTTPS rewrite did not already cover. It is set in the environment,
not `core.sshCommand`, so a repository-local override cannot reach past it. This is what keeps an agent off
your SSH keys and off a forwarded 1Password agent, whatever the remote URL says - a hard refusal, not a
courtesy.

## Signing

Agent commits are unsigned - `commit.gpgsign = false` in `agent.gitconfig`, by design: the signing keys are
yours.

Your own commits, made manually (`ssh -A devbox`, or on the laptop directly), are signed with
`gpg.format = ssh` against the forwarded 1Password agent:

```
user.signingkey = ~/.ssh/signing_personal.pub   # or signing_work.pub under ~/projects/work/
commit.gpgsign = true
tag.gpgsign = true
gpg.ssh.allowedSignersFile = ~/.ssh/allowed_signers
```

The signing key is a separate file from the authentication key (`id_*.pub`) because GitHub registers the two
kinds separately and each account uses a different key for each: signing with the authentication key
verifies locally and shows *Unverified* on GitHub. `GIT_*_SIGNINGKEY` in `.env` is the public key GitHub
lists under *SSH signing keys* for that account - on the laptop, `git config user.signingkey` prints it.

`ssh-keygen -Y sign` takes a *public* key file and signs through `SSH_AUTH_SOCK` - no private key needs to be
on disk for this to work. 1Password prompts for approval on the laptop, per signature. Without a forwarded
agent (a plain `ssh devbox`, a herdr pane, `./bin/devbox shell`), a manual commit fails to sign - the intended
shape of the escape hatch, not a bug.

```bash
git log --show-signature -1                                          # Good "git" signature with ED25519 key
gh api repos/<owner>/<repo>/commits/<sha> --jq .commit.verification  # verified: true
```

## Laptop install

`./bin/install-agent` installs the identical mechanism on the laptop, from the same `home/` templates the
devbox bootstraps from:

```bash
./bin/install-agent
```

It installs the launcher, the `gh` shim, `devbox-git-credential` and `devbox-git-no-ssh` into
`~/.local/libexec/devbox-agent`, `devbox-gh-token` into `~/.local/bin`, symlinks `~/.local/bin/omp` to the
launcher, and writes `~/.config/devbox/agent*.gitconfig` - regenerating every file on every run.
`~/.config/devbox/secrets.env` is created from the example only if it does not already exist, and is never
overwritten. It reads or edits nothing of yours.

On the laptop, only the launcher's own `PATH` export puts the libexec directory in front - an ordinary shell
or IDE never resolves the `gh` shim, so your own `gh` keeps its OAuth login. Whatever resolves `omp` on
`$PATH` besides the launcher is treated as "the real `omp`"; the installer reports which binary that is and
whether `omp` currently resolves to the launcher at all.

Remaining manual steps, printed by the installer: `GH_TOKEN_PERSONAL`/`GH_TOKEN_WORK` in
`~/.config/devbox/secrets.env`, and the work-app App credentials at
`~/.config/work/work-app/`. See [Secrets](secrets.md).

## Verify

```bash
# which credential path a repo would take, without minting a token
devbox-git-credential explain <owner>/<repo>

# inside an agent session: who git thinks it is, and that HTTPS/the helper are wired
git var GIT_AUTHOR_IDENT                                 # rozsival-agent <rozsival-agent@users.noreply.github.com> ...
git config --get credential.https://github.com.helper    # !devbox-git-credential
GIT_TRACE=1 git ls-remote https://github.com/<owner>/<repo> 2>&1 | grep -i http

# the work directory picks the bot author
cd ~/projects/work/<repo> && git var GIT_AUTHOR_IDENT  # work-app[bot] <...>

# the fence: any non-GitHub SSH remote refuses
git ls-remote git@gitlab.com:foo/bar    # devbox: ssh remotes are disabled in agent sessions...

# manual identity, forwarded agent required
ssh -A devbox
ssh -T git@github.com          # Hi <user>! - personal key
ssh -T git@work.github.com  # Hi <user>! - work key
```

## ❓ FAQ

**Can I put a personal repo outside `~/projects/rozsival/`?**
Yes. The personal identity is the global default; only `~/projects/work/**` is overridden. The
`~/projects/rozsival/` convention is organisational, not functional.

**I cloned an work repo with `git@github.com:` by mistake. How do I fix it?**
Nothing is broken - the `insteadOf` rewrite applies now that the directory exists. Confirm with
`GIT_TRACE=1 git fetch 2>&1 | grep ssh` that the work key is used, or set the URL explicitly:
`git remote set-url origin git@work.github.com:<org>/<repo>`.

**Why are agent commits unsigned?**
The signing keys are yours; an agent session has no private key and no forwarded agent to sign with (`GIT_SSH_COMMAND`
fences it off SSH entirely, and there is no HTTPS equivalent of `ssh-keygen -Y sign`).
`agent.gitconfig` sets `commit.gpgsign = false` rather than leave it to fail. Provenance for an agent commit
comes from its author identity and, for App-backed pushes, that only the App's own installation token could
have pushed it - not a signature.

**Why does the devbox generate no keys?**
A private key in the box is ambient push authority for every agent in it, whether you are present or not.
Public keys only, plus a forwarded agent that prompts on the laptop per use, keeps that authority with you.
`bootstrap` §2 deletes any devbox-generated private key from an earlier layout on sight and prints its
fingerprint so it can be revoked on GitHub. See [Security](security.md).

**A push says `Permission denied (publickey)`.**
Either the connection was not `-A` forwarded (`ssh devbox` instead of `ssh -A devbox`), or the laptop's own
key is not registered as an Authentication key on the target GitHub account. Reconnect with `-A` and check
`ssh -T git@github.com`.

**Commits show as unverified on GitHub.**
For a manual commit: the laptop key is missing as a *Signing* key on GitHub, or the commit email is not
attached to the account. For an agent commit: expected - agent commits are never signed.

**How do I run two `gh` accounts?**
The same way git picks an identity: by directory. `GH_TOKEN_PERSONAL` and `GH_TOKEN_WORK` live in
`~/.config/devbox/secrets.env`, and the `gh` shim (`~/.local/libexec/devbox-agent/gh`) resolves one per
invocation from the working directory (`devbox-gh-token --account` reports which). See
[Secrets](secrets.md#gh).

**Can an agent push to a repo the App is not installed on?**
Yes, with the fine-grained PAT for that directory's account - which is why the PAT now needs
`contents: write` on any repository agents push to without the App, not read-only. Install the App on a repo
to scope agent pushes down to one hour and one repository instead.

**What happens if I run an agent session by hand inside `ssh -A devbox`?**
Its own git is still fenced to HTTPS - `agent.gitconfig` and the fence apply the same as anywhere else. What
is not fenced is the shell around it: anything run directly in that pane, not through the launcher's git, can
still reach the forwarded agent socket with a raw `ssh` call. See
[Security](security.md#accepted-limits).
