load_push_env
host="${args[host]:-${DEVBOX_HOST:-}}"
[[ -n "${host}" ]] ||
  log_error "No host: pass one as an argument, export DEVBOX_HOST, or put DEVBOX_HOST=<ssh-alias> in ${REPO_ROOT}/.push.env"
remote_path="${DEVBOX_REMOTE_PATH}"

ssh "${host}" 'command -v rsync >/dev/null 2>&1' ||
  log_error "rsync is missing on ${host} - run: ssh ${host} 'sudo apt-get install -y rsync'"

log_info "Syncing ${REPO_ROOT}/ to ${host}:${remote_path}/..."
rsync -az --delete \
  --exclude '.git' \
  --exclude '.env' \
  --exclude 'data/' \
  --exclude '.DS_Store' \
  "${REPO_ROOT}/" "${host}:${remote_path}/"
log_success "Synced to ${host}:${remote_path}."

# Keeps `devbox` and its completion on the workstation's PATH; idempotent, and
# a failure there (a PATH line missing) is reported without stopping the deploy.
log_info "Installing the devbox command on ${host}..."
# shellcheck disable=SC2029 # remote_path is meant to expand locally
ssh "${host}" "${remote_path}/bin/devbox install" ||
  log_warn "devbox install on ${host} reported problems - see above"

if [[ -n "${args[--up]:-}" ]]; then
  force="${args[--force]:+ --force}"
  log_info "Bringing the devbox up on ${host}..."
  # -t so the container's session guard can prompt: an `up` that recreates the
  # container kills every live SSH session without telling the client.
  # shellcheck disable=SC2029 # remote_path and force are meant to expand locally
  ssh -t "${host}" "cd ${remote_path} && ./bin/devbox up${force}"
fi
