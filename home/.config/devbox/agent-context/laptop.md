# Runtime environment: the laptop

<!-- Generated from the devbox repo (home/.config/devbox/agent-context/laptop.md); edit it there, not here. -->

You run on the user's **macOS laptop**, not inside the devbox. The devbox is a separate Docker container on a remote
Ubuntu workstation. Confirm with `echo $DEVBOX_ENV`: it prints `laptop` in a session started through the launcher, and
in a Claude desktop app session through its `SessionStart` hook. If it is empty, git and `gh` are not fenced: stop and
tell the user before any git push or `gh` write.

- **System:** macOS with a BSD userland. `sed -i`, `stat`, `date`, `readlink` and `grep -P` differ from GNU, so check
  the flags or use the GNU tools Homebrew installed. Use Homebrew for packages. This is the user's own machine: their
  own files, keys and accounts are here, so ask before installing or changing system-wide things.
- **The devbox is elsewhere:** its `~/projects` is a different tree from this one. Don't assume a path, a running
  server or a Docker container on one side exists on the other. `ssh devbox` makes 1Password prompt the user, so use
  it only when the user asks.
- **Git and GitHub:** the same fence as on the devbox. git runs over HTTPS with per-repo GitHub App tokens, and SSH
  remote URLs are rewritten to HTTPS, so never change a remote URL; the user's own work uses it. Commits use the bot
  author and are unsigned. `gh` gets a scoped token, never the user's own login. Run git and `gh` from the shell tool:
  on a 403 "Resource not accessible by personal access token" or "Could not resolve to a Repository", first suspect a
  call outside the fence; `devbox-git-credential explain <owner>/<repo>` tells which (the `devbox-runtime` skill).
  Never run `gh auth login`, read the keychain, or run `op`. The user's 1Password and personal credentials are off
  limits even though they are on this machine.
- **Docker and ports:** whatever the user runs locally. `localhost` is the laptop itself, not the devbox.

For how-tos (what lives where, moving work between machines, auth failures), read the `devbox-runtime` skill.
