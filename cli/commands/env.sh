if [[ ! -f "${ENV_FILE}" ]]; then
  [[ -f "${ENV_EXAMPLE}" ]] || log_error "Missing ${ENV_EXAMPLE}"
  log_info "Creating ${ENV_FILE} from .env.example..."
  cp "${ENV_EXAMPLE}" "${ENV_FILE}"
fi

# HOST_UID is the user that owns the bind mount *and* the rootless project
# Docker daemon, which is the dedicated `dev` account once
# `sudo ./bin/devbox docker setup` has run - not whoever is deploying.
owner_uid='' owner_gid=''
if getent passwd dev >/dev/null 2>&1; then
  owner_uid="$(id -u dev)"
  owner_gid="$(id -g dev)"
  log_info "Syncing HOST_UID and HOST_GID from the dev user (${owner_uid}:${owner_gid})..."
else
  owner_uid="$(id -u)"
  owner_gid="$(id -g)"
  log_info 'Syncing HOST_UID and HOST_GID from the current user...'
fi
upsert_env_key HOST_UID "${owner_uid}"
upsert_env_key HOST_GID "${owner_gid}"

# Resolved from Tailscale, not from a flag: this address is what scopes the
# published sshd port away from the public internet, and the node already owns
# exactly one correct value for it.
addr="$(tailscale_addr)"
if [[ -z "${addr}" ]]; then
  log_warn 'No Tailscale IPv4 address yet; BIND_ADDR left unset.'
  log_warn "Run 'sudo tailscale up', then './bin/devbox env' again - 'up' refuses to start without it."
else
  log_info "Syncing BIND_ADDR to ${addr}..."
  upsert_env_key BIND_ADDR "${addr}"
fi

log_success "Env vars ready in ${ENV_FILE}."
