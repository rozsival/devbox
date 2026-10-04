compose() {
  (cd "${REPO_ROOT}" && docker compose "$@")
}

# Counts client connections to the container's sshd. Every recreate, stop or
# restart of the container kills them mid-keystroke with no message on the
# client - the disconnect that looks like "ssh devbox just closed" - so the
# destructive commands ask first.
ssh_sessions() {
  compose exec -T "${SERVICE}" \
    sh -c "ss -tnH state established '( sport = :2222 )' | wc -l" 2>/dev/null |
    tr -cd '0-9' || true
}

# `up` only drops sessions when compose decides to recreate; a no-op `up` is
# safe, so ask compose instead of guessing.
compose_would_recreate() {
  compose up -d --dry-run 2>&1 | grep -qE 'Recreate|Starting|Created'
}

# $1 describes the action; ${args[--force]} skips the prompt.
guard_ssh_sessions() {
  local action="$1" count
  count="$(ssh_sessions)"
  [[ -n "${count}" && "${count}" -gt 0 ]] || return 0

  log_warn "${count} SSH session(s) are connected to the devbox."
  log_warn "${action} kills them instantly and the client prints no reason."
  if [[ -n "${args[--force]:-}" ]]; then
    log_warn 'Continuing because --force was given.'
    return 0
  fi
  if [[ -t 0 ]]; then
    local reply
    read -rp "Continue anyway? [y/N] " reply
    [[ "${reply}" =~ ^[Yy]$ ]] || log_error 'Aborted.'
    return 0
  fi
  log_error 'Refusing to continue with live sessions - re-run with --force.'
}

tailscale_addr() {
  command -v tailscale >/dev/null 2>&1 || return 0
  tailscale ip -4 2>/dev/null | head -1 || true
}

preflight() {
  require_env_file
  command -v docker >/dev/null 2>&1 || log_error 'docker is not installed.'
  docker compose version >/dev/null 2>&1 || log_error 'docker compose v2 is not available.'

  local bind_addr data_dir host_uid host_gid owner_uid owner_gid
  bind_addr="$(env_get BIND_ADDR)"
  # Empty BIND_ADDR makes compose publish on 0.0.0.0, which would put the devbox
  # on the public internet. Failing here is the intended direction.
  [[ -n "${bind_addr}" ]] || log_error "BIND_ADDR is empty in ${ENV_FILE} - run './bin/devbox env' (Tailscale must be up)."

  data_dir="$(env_get DEVBOX_DATA_DIR)"
  [[ -n "${data_dir}" ]] || log_error "DEVBOX_DATA_DIR is empty in ${ENV_FILE}."
  [[ "${data_dir}" == /* ]] || log_error "DEVBOX_DATA_DIR must be an absolute path, got '${data_dir}'."

  host_uid="$(env_get HOST_UID)"
  host_gid="$(env_get HOST_GID)"

  if [[ ! -d "${data_dir}" ]]; then
    log_info "Creating ${data_dir} owned by ${host_uid}:${host_gid}..."
    install -d -m 755 -o "${host_uid}" -g "${host_gid}" "${data_dir}" 2>/dev/null ||
      log_error "Could not create ${data_dir} - run: sudo install -d -m 755 -o ${host_uid} -g ${host_gid} ${data_dir}"
  fi

  owner_uid="$(stat -c '%u' "${data_dir}")"
  owner_gid="$(stat -c '%g' "${data_dir}")"
  if [[ "${owner_uid}" != "${host_uid}" || "${owner_gid}" != "${host_gid}" ]]; then
    log_error "${data_dir} is owned by ${owner_uid}:${owner_gid}, expected ${host_uid}:${host_gid} - run: sudo chown -R ${host_uid}:${host_gid} ${data_dir}"
  fi

  # The project Docker daemon is optional infrastructure: a devbox with no
  # project containers is perfectly usable, so a missing socket warns rather
  # than blocking `up`. `docker` inside the container reports it precisely, and
  # `doctor` fails on it.
  local socket_dir
  socket_dir="$(env_get DEVBOX_DOCKER_SOCKET_DIR)"
  socket_dir="${socket_dir:-/run/devbox}"
  if [[ ! -S "${socket_dir}/docker.sock" ]]; then
    log_warn "No project Docker daemon at ${socket_dir}/docker.sock - 'docker' inside the devbox will not work."
    log_warn 'Provision it with: sudo ./bin/devbox docker setup'
  fi
}
