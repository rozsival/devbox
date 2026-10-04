# The devbox's SSH host for `sync`: the argument, then DEVBOX_SSH_HOST (env or
# .push.env), then `devbox`. This is the container's sshd (port 2223), not the
# workstation's, so whatever is copied lands in /home/dev on the bind mount.
devbox_ssh_host() {
  load_push_env
  printf '%s' "${args[host]:-${DEVBOX_SSH_HOST:-devbox}}"
}

# Copies one laptop file to the same path under the devbox's home, keeping the
# previous copy as <file>.bak there.
# $1 host, $2 source file, $3 destination relative to the remote home.
sync_to_devbox() {
  local host="$1" src="$2" dest="$3"
  log_info "Backing up the current ~/${dest} on ${host}..."
  # shellcheck disable=SC2029 # dest is meant to expand locally
  ssh "${host}" "
    set -eu
    mkdir -p ~/$(dirname "${dest}")
    [ -f ~/${dest} ] && cp -p ~/${dest} ~/${dest}.bak
    exit 0
  "
  log_info "Syncing ${src} to ${host}:~/${dest}..."
  rsync -az "${src}" "${host}:${dest}"
}
