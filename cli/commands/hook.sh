require_env_file
require_moshi_hook
if [[ -n "${args[--update]:-}" ]]; then
  moshi_hook_update ||
    log_error 'moshi-hook update failed; the running daemon was left untouched.'
  moshi_hook_install ||
    log_warn 'moshi-hook install failed; agent events may be stale.'
fi
moshi_hook_restart
