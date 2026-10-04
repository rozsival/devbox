preflight
# Build before asking compose what it would do: a fresh image is itself a
# reason to recreate, and the build touches no running container.
compose build
if compose_would_recreate; then
  guard_ssh_sessions 'Recreating the container'
fi
compose up -d
log_success "devbox is up on $(env_get BIND_ADDR):$(env_get DEVBOX_SSH_PORT)."
