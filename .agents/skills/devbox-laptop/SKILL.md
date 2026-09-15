---
name: devbox-laptop
description: Sets up and checks the laptop side of the devbox - private keys only in 1Password, the named public keys in ~/.ssh (id_personal, signing_personal, id_work, signing_work, devbox), ~/.ssh/config that selects them through the 1Password agent, the two gitconfigs signing through op-ssh-sign, the agent git override (./bin/install-agent: omp launcher, gh shim, credential helper), the two fine-grained PATs in ~/.config/devbox/secrets.env, the GitHub App credentials, and ./bin/laptop-doctor as the acceptance test. Use this whenever someone is onboarding a new laptop or Mac, asks where a key, token or config file lives on the laptop, wants OMP on the laptop to stop using their identity, finds a private key on disk, sees commits Unverified on GitHub, gets a 1Password or op-ssh-sign prompt or failure, asks whether the laptop matches the devbox, or runs laptop-doctor and gets a WARN.
---

# devbox laptop

The laptop and the devbox share one identity layout, and the laptop is where every private half actually
lives: in 1Password, served by its SSH agent. Everything on disk is a public key, a config that selects
through it, or a token. `./bin/laptop-doctor` is the acceptance test for all of it - run it first, fix what
it names, run it again. Its checks are the phases below, in order.

Literal blocks and rationale live in `docs/setup.md` (key, ssh config) and `docs/git.md` (identities, the
agent override, signing). Read the section you need rather than retyping it, so a changed default is picked
up instead of reintroduced.

## Phase 1 - keys: 1Password items, public halves on disk

Five 1Password SSH Key items, each exported as one `.pub` file in `~/.ssh`:

| file                    | 1Password item        | used by                                          |
|-------------------------|-----------------------|--------------------------------------------------|
| `id_personal.pub`       | personal auth key     | `Host github.com`; GitHub *Authentication* key   |
| `signing_personal.pub`  | personal signing key  | `~/.gitconfig` `user.signingkey`; GitHub *Signing* key |
| `id_work.pub`        | work auth key      | `Host work.github.com`; work *Authentication* key |
| `signing_work.pub`   | work signing key   | `~/.config/work/.gitconfig`; work *Signing* key |
| `devbox.pub`            | Devbox Laptop         | `Host workstation`, `Host devbox`, `DEVBOX_EXTRA_AUTHORIZED_KEYS` |

Auth and signing are separate files because GitHub registers the two kinds separately and each account uses
a different key for each - signing with the auth key verifies locally and shows *Unverified* on GitHub.

Write a public half with the agent, never by generating a key:

```bash
export SSH_AUTH_SOCK="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
ssh-add -l                                   # fingerprints + item names
ssh-add -L | grep <key-material-prefix> > ~/.ssh/<name>.pub
```

A `ssh-keygen -t …` on the laptop is the wrong move: it creates a private key on disk, which is exactly the
state this layout removes. If `laptop-doctor` reports `private key(s) on disk`, the key either already
exists as a 1Password item (then delete the file) or must be imported into 1Password first (1Password →
New item → SSH Key → import), then deleted.

The same four GitHub public keys go into the workstation's `.env` as `GIT_*_PUBKEY` / `GIT_*_SIGNINGKEY`, so
the devbox selects the same forwarded keys - see the `devbox-setup` skill, phase 5.

## Phase 2 - `~/.ssh/config`

`Host *` names the 1Password socket as `IdentityAgent`; every host block names one `.pub` as `IdentityFile`
with `IdentitiesOnly yes`, so ssh offers exactly that key out of the six the agent holds. `Host devbox`
spells out `ForwardAgent no`: herdr's connection must never carry the agent, only an explicit `ssh -A devbox`
does. Blocks verbatim in `docs/setup.md#2-add-the-sshconfig-blocks`; the GitHub blocks follow the same
pattern with `id_personal.pub` and `id_work.pub`.

Check: `ssh -G devbox | grep -E 'identityfile|identitiesonly|identityagent'`, then
`ssh -T git@github.com` and `ssh -T git@work.github.com` must greet two different accounts.

## Phase 3 - gitconfigs

Your own commits sign through 1Password (`gpg.ssh.program = op-ssh-sign`), with the signing key named by
file so laptop and devbox read the same way:

```
~/.gitconfig                    user.signingkey = ~/.ssh/signing_personal.pub, gpg.format = ssh,
                                commit.gpgsign = true, gpg.ssh.allowedSignersFile = ~/.ssh/allowed_signers,
                                includeIf gitdir:~/projects/work/ → ~/.config/work/.gitconfig
~/.config/work/.gitconfig    user.name/email for work, user.signingkey = ~/.ssh/signing_work.pub
~/.ssh/allowed_signers          one line per identity: <email> <key type> <key>
```

Check: an empty commit in a throwaway repo under each tree, `git log --show-signature -1` → `Good "git"
signature for <email>` with the *signing* key's fingerprint.

## Phase 4 - the agent git override

```bash
./bin/install-agent
```

Installs, from this repo's `home/` templates, the same override the devbox bootstraps: the `omp` launcher
(`~/.local/bin/omp` → `~/.local/libexec/devbox-agent/omp`), the `gh` shim, `devbox-git-credential`,
`devbox-git-no-ssh`, `devbox-gh-token`, and `~/.config/devbox/agent*.gitconfig`. Every OMP session started
through a shell after this gets HTTPS remotes with per-operation tokens, the bot author, no signing, and a
`gh` that sees no stored login - your shell and IDE on the same clones keep the SSH remote, the 1Password
agent and signed commits. Re-run after every `git pull` of this repo that touches `home/`;
`laptop-doctor` reports files that drifted from the templates.

The launcher only applies to what resolves `omp` through the PATH. A herdr pane or shell alias that names
the binary by absolute path (`~/.bun/bin/omp`) bypasses it - use plain `omp`. Proof inside a session:
`echo $GIT_CONFIG_GLOBAL` prints `~/.config/devbox/agent.gitconfig`; empty means the session predates the
install or bypassed the launcher.

## Phase 5 - what the override needs

- `~/.config/devbox/secrets.env` (mode 600, created by `install-agent`): `GH_TOKEN_PERSONAL` and
  `GH_TOKEN_WORK`, fine-grained, `contents: write` on the repositories agents push to without the App,
  plus `actions`/`checks` read and `issues`/`pull-requests` write only if agents should post. Used by the
  credential helper for repositories the App is not installed on and by `gh` inside agent sessions. Same
  file and variables as on the devbox; only the PATs belong here on the laptop - model keys come from OMP's
  own login.
- `~/.config/work/work-app/app-id` and `app.pem` (mode 600): the credential helper mints a
  repository-scoped installation token from them on every git operation on a repository the App is
  installed on, ahead of the PAT. Without them, every work repository is pushed with the PAT.

Check: `./bin/laptop-doctor` validates both tokens against GitHub and the pem as a key;
`devbox-git-credential explain <owner>/<repo>` prints `app:<installation>` or `pat:<account>` for a repo.

## When `laptop-doctor` warns

| Warning                                         | Meaning and fix                                                          |
|-------------------------------------------------|--------------------------------------------------------------------------|
| `private key(s) on disk`                        | Import into 1Password if not there yet, then delete the file (phase 1)   |
| `<name>.pub … is not held by the 1Password agent` | Wrong export, or the item is disabled for the agent; re-export via `ssh-add -L` |
| `1Password SSH agent not reachable`             | Agent off (1Password → Developer → SSH agent) or 1Password locked        |
| `Host …: IdentityFile is …`                     | Block names a private key path or the wrong `.pub` (phase 2)             |
| `Host devbox: ForwardAgent yes`                 | Remove it; forward explicitly with `ssh -A devbox` when needed           |
| `user.signingkey is …`                          | Points at the literal key or the auth key; use the `signing_*.pub` path  |
| `omp resolves to …, not the launcher`           | `./bin/install-agent`, then put `~/.local/bin` first on the PATH         |
| `differ from the repo templates`                | `./bin/install-agent` (templates changed since the last install)         |
| `no <account> token` / `token is rejected`      | Fill or re-issue the PAT in `secrets.env` (phase 5)                      |
| `ssh devbox failed`                             | 1Password locked, or the Devbox Laptop key not yet approved for this app |
| `both aliases reach <login>`                    | `id_work.pub` is the personal key; re-export it (phase 1)             |

herdr's saved-machine connections are background ssh through the same agent: a machine flapping between
`connecting` and `offline` while 1Password is locked is that dependency, not a devbox fault.

## What is deliberately not here

- No `op` in the loop for tokens: `secrets.env` is plaintext at mode 600 on both machines, by choice; an
  `op://` resolver branch is the documented next step if that changes.
- No laptop-side `gh auth` change: your own `gh` keeps its OAuth logins. Only agent sessions see the
  login-less `GH_CONFIG_DIR` the launcher exports.
- Nothing GitHub-facing is registered from the laptop for the devbox: the devbox reuses these same public
  keys, already on both accounts.

## Where the details live

| Topic                                              | File                      |
|----------------------------------------------------|---------------------------|
| Key item, ssh config blocks, herdr and 1Password   | `docs/setup.md`           |
| Both modes of git, launcher, helper, signing       | `docs/git.md`             |
| Tokens, App credentials, `secrets.env`             | `docs/secrets.md`         |
| `bin/install-agent`, `bin/laptop-doctor`           | `docs/cli.md`             |
| Workstation and container side of the same setup   | `devbox-setup` skill      |
