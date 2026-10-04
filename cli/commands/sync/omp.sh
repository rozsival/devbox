src="${OMP_CONFIG:-${HOME}/.omp/agent/config.yml}"
[[ -f "${src}" ]] || log_error "No OMP config at ${src}"
# The devbox's config.yml carries the bash.patterns guardrail bootstrap seeded
# (home/.omp/agent/config.yml). This sync replaces the whole file, so a laptop
# preset without that block would remove it there without a trace. Only the
# preset travels: agent.db, history.db, sessions, memories and models.yml are
# per-machine state.
if [[ -z "${args[--allow-unguarded]:-}" ]] && ! grep -qE '^bash:' "${src}"; then
  log_error "${src} has no bash: block - syncing it would drop the devbox's OMP guardrail. Copy the block from home/.omp/agent/config.yml into it first, or pass --allow-unguarded."
fi

host="$(devbox_ssh_host)"
sync_to_devbox "${host}" "${src}" .omp/agent/config.yml
log_success "OMP preset synced to ${host}."
log_info 'Restart any running OMP session there to pick it up.'
