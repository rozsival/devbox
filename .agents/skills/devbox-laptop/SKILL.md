---
name: devbox-laptop
description: Sets up and checks the laptop side of the devbox - private keys only in 1Password, the named public keys in ~/.ssh (id_personal, signing_personal, id_work, signing_work, devbox), ~/.ssh/config that selects them through the 1Password agent, the two gitconfigs signing through op-ssh-sign, the agent git override (./bin/install-agent: omp launcher, gh shim, credential helper), the two fine-grained PATs in ~/.config/devbox/secrets.env, the GitHub App credentials, and ./bin/laptop-doctor as the acceptance test. Use this whenever someone is onboarding a new laptop or Mac, asks where a key, token or config file lives on the laptop, wants OMP on the laptop to stop using their identity, finds a private key on disk, sees commits Unverified on GitHub, gets a 1Password or op-ssh-sign prompt or failure, asks whether the laptop matches the devbox, or runs laptop-doctor and gets a WARN.
---

# devbox laptop

Laptop and devbox share one identity layout; every private half lives on the laptop, in 1Password, served
by its SSH agent. Everything on disk: public key, config, or token. `./bin/laptop-doctor` is the acceptance
test - run it, fix what it names, run again; its checks are the phases below.

Blocks, rationale: `docs/setup.md` (key, ssh config), `docs/git.md` (identities, agent override, signing).
Read the needed section, not retyped, so a changed default gets picked up, not reintroduced.

## Phase 1 - keys: 1Password items, public halves on disk

Five 1Password SSH Key items, each exported as one `.pub` file in `~/.ssh`:

| file                   | 1Password item       | used by                                                             |
|------------------------|----------------------|---------------------------------------------------------------------|
| `id_personal.pub`      | personal auth key    | `Host github.com`; GitHub *Authentication* key                      |
| `signing_personal.pub` | personal signing key | `~/.gitconfig` `user.signingkey`; GitHub *Signing* key              |
| `id_work.pub`       | work auth key     | `Host work.github.com`; work *Authentication* key             |
| `signing_work.pub`  | work signing key  | `~/.config/work/.gitconfig`; work *Signing* key               |
| `devbox.pub`           | Devbox Laptop        | `Host workstation`, `Host devbox`, `DEVBOX_EXTRA_AUTHORIZED_KEYS` |

Auth/signing are separate files: GitHub registers each separately, per account - signing with auth key
verifies locally, shows *Unverified* on GitHub.

Write a public half via the agent, never by generating one:

```bash
export SSH_AUTH_SOCK="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
ssh-add -l                                   # fingerprints + item names
ssh-add -L | grep <key-material-prefix> > ~/.ssh/<name>.pub
```

`ssh-keygen -t …` is wrong: it creates a private key on disk - exactly what this layout removes.
`laptop-doctor` reporting `private key(s) on disk`: delete if already a 1Password item, else import
(1Password → New item → SSH Key → import), then delete.

Same four GitHub public keys go into the workstation's `.env` as `GIT_*_PUBKEY`/`GIT_*_SIGNINGKEY` - see
`devbox-setup`, phase 5.

## Phase 2 - `~/.ssh/config`

`Host *` names the 1Password socket as `IdentityAgent`; each host block names one `.pub` as `IdentityFile`
with `IdentitiesOnly yes`, so ssh offers that key of six held. `Host devbox` sets `ForwardAgent no`
- herdr never carries the agent; only explicit `ssh -A devbox` does. Blocks verbatim:
`docs/setup.md#2-add-the-sshconfig-blocks`; GitHub blocks follow the pattern with `id_personal.pub`,
`id_work.pub`.

Check: `ssh -G devbox | grep -E 'identityfile|identitiesonly|identityagent'`, then
`ssh -T git@github.com` and `ssh -T git@work.github.com` must greet two different accounts.

## Phase 3 - gitconfigs

Commits sign through 1Password (`gpg.ssh.program = op-ssh-sign`), signing key named by file so laptop and
devbox read it alike:

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

Installs the devbox's bootstrap override, from `home/` templates: `omp-launcher`
(`~/.local/bin/omp` → `~/.local/libexec/devbox-agent/omp` → `omp-launcher`, symlinks at both hops), `gh`
shim, `devbox-git-credential`, `devbox-git-no-ssh`, `devbox-gh-token`,
`~/.config/devbox/agent*.gitconfig`. Every OMP session through a
shell after gets HTTPS remotes, per-operation tokens, a bot author, no signing, a `gh` with no stored login
- shell/IDE on same clones keep SSH remote, 1Password agent, signed commits. Re-run after `git pull`
touches `home/`; `laptop-doctor` reports drift from templates.

The launcher only covers what resolves `omp` via PATH - a herdr pane or alias naming the binary by
absolute path (`~/.bun/bin/omp`) bypasses it; use plain `omp`. Proof: `echo $GIT_CONFIG_GLOBAL` prints
`~/.config/devbox/agent.gitconfig`; empty means session predates install or bypassed launcher.

`omp update` is safe: the launcher drops its own PATH entries for that subcommand, so the updater replaces
the real install (bun/npm-managed here, `~/.local/bin/omp` on the devbox) and not the launcher. Before that
passthrough, an update wrote the release binary over the launcher and agent sessions silently fell back to
`~/.gitconfig` - SSH remotes, your keys. Re-run `./bin/install-agent` if a session ever reaches for a key;
the symlinks are what `laptop-doctor` checks.

## Phase 5 - what the override needs

- `~/.config/devbox/secrets.env` (mode 600, from `install-agent`): `GH_TOKEN_PERSONAL`, `GH_TOKEN_WORK` -
  fine-grained, `contents: write` on repos agents push to without the App, plus `actions`/`checks` read,
  `issues`/`pull-requests` write if agents should post. Used by the credential helper for App-less repos,
  by `gh` in agent sessions. Same file/variables as devbox; only PATs belong here - model keys come from
  OMP.
- `~/.config/work/work-app/app-id`, `app.pem` (mode 600): the credential helper mints a
  repo-scoped installation token per git op on a repo with the App, ahead of the PAT. Without them, work
  repos push with the PAT.

Check: `./bin/laptop-doctor` validates both tokens against GitHub, pem as a key;
`devbox-git-credential explain <owner>/<repo>` prints `app:<installation>` or `pat:<account>` for a repo.

## When `laptop-doctor` warns

| Warning                                           | Meaning and fix                                                                                         |
|---------------------------------------------------|---------------------------------------------------------------------------------------------------------|
| `private key(s) on disk`                          | Import to 1Password if missing, delete file (phase 1)                                                   |
| `<name>.pub … is not held by the 1Password agent` | Wrong export, or item disabled; re-export via `ssh-add -L`                                              |
| `1Password SSH agent not reachable`               | Agent off (1Password → Developer → SSH agent) or locked                                                 |
| `~/.ssh/config does not parse: … line N`          | Option-name typo; ssh clients (herdr included) die before the agent, 1Password never prompts            |
| `Host …: IdentityFile is …`                       | Names a private key path or wrong `.pub` (phase 2)                                                      |
| `Host devbox: ForwardAgent yes`                   | Remove it; forward via `ssh -A devbox` when needed                                                      |
| `user.signingkey is …`                            | Points at literal or auth key; use `signing_*.pub`                                                      |
| `omp resolves to …, not the launcher`             | `./bin/install-agent`; put `~/.local/bin` first on PATH                                                 |
| `… is not a symlink to …/omp-launcher`            | An `omp` release binary replaced a launcher symlink; `./bin/install-agent`, then `omp update` again     |
| `differ from the repo templates`                  | `./bin/install-agent` (templates changed since last install)                                            |
| `the keychain holds an agent token`               | Homebrew's `osxkeychain` preempted the helper; erase via `git credential-osxkeychain erase`, reinstall  |
| `no <account> token` / `token is rejected`        | Fill/re-issue the PAT in `secrets.env` (phase 5)                                                        |
| `ssh devbox failed`                               | 1Password locked, or Devbox Laptop key unapproved for this app                                          |
| `both aliases reach <login>`                      | `id_work.pub` is the personal key; re-export (phase 1)                                               |

herdr's saved-machine connections are background ssh over that agent - a machine flapping between
`connecting`/`offline` while 1Password is locked is that, not a devbox fault.

## What is deliberately not here

- No `op` for tokens: `secrets.env` is plaintext at mode 600 on both machines, by choice; an `op://`
  resolver branch is the documented next step if changed.
- No laptop-side `gh auth` change: your `gh` keeps its OAuth logins; only agent sessions see the login-less
  `GH_CONFIG_DIR` launcher exports.
- Nothing GitHub-facing is registered: it reuses these same public keys, already on both accounts.

## Where the details live

| Topic                                            | File                 |
|--------------------------------------------------|----------------------|
| Key item, ssh config, herdr, 1Password           | `docs/setup.md`      |
| Both git modes, launcher, helper, signing        | `docs/git.md`        |
| Tokens, App credentials, `secrets.env`           | `docs/secrets.md`    |
| `bin/install-agent`, `bin/laptop-doctor`         | `docs/cli.md`        |
| Workstation/container side of the same setup     | `devbox-setup` skill |
