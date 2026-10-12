require_env_file
require_moshi_hook
# One failed updater must not cost the others their run, so each failure is
# counted and the exit status comes last. `omp` and `claude` resolve to the
# launchers in a login shell; both pass `update` through to the real install
# (docs/git.md). OMP goes before moshi-hook because moshi-hook rewrites the OMP
# extension it installs, and moshi-hook goes last because the daemon restart is
# the one step that aborts.
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

if moshi_hook_update; then
  moshi_hook_restart
else
  log_warn 'moshi-hook update failed; the running daemon was left untouched.'
  failures=$((failures + 1))
fi

((failures == 0)) || log_error "${failures} update(s) failed."
log_success 'OMP, Claude Code and moshi-hook are up to date.'
