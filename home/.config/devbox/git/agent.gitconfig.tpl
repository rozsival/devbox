# Template for the git configuration of an agent session. Rendered by
# devbox-identities (the @MARKER@ lines below are replaced with the blocks
# derived from ~/.config/devbox/identities.conf) and installed read-only as
# ~/.config/devbox/git/agent.gitconfig by container/bootstrap.sh and
# bin/install-agent. Edit this file in the repo, never the rendered one.
#
# The `omp` launcher in ~/.local/libexec/devbox-agent exports GIT_CONFIG_GLOBAL
# pointing at the rendered file, so every git the agent runs - and every tool
# that shells out to git: gh, wt, lazygit, OMP itself - reads it *instead of*
# ~/.gitconfig. Nothing else on the machine sees it: the same clone opened in an
# IDE or a plain shell keeps its SSH remote, the 1Password agent and the signing
# key. See docs/git.md.
#
# ~/.config/devbox/git/ is installed read-only (dir 500, files 444) because
# `git config --global` inside a session writes *here*: one such call replaced
# the author with the user's own name and email, and five commits carried it
# before anyone noticed. git needs to create a lock file beside the file it
# rewrites, so a directory without write permission turns that into an
# immediate "could not lock config file" instead of silent drift.
#
# Self-contained on purpose. ~/.gitconfig carries SSH `insteadOf` rewrites for
# the same prefixes as below (`gh:`), and when two rewrites tie on length git
# keeps the first one it read - so including that file would let an SSH rewrite
# win over the HTTPS one. Its per-tree and per-org includes would also hand an
# agent your own author, signing key and ssh tag.

# The author of every agent commit, outside the trees the includes at the end
# claim. Not an account: the pusher is a fine-grained PAT or an App installation
# token, the author is visibly not you.
@DEFAULT_AUTHOR@

# Unsigned: the signing keys are yours, and never within an agent's reach.
[commit]
	gpgsign = false
[tag]
	gpgsign = false

# Every forge remote goes over HTTPS whatever URL the clone was made with, and
# the helper mints a token per operation: a repository-scoped GitHub App
# installation token where an App is installed, a fine-grained PAT elsewhere.
# The user-less `<host>:` forms are what an `ssh` config with `User git` lets a
# clone get away with; `gh:` is the personal ~/.gitconfig shorthand.
#
# The empty helper entry resets the list inherited from the system config
# (osxkeychain on macOS, gh's own helper if it was ever configured): an agent
# must never reach a credential stored for you. Any other HTTPS remote is
# therefore left without a helper and fails - GIT_TERMINAL_PROMPT=0 in the
# launcher turns that into an immediate error rather than a hung prompt.
# `!` runs the value as a shell command found on the PATH the launcher set; a
# bare name would be looked up as `git credential-<name>`, and an absolute path
# would tie this file to one machine's home directory.
[credential]
	helper =
@URL_REWRITES@

[init]
	defaultBranch = main
[pull]
	rebase = true
	ff = only
[push]
	default = simple
	followTags = true
[filter "lfs"]
	clean = git-lfs clean -- %f
	smudge = git-lfs smudge -- %f
	process = git-lfs filter-process
	required = true

# Same directory rule as ~/.gitconfig: a tree with its own agent author gets it
# here. Must stay after the [user] block above - later wins. Relative paths: git
# resolves them against this file's own directory, so the set moves together.
@INCLUDES@
