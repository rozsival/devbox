# Runtime environment: the devbox

<!-- Generated from the devbox repo (home/.config/devbox/agent-context/devbox.md); edit it there, not here. -->

You run inside the **devbox**: an unprivileged Docker container on a remote Ubuntu workstation that the user reaches
over SSH from a macOS laptop. Confirm with `echo $DEVBOX_ENV`: it prints `devbox` in a session started through the
launcher. If it is empty, git and `gh` are not fenced: stop and tell the user before any git push or `gh` write.

- **System:** Ubuntu 26.04, GNU userland, user `dev`, home `/home/dev`, projects under `~/projects`. There is no root
  and no `sudo`, so `apt-get install` is impossible. To add a missing tool, propose a change to the devbox repo's
  `Dockerfile` and don't hunt for a workaround. Per-user installs into `~/.local` work (`npm i -g --prefix ~/.local`,
  `cargo install --root ~/.local`). `/tmp` is a `noexec` tmpfs that a container restart clears: run scripts there with
  `bash <file>`, or put executables under `$HOME`.
- **Reach:** the project tree, the internet, and the project Docker daemon. You can't reach the workstation's
  filesystem, its root Docker daemon, its own services or other Tailnet machines. The user's laptop is a different
  machine: its paths don't exist here.
- **Docker:** `docker` talks to a separate rootless daemon. Bind-mount sources must be under `/home/dev`. A port
  published as `127.0.0.1:…` is unreachable; publish on the default address, then reach it at
  `host.docker.internal:<port>`, or run `devbox-ports` to mirror it onto `localhost`.
- **Ports for the user:** dev servers stay inside the container. Tell the user the tunnel to run on their laptop:
  `ssh -N -L <port>:localhost:<port> devbox`.
- **Git and GitHub:** git runs over HTTPS with per-repo GitHub App tokens. Remotes may stay SSH URLs, because the agent
  gitconfig rewrites them to HTTPS, so never change a remote URL. SSH itself is fenced and there are no private keys
  here. Commits use the bot author and are unsigned. Never run `gh auth login`, and don't change the git identity.
  Run git and `gh` from the shell tool: a 403 "Resource not accessible by personal access token" or "Could not resolve
  to a Repository" means a call ran outside the fence, not that a permission is missing (the `devbox-runtime` skill has
  the check).
- **Secrets:** there is no 1Password (`op`) and no `gcloud`. A file that a vault renders (such as `.env.local` from
  `op inject`) has to be generated on the laptop and copied in: ask the user.

For how-tos (Docker patterns, ports, missing tools, auth failures), read the `devbox-runtime` skill.
