require_env_file
guard_ssh_sessions 'Stopping the container'
compose down
log_success 'devbox is down.'
