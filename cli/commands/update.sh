require_env_file
require_moshi_hook
# One failed updater must not cost the others their run, so each failure is
# counted and the exit status comes last. `omp`, `claude` and `codex` resolve to
# the launchers in a login shell; all three pass `update` through to the real
# install (docs/git.md). The agents go first because `moshi-hook install`
# rewrites hooks into their configs; that install runs whether or not
# `moshi-hook update` succeeded, since the current binary can still repair the
# hooks. The daemon restart goes last because it is the one step that aborts,
# and is skipped after a failed update so the old daemon keeps serving.
failures=0

log_info 'Updating OMP...'
if ! compose exec -T "${SERVICE}" bash -lc 'omp update'; then
  log_warn 'omp update failed.'
  failures=$((failures + 1))
fi

log_info 'Updating Claude Code...'
if ! compose exec -T "${SERVICE}" bash -lc 'claude update'; then
  log_warn 'claude update failed.'
  failures=$((failures + 1))
fi

log_info 'Updating Codex...'
if ! compose exec -T "${SERVICE}" bash -lc 'codex update'; then
  log_warn 'codex update failed.'
  failures=$((failures + 1))
fi

moshi_hook_updated=true
if ! moshi_hook_update; then
  log_warn 'moshi-hook update failed; the running daemon will be left untouched.'
  moshi_hook_updated=false
  failures=$((failures + 1))
fi

if ! moshi_hook_install; then
  log_warn 'moshi-hook install failed; agent events may be stale.'
  failures=$((failures + 1))
fi

if ${moshi_hook_updated}; then
  moshi_hook_restart
fi

((failures == 0)) || log_error "${failures} update(s) failed."
log_success 'OMP, Claude Code, Codex and moshi-hook are up to date.'
