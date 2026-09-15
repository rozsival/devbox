# 🔑 Git identities

Two identities, personal and work, chosen by directory. The devbox holds no private key for either; you
and an agent session use them differently.

|                                             | Personal (everywhere)                                                                                                            | work (`~/projects/work/**`)                                                                                      |
|---------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------|
| **You** (manual, `ssh -A devbox` or laptop) | SSH `git@github.com:`, forwarded `id_personal.pub`, author `${GIT_PERSONAL_NAME} <${GIT_PERSONAL_EMAIL}>`, signed | SSH `git@work.github.com:`, forwarded `id_work.pub`, author `${GIT_WORK_NAME} <${GIT_WORK_EMAIL}>`, signed |
| **Agent session** (`omp` launcher)          | HTTPS, token from `devbox-git-credential`, author `rozsival-agent <rozsival-agent@users.noreply.github.com>`, unsigned           | HTTPS, same helper, author `work-app[bot] <00000000+work-app[bot]@users.noreply.github.com>`, unsigned    |

The `~/projects/work/**` rule picks the identity both ways: `includeIf gitdir:` in your gitconfig, same
prefix in `agent.gitconfig`'s `includeIf` for an agent.

## Cloning

SSH URLs, chosen by directory, from a pane with the 1Password agent forwarded (`ssh -A devbox`, next
section):

```bash
git clone git@github.com:rozsival/<repo> ~/projects/rozsival/<repo>      # personal
git clone git@work.github.com:<org>/<repo> ~/projects/work/<repo>  # work
```

`work.github.com` is a `Host` alias in `~/.ssh/config`: `github.com` with `IdentityFile
~/.ssh/id_work.pub` and `IdentitiesOnly yes`, picking the work key from the agent's offer. **Not
skippable at clone time**: its `url."git@work.github.com:".insteadOf=git@github.com:` rewrite lives in
the `includeIf` file, loaded only once the repo exists - a `git@github.com:` URL would go out over the
personal key. Repos under `~/projects/work/` get remotes rewritten after.

`gh repo clone` works for personal repos (`gh config` sets `git_protocol ssh`); for work, clone by alias -
the remote URL is right from the start.

Confirm which identity a repo picked up (your manual identity in `~/.gitconfig`, not an agent session's - see
[Agent sessions](#agent-sessions)):

```bash
cd ~/projects/work/<repo>
git config user.email        # you@work.example
git config user.signingkey   # /home/dev/.ssh/signing_work.pub
git remote -v
```

## Manual work on the devbox - the escape hatch

The devbox generates and holds no private GitHub key. A push, signed commit, or cloning a private repo as
*you* borrows the laptop's running 1Password agent, forwarded for one connection:

```bash
ssh -A devbox
```

`container/sshd_config` sets `AllowAgentForwarding yes` for this. The devbox's `~/.ssh/config` (`bootstrap`,
from `home/.ssh/config.tpl`) picks: each `Host` block names a *public* key with `IdentityFile` and
`IdentitiesOnly yes`, so `ssh` offers only that key - otherwise GitHub takes whichever agent key comes first.

Without `-A`, a manual `git push` or signed commit fails on purpose - no key to answer. Ordinary `herdr`
panes and `./bin/devbox shell` do **not** forward the agent: herdr's SSH connection never sets `ForwardAgent`,
and the laptop's `Host devbox` block keeps it off - only an explicit `ssh -A devbox` does.

**Accepted limit.** For that connection's lifetime, anything inside it can reach the agent socket with a raw
`ssh` call. Git in an agent session can't (fenced to HTTPS), but a manual shell inside `ssh -A devbox` isn't.
1Password's per-use approval is the backstop: nothing signs without it. See
[Security](security.md#accepted-limits).

## Agent sessions

Every agent session - an `omp`-launched process and everything it shells out to (`gh`, `wt`, `lazygit`, git
itself) - runs under five exports the `omp` launcher (`~/.local/libexec/devbox-agent/omp`) sets for its
process tree, before `exec`-ing real `omp`:

| Export                | Value                              | What it does                                         |
|-----------------------|-------------------------------------|-------------------------------------------------------|
| `GIT_CONFIG_GLOBAL`   | `~/.config/devbox/agent.gitconfig` | replaces `~/.gitconfig`, not merged     |
| `GIT_SSH_COMMAND`     | `…/devbox-git-no-ssh`              | refuses every SSH remote, exit 255      |
| `GIT_TERMINAL_PROMPT` | `0`                                | missing credential errors, never hangs  |
| `GH_CONFIG_DIR`       | `~/.config/devbox/gh`              | `gh` sees no login: shim token, or none |
| `PATH`                | launcher's directory prepended     | puts `gh` shim ahead of real `gh`       |

Nothing outside that process tree sees any of it - a clone opened in a pane or IDE keeps its SSH remote,
forwarded agent, signed commits.

`GIT_CONFIG_GLOBAL` beats `includeIf` via `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_*`, which ignores `includeIf
gitdir:` and can't follow the repo tree like `agent.gitconfig`'s `includeIf`. Pointing `GIT_CONFIG_GLOBAL` at
a file that itself `includeIf`s a second makes the rule work under an env override.

**Caveat:** a repository's own `.git/config` `user.email` wins over `GIT_CONFIG_GLOBAL` - local always
outranks global in git. Stock git behavior.

### `agent.gitconfig`

- **Author**: `rozsival-agent <...>` - not real: pusher is a token, author visibly not you.
- **Unsigned**: `commit.gpgsign = false`, `tag.gpgsign = false` - keys are yours, out of an agent's reach.
- **HTTPS rewrite**: `url."https://github.com/".insteadOf` covers `git@github.com:`, `git@work.github.com:`,
  the user-less `github.com:`/`work.github.com:` forms an ssh config with `User git` allows,
  `ssh://git@github.com/`, and the `gh:` shorthand - every GitHub remote goes over HTTPS however cloned.
- **Credential helper**: `[credential] helper =` clears inherited helpers (blocking `osxkeychain` or your
  `gh` login), then sets `[credential "https://github.com"] helper = !devbox-git-credential, useHttpPath =
  true` (`!` runs it as a command on the launcher's PATH; a bare name would mean `git credential-<name>`).
  Non-GitHub HTTPS remotes get no helper and fail outright (`GIT_TERMINAL_PROMPT=0`: immediate, not hung).
- **`includeIf gitdir:~/projects/work/`** pulls in `agent-work.gitconfig`, resetting
  `user.name`/`user.email` to the work bot identity - same bot whose App installation token pushes it.
- **Self-contained**: excludes `~/.gitconfig`. Both files carry `insteadOf` rewrites for the same prefixes
  and git keeps the first read on a length tie, so including `~/.gitconfig` would let its SSH rewrite beat
  the HTTPS one.

### `devbox-git-credential`

Configured with `useHttpPath`: requests name the repository. A token is minted **per git operation,
never cached, nothing stored**:

1. If `~/.config/work/work-app/{app-id,app.pem}` exist: sign a JWT (RS256, `openssl`), call
   `GET /repos/{owner}/{repo}/installation`. `200` → mint an installation token
   (`POST /app/installations/{id}/access_tokens`, `repositories:[repo]`, one hour) and use it. `404` → step
   2; any other status → hard failure, never a silent PAT downgrade.
2. Otherwise, the fine-grained PAT for the directory's account - `devbox-gh-token`, the
   `~/projects/work/**` rule `gh` and git's `includeIf` use.

`store` and `erase` are accepted and ignored - nothing to keep. `devbox-git-credential explain owner/repo
[dir]` prints which path a request would take (`app:<installation-id>` or `pat:<account>`) without minting
anything.

The App is scoped per repository by its installation - no allowlist; installing it is all the
configuration. A repo without the App gets the PAT, needing `contents: write` there, not read-only - see
[Secrets](secrets.md#gh).

### The fence

`GIT_SSH_COMMAND` points at `devbox-git-no-ssh`, printing a one-line explanation and exiting 255 (ssh's own
"could not connect") for *any* uncovered remote. Set in the environment, not `core.sshCommand`, so a
repository-local override can't reach past it - keeping an agent off your SSH keys and any forwarded agent,
whatever the remote says.

## Signing

Agent commits are unsigned - `commit.gpgsign = false` in `agent.gitconfig`, by design: the signing keys are
yours.

Your manual commits are signed with `gpg.format = ssh` - on the laptop through 1Password's signer
(`gpg.ssh.program = /Applications/1Password.app/Contents/MacOS/op-ssh-sign`), on the devbox (`ssh -A devbox`)
against the forwarded 1Password agent:

```
user.signingkey = ~/.ssh/signing_personal.pub   # or signing_work.pub under ~/projects/work/
commit.gpgsign = true
tag.gpgsign = true
gpg.ssh.allowedSignersFile = ~/.ssh/allowed_signers
```

The signing key is separate from the authentication key (`id_*.pub`) - GitHub registers both separately, one
per account; signing with it verifies locally but shows *Unverified*. `GIT_*_SIGNINGKEY` in `.env` is the
public key GitHub lists under *SSH signing keys* - `git config user.signingkey` prints it on the laptop.

`ssh-keygen -Y sign` takes a *public* key file and signs through `SSH_AUTH_SOCK` - no private key on disk
needed. 1Password prompts for approval, per signature. Without a forwarded agent (`ssh devbox`, a herdr
pane, `./bin/devbox shell`), a manual commit fails to sign - by design.

```bash
git log --show-signature -1                                          # Good "git" signature with ED25519 key
gh api repos/<owner>/<repo>/commits/<sha> --jq .commit.verification  # verified: true
```

## Laptop install

`./bin/install-agent` installs the identical mechanism on the laptop, from the `home/` templates the devbox
bootstraps from:

```bash
./bin/install-agent
```

It installs the launcher, `gh` shim, `devbox-git-credential`, and `devbox-git-no-ssh` into
`~/.local/libexec/devbox-agent`; `devbox-gh-token` into `~/.local/bin`; symlinks `~/.local/bin/omp` to the
launcher; writes `~/.config/devbox/agent*.gitconfig`, regenerating every file each run.
`~/.config/devbox/secrets.env` is created from the example if absent and never overwritten. The installer
reads or edits nothing of yours.

On the laptop, only the launcher's `PATH` puts the libexec directory first - an ordinary shell or IDE never
resolves the `gh` shim, so your `gh` keeps its OAuth login. Whatever else resolves `omp` is "the real `omp`";
the installer reports which, and whether `omp` resolves to the launcher.

Remaining manual steps, printed by the installer: `GH_TOKEN_PERSONAL`/`GH_TOKEN_WORK` in
`~/.config/devbox/secrets.env`, and the work-app App credentials at
`~/.config/work/work-app/`. See [Secrets](secrets.md). `./bin/laptop-doctor` then checks this with
the rest of the laptop side - keys, `~/.ssh/config`, signing, tokens, connections
([CLI reference](cli.md#binlaptop-doctor)).

The laptop side of the *manual* identity isn't installed by this repo - it's your own `~/.gitconfig` - but
`laptop-doctor` holds it to the same layout the devbox bootstraps, so both read a commit alike:

```
gpg.format = ssh
gpg.ssh.program = /Applications/1Password.app/Contents/MacOS/op-ssh-sign
commit.gpgsign = true
user.signingkey = ~/.ssh/signing_personal.pub
gpg.ssh.allowedSignersFile = ~/.ssh/allowed_signers
includeIf "gitdir:~/projects/work/" → a file setting user.signingkey = ~/.ssh/signing_work.pub
```

`allowed_signers` needs one line per identity (`<email> <key type> <key>`) so `git log --show-signature`
verifies both.

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
Yes. Personal is the global default; only `~/projects/work/**` is overridden. The
`~/projects/rozsival/` path is organisational, not functional.

**I cloned an work repo with `git@github.com:` by mistake. How do I fix it?**
Nothing is broken - the `insteadOf` rewrite applies, since the directory exists. Confirm with
`GIT_TRACE=1 git fetch 2>&1 | grep ssh` that the work key is used, or set the URL explicitly:
`git remote set-url origin git@work.github.com:<org>/<repo>`.

**`bootstrap` tells me to repoint a stale `github-work:` remote.**
The alias used to be `github-work`; it is `work.github.com` now, on the laptop and the devbox alike.
`bootstrap` §6 removes the old `insteadOf` rewrite from `~/.config/work/.gitconfig` (leaving both would
make the remote ambiguous) and lists clones under `~/projects/work/` naming the old alias. Fix each with
`git -C ~/projects/work/<repo> remote set-url origin git@work.github.com:<org>/<repo>`.

**Why are agent commits unsigned?**
No private key or forwarded agent to sign with in an agent session - `GIT_SSH_COMMAND` fences off SSH, with
no HTTPS equivalent of `ssh-keygen -Y sign`. `agent.gitconfig` sets `commit.gpgsign = false` rather than
fail. Provenance: author identity, and for App-backed pushes, only the App's token could have pushed it -
not a signature.

**Why does the devbox generate no keys?**
A private key there is ambient push authority for every agent, present or not. Public keys, plus a forwarded
agent prompting per use, keep that authority with you. `bootstrap` §2 deletes any earlier devbox-generated
private key, printing its fingerprint for revoking on GitHub. See [Security](security.md).

**A push says `Permission denied (publickey)`.**
Either the connection wasn't `-A` forwarded (`ssh devbox` instead of `ssh -A devbox`), or the laptop's key
isn't registered as an Authentication key on the GitHub account. Reconnect with `-A` and check
`ssh -T git@github.com`.

**Commits show as unverified on GitHub.**
For a manual commit: the laptop key is missing as a *Signing* key, or the commit email isn't attached to
the account. For an agent commit: expected - never signed.

**How do I run two `gh` accounts?**
The same way git picks an identity: by directory. `GH_TOKEN_PERSONAL` and `GH_TOKEN_WORK` live in
`~/.config/devbox/secrets.env`; the `gh` shim (`~/.local/libexec/devbox-agent/gh`) resolves one per
invocation from the directory (`devbox-gh-token --account` reports which). See [Secrets](secrets.md#gh).

**Can an agent push to a repo the App is not installed on?**
Yes, with the fine-grained PAT for that account - why it needs `contents: write` on repos pushed without
the App, not read-only. Install the App to scope pushes to one hour and one repo instead.

**What happens if I run an agent session by hand inside `ssh -A devbox`?**
Its git is still fenced to HTTPS - same as anywhere else. The shell around it isn't: anything run there can
reach the forwarded agent socket with a raw `ssh` call. See [Security](security.md#accepted-limits).
