# GNU rsync only. macOS ships openrsync as /usr/bin/rsync, which accepts the
# protect rules below and then ignores them: under --delete-excluded it deletes
# the workstation's .env, data/ and .git.
[[ "$(rsync --version 2>&1)" =~ ^rsync\ +version\ [3-9] ]] ||
  log_error "$(command -v rsync) is not GNU rsync (macOS ships openrsync) - run: brew install rsync, and put Homebrew's bin ahead of /usr/bin on the PATH"

load_push_env
host="${args[host]:-${DEVBOX_HOST:-}}"
[[ -n "${host}" ]] ||
  log_error "No host: pass one as an argument, export DEVBOX_HOST, or put DEVBOX_HOST=<ssh-alias> in ${REPO_ROOT}/.push.env"
remote_path="${DEVBOX_REMOTE_PATH}"

ssh "${host}" 'command -v rsync >/dev/null 2>&1' ||
  log_error "rsync is missing on ${host} - run: ssh ${host} 'sudo apt-get install -y rsync'"

# An allowlist, not a blocklist: the workstation needs only what builds and
# runs the container plus the CLI driving it. Docs, agent skills, IDE and
# formatter configs stay on the laptop, and a new dev file stays there by
# default. --delete-excluded also removes anything outside the list left by an
# older deploy; the protect rules keep the host's own state, which no deploy
# ever writes.
filters=(
  --filter 'P /.env'
  --filter 'P /data/'
  --filter 'P /docker-compose.override.yml'
  --filter 'P /.git/'
  --exclude '.DS_Store'
  --include '/bin/***'
  --include '/container/***'
  --include '/home/***'
  --include '/Dockerfile'
  --include '/docker-compose.yml'
  --include '/.env.example'
  --exclude '*'
)

log_info "Syncing the runtime files of ${REPO_ROOT}/ to ${host}:${remote_path}/..."
rsync -az --delete --delete-excluded "${filters[@]}" "${REPO_ROOT}/" "${host}:${remote_path}/"
log_success "Synced to ${host}:${remote_path}."

# Keeps `devbox` and its completion on the workstation's PATH; idempotent, and
# a failure there (a PATH line missing) is reported without stopping the deploy.
log_info "Installing the devbox command on ${host}..."
# shellcheck disable=SC2029 # remote_path is meant to expand locally
ssh "${host}" "${remote_path}/bin/devbox install" ||
  log_warn "devbox install on ${host} reported problems - see above"

if [[ -n "${args[--start]:-}" ]]; then
  force="${args[--force]:+ --force}"
  log_info "Starting the devbox on ${host}..."
  # -t so the container's session guard can prompt: a `start` that recreates
  # the container kills every live SSH session without telling the client.
  # shellcheck disable=SC2029 # remote_path and force are meant to expand locally
  ssh -t "${host}" "cd ${remote_path} && ./bin/devbox start${force}"
fi
