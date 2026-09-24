# 🔑 Git identities

Any number of identities, chosen by directory. Each is a `[slug]` block in
`~/.config/devbox/identities.conf`, read by `devbox-identities`, the one script that turns the registry into
everything below. The devbox holds no private key for any of them; you and an agent session use them
differently.

|                                             | Default identity (everywhere)                                                                                           | A second identity (`~/projects/work/**`, org `your-org`)                                                                  |
|---------------------------------------------|-------------------------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------|
| **You** (manual, `ssh -A devbox` or laptop) | SSH `git@github.com:`, forwarded `id_personal.pub` (the host's plain key), author `Your Name <you@example.com>`, signed | SSH `git@github.com:`, forwarded `id_work.pub` (`ssh -P work` tags it), author `Your Name <you@work.example.com>`, signed |
| **Agent session** (`omp` launcher)          | HTTPS, token from `devbox-git-credential`, author `your-agent <your-agent@users.noreply.github.com>`, unsigned          | HTTPS, same helper, author `your-app[bot] <00000000+your-app[bot]@users.noreply.github.com>`, unsigned                    |

A `dir` in `identities.conf` picks the identity both ways: `includeIf gitdir:` in your own `~/.gitconfig`,
the same prefix in `agent.gitconfig`'s `includeIf` for an agent. Exactly one block omits `dir` - that one is
the default, catching every tree no other block claims; the rest match by longest prefix, so one tree can
nest inside another.

Nesting works because of two things the generators do, not because git does it for you. git applies *every* matching
`includeIf` and the last one read wins, so every identity with a `dir` gets a file of its
own - even one that only inherits the default author, which is then written out explicitly - and the
includes are emitted shortest `dir` first, whatever order the blocks appear in the config. A tree inside
another identity's tree therefore ends on its own name, email, signing key and agent author.

Org includes (`org-<slug>.gitconfig`, below) are separate from this nesting: `hasconfig:remote.*.url:`
matches a remote's URL text, not a directory, so they apply to a repository wherever it lives - and, unlike
`gitdir:`, from the very first `git clone`, since a clone writes the remote before it fetches. Both kinds of
`includeIf` land in `~/.gitconfig`; the tree-based ones are written first, so an org include - when one
applies - is read last and wins.

## The identity registry

`~/.config/devbox/identities.conf` is the single source. `~/.local/libexec/devbox-identities`
(`DEVBOX_IDENTITIES_FILE` overrides the path) is its one reader on both machines: `~/.ssh/config`,
`~/.gitconfig`'s `includeIf` chain, `allowed_signers`, both agent gitconfigs, and which GitHub token or App
a directory gets all come out of it. You create it by copying
`home/.config/devbox/identities.conf.example`; neither `container/bootstrap.sh` nor `./bin/install-agent`
writes it for you - the example is a *valid* file, so seeding it would quietly make `Your Name
<you@example.com>` this machine's identity instead of failing the check. Both print the `cp` command while
it is missing. Both machines need the *same* file; `./bin/sync-identities` copies the laptop's copy to
the devbox and re-runs bootstrap so everything derived from it catches up (see
[Laptop install](#laptop-install)).

One `[slug]` block per identity, `slug` lowercase `[a-z][a-z0-9_]*`:

| Field                       | Meaning                                                                                                                                                                                                                                                                                                                                                                                              | Default                                                |
|-----------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|--------------------------------------------------------|
| `dir`                       | Directory prefix that selects this identity. Must be absolute or start `~/`, and contain no whitespace - it also becomes a `gitdir:` pattern and a config key, and a relative path resolves differently for git than for the token resolver, so `check` rejects both. Omit on exactly one block - that one is the default, catching every tree no other `dir` matches. Longest matching prefix wins. | none on the default block                              |
| `name`, `email`             | Your git identity in that tree. Required.                                                                                                                                                                                                                                                                                                                                                            | -                                                      |
| `pubkey`                    | The laptop's *public* authentication key, one line, as in `~/.ssh/id_<slug>.pub`. Devbox only: it holds no private key. Empty disables SSH-as-you for that tree.                                                                                                                                                                                                                                     | empty                                                  |
| `signing_pubkey`            | The matching *public* signing key. GitHub registers authentication and signing keys separately; signing with the auth key shows *Unverified*.                                                                                                                                                                                                                                                        | empty                                                  |
| `agent_name`, `agent_email` | Author of agent commits in that tree.                                                                                                                                                                                                                                                                                                                                                                | the default identity's                                 |
| `app`                       | Directory holding a GitHub App's `app-id` + `app.pem` (mode 600) - see [`devbox-git-credential`](#devbox-git-credential).                                                                                                                                                                                                                                                                            | none - the PAT is used instead                         |
| `host`                      | Forge host. A GitHub Enterprise host moves the HTTPS rewrite, the API this identity's credentials use, and every `orgs` pattern onto that instance.                                                                                                                                                                                                                                                  | `github.com`                                           |
| `orgs`                      | GitHub owners (orgs or user logins) whose repositories this identity pushes to - space- or comma-separated, spelled exactly as GitHub spells them (matching is case-sensitive). Required for any identity whose `pubkey` differs from its host's plain key, since nothing else would ever select it. See [Cloning](#cloning).                                                                        | none - the plain key and the default identity's author |

Everything else is derived from the slug alone: `~/.ssh/id_<slug>.pub` / `~/.ssh/signing_<slug>.pub` (the
key files below), the ssh tag `<slug>` when its key differs from its host's plain one (`devbox-identities get
<slug> tag`, [Cloning](#cloning)), `GH_TOKEN_<SLUG>` in `~/.config/devbox/secrets.env` (see
[Secrets](secrets.md#gh)), and the generated `agent-<slug>.gitconfig` / `user-<slug>.gitconfig` /
`org-<slug>.gitconfig` (below). **Adding an account is therefore a block in `identities.conf`, a token in
`secrets.env`, and the two public keys - no code change anywhere.** See [Laptop install](#laptop-install)
and [Secrets](secrets.md#manual-checklist) for the exact steps.

`devbox-identities` is symlinked into `~/.local/bin`, so it answers by name in any shell.
`devbox-identities check` validates the file - exactly one default, no duplicate slugs, every `dir` absolute
and whitespace-free, `name`/`email` present, the default identity's `agent_name`/`agent_email` present, every
`orgs` entry a valid GitHub owner name, no org claimed by two identities on the same host, and an `orgs`
entry on any identity whose `pubkey` differs from its host's plain key (otherwise nothing ever selects that
key) - and is what a broken registry fails on: every identity-derived step of `bootstrap` is then skipped as
one block, so a bad edit costs configuration, never SSH access. `devbox-identities
list|for <dir>|get <slug> <field>|show <slug>|org-urls <slug>|alias-remotes` inspect the resolved registry;
`devbox-identities render ssh-config|agent-gitconfig [slug]|user-gitconfig <slug>|org-gitconfig
<slug>|allowed-signers` print exactly what `bootstrap` installs.

## Cloning

Plain GitHub URLs, chosen by directory, from a pane with the 1Password agent forwarded (`ssh -A devbox`, next
section):

```bash
git clone git@github.com:<your-github-username>/<repo> ~/projects/<your-github-username>/<repo>  # default identity
git clone git@github.com:<org>/<repo> ~/projects/work/<repo>                                       # work identity - <org> in its `orgs`
```

No alias host, ever - the remote is the same text whichever identity clones it. Two independent things key
off that text and pick the right identity, both live from the very first clone:

- **Which key SSH offers.** `org-work.gitconfig` sets `core.sshCommand = ssh -P work` for this repository,
  which selects `Match host github.com tagged work` in `~/.ssh/config` - `id_work.pub`, not the host's plain
  key. Only an identity whose key differs from the plain one gets a tag (`devbox-identities get work tag`;
  empty means no tag, and none needed).
- **Which author and signing key sign it.** `~/.gitconfig`'s `includeIf "hasconfig:remote.*.url:<pattern>"`
  (one per URL form git accepts for a GitHub remote - `git@github.com:<org>/**`,
  `ssh://git@github.com/<org>/**`, `https://github.com/<org>/**`, from `devbox-identities org-urls work`)
  loads `org-work.gitconfig`. `hasconfig:` matches the remote URL the clone itself writes, before the first
  fetch - unlike `includeIf gitdir:`, which only starts matching once the directory already exists.
- Matching is exact text, case-sensitive: `orgs = your-org` in `identities.conf` must be spelled exactly as
  GitHub spells the owner (`ApiTreeCZ`, not `apitreecz`).
- Directory-independent: an org's repository gets that org's identity wherever it is cloned to. The `dir`
  prefix only matters as a fallback - an identity's own non-org repositories inside its tree.

`gh repo clone` works the same way for every identity - `gh config` sets `git_protocol ssh`, and the URL it
clones with is the same `git@github.com:<owner>/<repo>` either way.

Confirm which identity a repo picked up (your manual identity in `~/.gitconfig`, not an agent session's - see
[Agent sessions](#agent-sessions)):

```bash
cd ~/projects/work/<repo>
git config user.email        # you@work.example.com
git config user.signingkey   # /home/dev/.ssh/signing_work.pub
git config core.sshCommand   # ssh -P work
git remote -v                # git@github.com:<org>/<repo> - no alias host
```

## Manual work on the devbox - the escape hatch

The devbox generates and holds no private GitHub key. A push, signed commit, or cloning a private repo as *you* borrows
the laptop's running 1Password agent, forwarded for one connection:

```bash
ssh -A devbox
```

`container/sshd_config` sets `AllowAgentForwarding yes` for this. The devbox's `~/.ssh/config` (`bootstrap`,
rendered from `identities.conf` by `devbox-identities render ssh-config`) has one plain `Host <host>` block
per forge naming the key most identities on it share (`IdentityFile` + `IdentitiesOnly yes`), plus a
`Match host <host> tagged <slug>` block per identity whose key differs, selected by the `ssh -P <slug>` an
org's `core.sshCommand` passes - so `ssh` offers exactly one key, never whichever the forwarded agent happens
to list first.

Without `-A`, a manual `git push` or signed commit fails on purpose - no key to answer. Ordinary `herdr`
panes and `./bin/devbox shell` do **not** forward the agent: herdr's SSH connection never sets `ForwardAgent`,
and the laptop's `Host devbox` block keeps it off - only an explicit `ssh -A devbox` does.

**Accepted limit.** For that connection's lifetime, anything inside it can reach the agent socket with a raw
`ssh` call. Git in an agent session can't (fenced to HTTPS), but a manual shell inside `ssh -A devbox` isn't.
1Password's per-use approval is the backstop: nothing signs without it. See
[Security](security.md#accepted-limits).

## Agent sessions

Every agent session - an `omp`-launched process and everything it shells out to (`gh`, `wt`, `lazygit`, git
itself) - runs under five exports the `omp` launcher (`~/.local/libexec/devbox-agent/omp-launcher`, reached
as `omp` through a symlink) sets for its process tree, before `exec`-ing real `omp`:

| Export                | Value                                  | What it does                            |
|-----------------------|----------------------------------------|-----------------------------------------|
| `GIT_CONFIG_GLOBAL`   | `~/.config/devbox/git/agent.gitconfig` | replaces `~/.gitconfig`, not merged     |
| `GIT_SSH_COMMAND`     | `…/devbox-git-no-ssh`                  | refuses every SSH remote, exit 255      |
| `GIT_TERMINAL_PROMPT` | `0`                                    | missing credential errors, never hangs  |
| `GH_CONFIG_DIR`       | `~/.config/devbox/gh`                  | `gh` sees no login: shim token, or none |
| `PATH`                | launcher's directory prepended         | puts `gh` shim ahead of real `gh`       |

Nothing outside that process tree sees any of it - a clone opened in a pane or IDE keeps its SSH remote,
forwarded agent, signed commits.

`GIT_CONFIG_GLOBAL` beats `includeIf` via `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_*`, which ignores `includeIf
gitdir:` and can't follow the repo tree like `agent.gitconfig`'s `includeIf`. Pointing `GIT_CONFIG_GLOBAL` at
a file that itself `includeIf`s a second makes the rule work under an env override.

**Caveat:** a repository's own `.git/config` `user.email` wins over `GIT_CONFIG_GLOBAL` - local always
outranks global in git. Stock git behavior.

**Read-only by install.** `~/.config/devbox/git/` is a directory of mode 500 holding both gitconfigs at
444, because `GIT_CONFIG_GLOBAL` points *into* it: a `git config --global …` anywhere in a session
rewrites the agent's own configuration. That is not hypothetical, and it needs no agent - on this laptop
`~/.bash_profile` sources `~/.extra`, which ends in

```bash
git config --global user.name "$GIT_AUTHOR_NAME"
git config --global user.email "$GIT_AUTHOR_EMAIL"
```

so *every login bash started inside a session* stamped the owner's name and email into
`agent.gitconfig`, and five commits in a personal repo carried it before anyone looked. git creates a lock
file beside the config it rewrites, so a directory without write permission turns that into an immediate
`error: could not lock config file` - loud, at the offending call, instead of silent drift. Reading is
unaffected. Fix the dotfile too (the `GIT_AUTHOR_*`/`GIT_COMMITTER_*` assignments above those lines serve
your own shell perfectly well); `./bin/laptop-doctor` flags the pattern. The launcher additionally
`unset`s `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`, `GIT_COMMITTER_NAME` and `GIT_COMMITTER_EMAIL`, which
outrank every configuration file, and refuses to start at all if the gitconfig is missing - no session may
run without an identity, because that is what invites something to set one. Both doctors check the mode
and compare the files against the repo templates; the installers (`./bin/install-agent`,
`./bin/devbox bootstrap`) lift the mode, regenerate, and lock it again.

### `omp update`

`omp update` picks what to replace by looking `omp` up on the `PATH`, and takes over whatever it finds -
a plain file in place, a symlink through its target. Both are the launcher, so the launcher drops its own
`PATH` entries for that one subcommand: the lookup then lands on the real install - bun/npm-managed on the
laptop, the standalone binary in `~/.local/bin` on the devbox - which is what the updater must replace.
`omp update` works normally; the launcher is untouched, and no export applies (no git runs).

Belt and braces, because the failure was silent: `omp` is a **symlink** to `omp-launcher` at both hops
(`~/.local/bin/omp` → `~/.local/libexec/devbox-agent/omp` → `omp-launcher`), never a file named `omp`.
An argv shape the passthrough does not recognise therefore hits the updater's own refusal to replace a
script behind a symlink - a one-line error - instead of a release binary landing on top of the launcher,
which leaves agent sessions on your `~/.gitconfig`, with SSH remotes and your keys. `./bin/laptop-doctor`
checks both hops are still symlinks.

### `agent.gitconfig`

- **Author**: not real - a name like `your-agent`, since the pusher is a token and the author is visibly
  not you.
- **Unsigned**: `commit.gpgsign = false`, `tag.gpgsign = false` - keys are yours, out of an agent's reach.
- **HTTPS rewrite**: one `[url "https://<host>/"]` block per forge host any identity names, covering
  `git@<host>:`, the user-less `<host>:` form an ssh config with `User git` allows, `ssh://git@<host>/`, and (on
  `github.com`) the `gh:` shorthand - every remote on that host goes over HTTPS however cloned, whichever
  identity it was cloned with. No alias host to cover: remotes are always plain.
- **Credential helper**: `[credential] helper =` clears inherited helpers (blocking `osxkeychain` or your
  `gh` login), then one `[credential "https://<host>"] helper = !devbox-git-credential, useHttpPath = true`
  per forge host (`!` runs it as a command on the launcher's PATH; a bare name would mean `git
  credential-<name>`). A host no identity's `host` field names gets no helper and fails outright
  (`GIT_TERMINAL_PROMPT=0`: immediate, not hung).
- **`includeIf gitdir:<dir>/`** - one per non-default identity that sets its own `agent_name`/`agent_email`,
  pulling in `agent-<slug>.gitconfig`, resetting `user.name`/`user.email` to that identity's bot author -
  the same bot whose App installation token, if `app` is configured, pushes it. An identity that leaves
  `agent_name`/`agent_email` unset simply inherits the default author and gets no include.
- **Self-contained**: excludes `~/.gitconfig`. Both files carry `insteadOf` rewrites for the same prefixes
  and git keeps the first read on a length tie, so including `~/.gitconfig` would let its SSH rewrite beat
  the HTTPS one.
- **Rendered, not hand-edited**: the static shape is `home/.config/devbox/git/agent.gitconfig.tpl`;
  `devbox-identities render agent-gitconfig` substitutes the registry-derived blocks above for its
  `@DEFAULT_AUTHOR@`/`@URL_REWRITES@`/`@INCLUDES@` markers. `container/bootstrap.sh` installs the result,
  plus one `agent-<slug>.gitconfig` per identity that claims a `dir` - every one of them, including those
  inheriting the default author, because git applies *every* matching `includeIf` and a tree nested inside
  another would otherwise keep the outer identity's author - and deletes any left over from a
  renamed or dropped identity.

### `devbox-git-credential`

Configured with `useHttpPath`: requests name the repository. Each request is answered from the identities
that could serve the request's host - the one
owning the working directory first, then the rest in config order, so two accounts with two Apps on the
same host stay apart:

1. For each candidate identity with `app` credentials (`app-id` + `app.pem`) at that path: sign a JWT (RS256,
   `openssl`), call `GET /repos/{owner}/{repo}/installation` against that identity's API (`https://api.github.com`, or
   `https://<host>/api/v3` for a GitHub Enterprise `host`). `200` → mint an
   installation token (`POST /app/installations/{id}/access_tokens`, `repositories:[repo]`, one hour) and
   use it. `404` → try the next candidate identity; any other status → hard failure, never a silent PAT
   downgrade.
2. Otherwise, the fine-grained PAT of the identity the working directory belongs to - `devbox-gh-token`, the
   same rule `gh` and git's `includeIf` use.

`store` and `erase` are accepted and ignored. `devbox-git-credential explain owner/repo
[dir]` prints which path a request would take - `app:<slug>:<installation-id>` or `pat:<slug>` - without
minting anything. `devbox-git-credential token owner/repo [dir]` prints just the App token, or nothing
when no App covers the repository: the `gh` shim's way to act as the same bot in an agent session
([Secrets](secrets.md#agent-sessions-the-app-for-one-repositorys-commands)).

Minting takes two API round trips (~0.75 s), so the App answer is cached per repository and per working
directory's identity: a token for 30 of its 60 minutes (whoever receives it keeps at least half an hour -
`gh run watch` included), "no App installed" for 5 minutes, so installing the App on a repository takes
effect within that. The cache is `devbox-agent-<uid>/` under `$XDG_RUNTIME_DIR`, else `/dev/shm` (the
container's tmpfs), else `$TMPDIR` (the laptop) - mode 700, files 600, never under `$HOME`, which is the
bind mount and gets backed up; a directory not owned by you there disables caching rather than trusting
it. Delete it to force a fresh mint. The PAT path was never slow and is not cached.

An App is scoped per repository by its installation - no allowlist; installing it is all the configuration.
A repo without the App gets the PAT, needing `contents: write` there, not read-only - see
[Secrets](secrets.md#gh). A host nothing in the registry names gets no credential at all.

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
per account; signing with it verifies locally but shows *Unverified*. `signing_pubkey` in
`~/.config/devbox/identities.conf` is the public key GitHub lists under *SSH signing keys* - `git config
user.signingkey` prints it on the laptop.

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

It installs `omp-launcher`, the `gh` shim, `devbox-git-credential`, and `devbox-git-no-ssh` into
`~/.local/libexec/devbox-agent`; `devbox-gh-token` into `~/.local/bin` and `devbox-identities` into
`~/.local/libexec`; symlinks `~/.local/bin/omp` → `~/.local/libexec/devbox-agent/omp` → `omp-launcher`;
names the `cp` command for `~/.config/devbox/identities.conf` when it is absent, and never writes that
file itself (the example validates, so seeding it would author agent commits as `your-agent`); and renders
`~/.config/devbox/git/agent*.gitconfig` from the registry, regenerating every file
each run and locking their directory read-only afterwards. `~/.config/devbox/secrets.env` is created from
the example if absent and never overwritten either. The installer reads or edits nothing of yours in either
file. It does **not** touch `~/.ssh/config` or `~/.gitconfig` - both are hand-maintained here (below);
`bootstrap` renders them on the devbox because nothing there is meant to be hand-edited.

On the laptop, only the launcher's `PATH` puts the libexec directory first - an ordinary shell or IDE never
resolves the `gh` shim, so your `gh` keeps its OAuth login. Whatever else resolves `omp` is "the real `omp`";
the installer reports which, and whether `omp` resolves to the launcher.

Remaining manual steps, printed by the installer: fill in each identity's block in
`~/.config/devbox/identities.conf` (at minimum `name`/`email`, plus `agent_name`/`agent_email` on the
default identity - see [The identity registry](#the-identity-registry)), a `GH_TOKEN_<SLUG>` per identity in
`~/.config/devbox/secrets.env`, and any configured `app` directory's GitHub App credentials. See
[Secrets](secrets.md). `./bin/laptop-doctor` then checks this with the rest of the laptop side - keys,
`~/.ssh/config`, signing, tokens, connections ([CLI reference](cli.md#binlaptop-doctor)).

`~/.ssh/config` isn't installed by this repo either - `devbox-identities render ssh-config` prints exactly
what it should contain, to copy in by hand (`laptop-doctor` checks the result, not what produced it). One
plain `Host <host>` block per forge, one `Match host <host> tagged <slug>` per identity whose key differs
from the plain one, `IdentityAgent` on `Host *` pointing at 1Password:

```
Host *
  IdentityAgent "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"

Host github.com
  User git
  IdentitiesOnly yes

Match host github.com tagged work
  IdentityFile ~/.ssh/id_work.pub

Match host github.com !tagged work
  IdentityFile ~/.ssh/id_personal.pub
```

Why tags rather than `ssh -i`: ssh tries the keys the agent lists in the *agent's* order, not the order
given on the command line, so `ssh -i id_work.pub` still answers as whichever account the forwarded agent
offers first - measured, not theoretical. A `Match … tagged` block is the only thing that overrides it.

The laptop side of the *manual* identity isn't installed by this repo either - it's your own `~/.gitconfig` -
but `laptop-doctor` holds it to the same layout the devbox bootstraps: one `includeIf "gitdir:…"` per tree (author and
signing key only - the SSH key follows the repository's owner, not the tree), and one triple of
`includeIf "hasconfig:remote.*.url:…"` per identity with `orgs` (author, signing key, and the ssh tag):

```
gpg.format = ssh
gpg.ssh.program = /Applications/1Password.app/Contents/MacOS/op-ssh-sign
commit.gpgsign = true
user.signingkey = ~/.ssh/signing_personal.pub
gpg.ssh.allowedSignersFile = ~/.ssh/allowed_signers
includeIf "gitdir:~/projects/work/"                                 → user-work.gitconfig ([user] only)
includeIf "hasconfig:remote.*.url:git@github.com:your-org/**"       → org-work.gitconfig
includeIf "hasconfig:remote.*.url:ssh://git@github.com/your-org/**" → org-work.gitconfig
includeIf "hasconfig:remote.*.url:https://github.com/your-org/**"   → org-work.gitconfig
```

`devbox-identities org-urls work` prints the three patterns for an identity's `orgs`; `devbox-identities
render org-gitconfig work` prints the file they point at - any file, e.g. `~/.config/work/org.gitconfig`:

```
[user]
  name = Your Name
  email = you@work.example.com
  signingkey = ~/.ssh/signing_work.pub
[core]
  sshCommand = ssh -P work
```

`[core] sshCommand` is only in the org file, never the `gitdir:` one: it is what makes the *ssh tag* follow
the repository's owner, independent of which tree it was cloned into. `devbox-identities render
user-gitconfig work` prints the `gitdir:` file the same way - `[user]` only, no `sshCommand`, since a
personal repository cloned into a work tree still has to push with your own key.

`allowed_signers` needs one line per identity (`<email> <key type> <key>`) so `git log --show-signature`
verifies all of them - `devbox-identities render allowed-signers` builds it from whichever
`signing_<slug>.pub` files exist on disk.

Both machines hold the same `identities.conf`. `./bin/sync-identities [ssh-host]` copies the laptop's copy
to the devbox (keeping one `identities.conf.bak` there), validates it locally with `devbox-identities check`
first so a broken file never lands, then re-runs `container/bootstrap.sh` so `~/.ssh/config`, `~/.gitconfig`'s
`user-*`/`org-*` includes, the agent gitconfigs and `allowed_signers` catch up - the same regeneration
`./bin/devbox bootstrap` does on its own, and just as idempotent. The laptop's own `~/.ssh/config` and
`~/.gitconfig` are yours to keep in sync by hand; `laptop-doctor` is what notices drift.

## Verify

```bash
# which credential path a repo would take, without minting a token
devbox-git-credential explain <owner>/<repo>

# who owns a directory, and every resolved field for an identity
devbox-identities for ~/projects/work/<repo>
devbox-identities show work

# inside an agent session: who git thinks it is, and that HTTPS/the helper are wired
git var GIT_AUTHOR_IDENT                                 # your-agent <your-agent@users.noreply.github.com> ...
git config --get credential.https://github.com.helper    # !devbox-git-credential
GIT_TRACE=1 git ls-remote https://github.com/<owner>/<repo> 2>&1 | grep -i http

# a second identity's directory picks its own author
cd ~/projects/work/<repo> && git var GIT_AUTHOR_IDENT  # your-app[bot] <...>

# the fence: any non-GitHub SSH remote refuses
git ls-remote git@gitlab.com:foo/bar    # devbox: ssh remotes are disabled in agent sessions...

# manual identity, forwarded agent required
ssh -A devbox
ssh -T git@github.com        # Hi <user>! - default identity's key
ssh -P work -T git@github.com # Hi <user>! - work identity's key
```

## ❓ FAQ

**Can I put a repo for my default identity outside `~/projects/<your-github-username>/`?**
Yes. The default identity catches every tree no other `dir` overrides; the `~/projects/<slug>/` layout is
organisational, not functional.

**I cloned an org's repo into the wrong directory. Do I need to fix anything?**
No - `hasconfig:remote.*.url:` matches the remote's URL text, not a directory, so the org's identity (author,
signing key, ssh tag) applies wherever the clone lives. Move it for tidiness if you like; nothing to fix.
Only the `dir`-scoped fallback - an identity's own non-org repositories inside its tree - cares where a repo
sits.

**Why no SSH aliases?**
ssh picks a key by *host*, so before tags existed, a second identity needed a fake `Host <slug>.<host>` block
and a `git@<slug>.<host>:` URL in every remote and every clone command just to give ssh something to key off.
Two things removed the need: `hasconfig:remote.*.url:` matches the remote itself - case-sensitively, as
text, against `git@<host>:<org>/**`, `ssh://git@<host>/<org>/**` and `https://<host>/<org>/**` (`orgs` must
be spelled exactly as GitHub spells the owner) - and it already holds on the very first `git clone`, since
clone writes the remote before it fetches; no alias was ever needed to make that first clone land right. The
ssh tag (`ssh -P <slug>`, set by `org-<slug>.gitconfig`'s `core.sshCommand`) replaced the alias host for
picking the *key*: a `Match host <host> tagged <slug>` block, not `ssh -i` - ssh offers keys in the order the *agent*
lists them, not the order given on the command line, so `ssh -i id_work.pub` still answered as
whichever account the forwarded agent offered first, measured on this repo before tags existed. Old clones
left on a `git@<slug>.<host>:` remote resolve nothing now (`devbox-identities alias-remotes` lists them;
`laptop-doctor` and `bootstrap` print the `git remote set-url` commands to fix each one).

**After `omp update`, my agent tried to use my SSH keys.**
Fixed in the launcher, and worth recognising: before the `update` passthrough existed, the updater resolved
`omp` on the launcher's own `PATH` and wrote the release binary straight over the launcher script, so later
sessions read `~/.gitconfig` - SSH remotes, your keys, 1Password prompting. Repair is
`./bin/install-agent` on the laptop, `./bin/devbox bootstrap` on the devbox; both are idempotent and the
update itself is not lost (re-run `omp update`). Recognition cue: `./bin/laptop-doctor` reports the
installed launcher no longer matching the repo template - the `~/.local/bin/omp` symlink stays intact, it
is the file behind it that became a ~180 MB binary. Inside a session, `echo $GIT_CONFIG_GLOBAL` printing
nothing says the same thing.

**An agent committed under my own name and email.**
Different failure from the one above, and the fence was working: HTTPS remote, per-operation token,
unsigned commit - only the author was wrong. The `[user]` section of the installed
`~/.config/devbox/git/agent.gitconfig` had been rewritten, which is what a `git config --global user.name
…` inside a session does: `GIT_CONFIG_GLOBAL` points at that file. On this laptop the caller was not an
agent at all but `~/.extra`, sourced by `~/.bash_profile`, so any login bash a session started did it.
Delete those two lines from the dotfile. The directory is mode 500 now, so the
same call fails with `could not lock config file`; repair a drifted copy with `./bin/install-agent`
(laptop) or `./bin/devbox bootstrap` (devbox). Both doctors compare the two files against the templates
and check the mode. Commits already made are only fixable by rewriting history, and `--reset-author` is
the wrong tool: it takes the author from the shell doing the rewrite, so from your own terminal it stamps
you again. Name the author instead, per commit to rewrite, and leave your own commits alone:
`git rebase -i <base>` from your own terminal with
`exec git commit --amend --no-edit --no-gpg-sign --author='your-agent
<your-agent@users.noreply.github.com>'` after each offending pick. `--no-gpg-sign` matters: your
`commit.gpgsign = true` would otherwise sign the bot-authored commits with *your* key. Commits of yours
that the rebase re-creates are re-signed automatically (1Password prompts per commit). Then force-push,
after checking nobody else has pulled the branch.

**Why are agent commits unsigned?**
No private key or forwarded agent to sign with in an agent session - `GIT_SSH_COMMAND` fences off SSH, with
no HTTPS equivalent of `ssh-keygen -Y sign`. `agent.gitconfig` sets `commit.gpgsign = false` rather than
fail. Provenance: author identity, and for App-backed pushes, only the App's token could have pushed it -
not a signature.

**Why does the devbox generate no keys?**
A private key there is ambient push authority for every agent, present or not. Public keys, plus a forwarded
agent prompting per use, keep that authority with you. `bootstrap` deletes any earlier devbox-generated
private key, printing its fingerprint for revoking on GitHub. See [Security](security.md).

**A push says `Permission denied (publickey)`.**
Either the connection wasn't `-A` forwarded (`ssh devbox` instead of `ssh -A devbox`), or the laptop's key
isn't registered as an Authentication key on the GitHub account. Reconnect with `-A` and check
`ssh -T git@github.com`.

**Commits show as unverified on GitHub.**
For a manual commit: the laptop key is missing as a *Signing* key, or the commit email isn't attached to
the account. For an agent commit: expected - never signed.

**How do I run two `gh` accounts?**
The same way git picks an identity: by directory. `GH_TOKEN_<SLUG>` for each identity lives in
`~/.config/devbox/secrets.env`; the `gh` shim (`~/.local/libexec/devbox-agent/gh`) resolves one per
invocation from the directory (`devbox-gh-token --account` reports which). See [Secrets](secrets.md#gh).

**Can an agent push to a repo the App is not installed on?**
Yes, with the fine-grained PAT for that identity - why it needs `contents: write` on repos pushed without
the App, not read-only. Install the App to scope pushes to one hour and one repo instead.

**Why are an agent's PRs opened by the App's bot and not by me?**
In an agent session, `gh` commands about one repository the identity's App is installed on use that App's
installation token - the one its git pushes with - so PRs, issues and comments carry the same author as the
commits. Your own `gh`, and account-wide agent commands (`gh repo list`, `gh api user`), keep the PAT. See
[Secrets](secrets.md#agent-sessions-the-app-for-one-repositorys-commands).

**How do I add a third account?**
One `[slug]` block in `~/.config/devbox/identities.conf`, a `GH_TOKEN_<SLUG>` in
`~/.config/devbox/secrets.env`, and the identity's two public keys, already on GitHub. Apply with
`./bin/sync-identities` from the laptop, or `./bin/devbox bootstrap` on the devbox alone - no code change,
nowhere. See [The identity registry](#the-identity-registry).

**Can two identities be the same GitHub account?**
Yes - the way to give an organization of your own its own token, since a fine-grained PAT has exactly one
resource owner (your user *or* one org). Copy the default block under a new slug with its own `dir` and
`orgs` naming that org, the same `pubkey`/`signing_pubkey` as the default (so it gets no tag - the key
already matches the plain one), and copy `id_<default>.pub`/`signing_<default>.pub` to the new slug's names
on the laptop. `laptop-doctor` normally fails two identities' connections greeting one login as a wrong key;
identical `pubkey` lines in the registry declare it deliberate, so that check skips the pair.

**Both machines hold `identities.conf` - which one wins?**
Neither is authoritative by itself; they're expected to agree. `./bin/sync-identities` always copies
laptop → devbox (validating with `devbox-identities check` before it copies), because the laptop is where
you hand-edit the file and where 1Password holds the private keys it names. Editing the devbox's copy
directly works too - `./bin/devbox bootstrap` re-derives everything from whichever copy is on disk there -
but the next `sync-identities` overwrites it with the laptop's, so a devbox-only edit should be mirrored
back by hand or it will be lost on the next sync.

**Can two identities share one GitHub App?**
Point both blocks' `app` field at the same directory. `devbox-git-credential` tries the working directory's
own identity first and then the rest in config order, so whichever one the App is actually installed for
answers `GET /repos/{owner}/{repo}/installation` with `200`; the other falls through. One App installed on
repositories from two orgs works the same way as two Apps, at the cost of both identities sharing one
`app.pem` to protect.

**What happens if I run an agent session by hand inside `ssh -A devbox`?**
Its git is still fenced to HTTPS - same as anywhere else. The shell around it isn't: anything run there can
reach the forwarded agent socket with a raw `ssh` call. See [Security](security.md#accepted-limits).
