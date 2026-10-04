preflight
guard_ssh_sessions 'Rebuilding the container'
compose build --no-cache
compose up -d
log_success 'devbox rebuilt.'
