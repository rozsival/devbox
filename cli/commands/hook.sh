require_env_file
require_moshi_hook
if [[ -n "${args[--update]:-}" ]]; then
  moshi_hook_update ||
    log_error 'moshi-hook update failed; the running daemon was left untouched.'
fi
moshi_hook_restart
