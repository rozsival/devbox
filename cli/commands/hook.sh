require_env_file
if ! compose exec -T "${SERVICE}" bash -lc 'command -v moshi-hook >/dev/null 2>&1'; then
  log_error "moshi-hook is not installed - run './bin/devbox bootstrap'."
fi
# The update runs before the old daemon is touched, so a failed one aborts
# with that daemon still serving instead of restarting into nothing. The OMP
# extension and the Claude Code hooks are regenerated for the same reason
# bootstrap §15 does it: the binary writes them, and stale ones are the
# daemon's "agent hooks missing or stale" warning.
if [[ -n "${args[--update]:-}" ]]; then
  log_info 'Updating moshi-hook...'
  compose exec -T "${SERVICE}" bash -lc 'moshi-hook update' ||
    log_error 'moshi-hook update failed; the running daemon was left untouched.'
  compose exec -T "${SERVICE}" bash -lc 'moshi-hook install --target omp,claude >/dev/null' ||
    log_warn 'moshi-hook install --target omp,claude failed; agent events may be stale.'
fi
# A detached `exec`, never a container recreate: the daemon has to be
# restartable after `moshi-hook pair` without taking live SSH sessions down
# with it.
#
# The pattern matches the *serve invocation*, not the command name. Two
# reasons: the binary ships a `moshi` alias symlink, and the daemon found
# running here was `moshi serve`, which `pgrep -x moshi-hook` cannot see -
# so `hook` killed nothing and then failed on the lock that daemon held.
# Matching comm `moshi` instead would be worse: it would also kill a user's
# `moshi-hook pair`, `moshi <dir>` or `moshi diff` running in a pane, and
# make `doctor` count one as the daemon.
#
# The wait is load-bearing. `pkill` returns as soon as the signal is queued,
# while the lock and the gateway socket on 127.0.0.1:24543 are released only
# once the old process actually exits - and `serve` refuses to start against
# either, so starting too early produces a silent no-daemon.
# shellcheck disable=SC2016 # the script body must expand inside the container
compose exec -T "${SERVICE}" bash -c '
  pattern="(^|/)(moshi|moshi-hook) serve( |$)"
  pkill -f "${pattern}" >/dev/null 2>&1 || exit 0
  for _ in $(seq 50); do
    pgrep -f "${pattern}" >/dev/null 2>&1 || exit 0
    sleep 0.1
  done
  exit 1
' || log_error 'The running moshi-hook did not exit; refusing to start a second one.'

compose exec -d "${SERVICE}" bash -lc 'exec moshi-hook serve'
sleep 1
if ! compose exec -T "${SERVICE}" pgrep -f '(^|/)(moshi|moshi-hook) serve( |$)' >/dev/null 2>&1; then
  compose exec -T "${SERVICE}" bash -lc \
    'tail -5 ~/.local/state/moshi/serve.err ~/.local/state/moshi/hook.log' 2>/dev/null || true
  log_error 'moshi-hook did not stay up - see the output above.'
fi
compose exec -T "${SERVICE}" bash -lc 'moshi-hook status' || true
log_success 'moshi-hook daemon restarted.'
