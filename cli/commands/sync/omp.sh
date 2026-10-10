src="${OMP_CONFIG:-${TEMPLATE_DIR}/.omp/agent/config.yml}"
[[ -f "${src}" ]] || log_error "No OMP config at ${src}"
# Both config.yml files carry the bash.patterns guardrail their installers
# seeded (home/.omp/agent/config.yml). This sync replaces each whole file, so a
# preset without that block would remove it without a trace. Only the preset
# travels: agent.db, history.db, sessions, memories and models.yml are
# per-machine state.
if [[ -z "${args['--allow-unguarded']:-}" ]] && ! grep -qE '^bash:' "${src}"; then
  log_error "${src} has no bash: block - syncing it would drop the OMP guardrail. Copy the block from home/.omp/agent/config.yml into it first, or pass --allow-unguarded."
fi

# The laptop first, so a failed devbox copy still leaves this machine current.
# OMP owns the live file and may hold a change made in it that never reached
# the preset: keep the replaced copy as config.yml.bak, like the devbox side.
live="${HOME}/.omp/agent/config.yml"
if [[ ! -e "${live}" ]]; then
  install -d -m 755 "${live%/*}"
  install -m 600 "${src}" "${live}"
  log_success "OMP preset installed at ${live}."
elif [[ "$(readlink -f "${src}")" == "$(readlink -f "${live}")" ]] || cmp -s "${src}" "${live}"; then
  log_info "${live} already matches."
else
  cp -p "${live}" "${live}.bak"
  cp "${src}" "${live}"
  log_success "OMP preset applied to ${live} (previous copy: ${live}.bak)."
fi

host="$(devbox_ssh_host)"
sync_to_devbox "${host}" "${src}" .omp/agent/config.yml
log_success "OMP preset synced to ${host}."
log_info 'Restart any running OMP session on either machine to pick it up.'
