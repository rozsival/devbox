src="${HOME}/.config/devbox/profile.json"
[[ -f "${src}" ]] ||
  log_error "No profile at ${src} - cp ${TEMPLATE_DIR}/.config/devbox/profile.json.example ${src}, then fill it in"

# Validated before anything is written: a profile that does not validate is
# skipped by agent-context on both machines, so syncing it would only spread it.
agent_context="${REPO_ROOT}/container/agent-context"
problem="$("${BASH}" "${agent_context}" validate-profile "${src}")" ||
  log_error "${problem} - fix it before syncing"

# The laptop first, so a failed devbox copy still leaves this machine current.
out="$("${BASH}" "${agent_context}" apply laptop "${TEMPLATE_DIR}" 2>&1)" ||
  log_error "Rendering the laptop's agent context failed: ${out}"
[[ -z "${out}" ]] || while IFS= read -r line; do log_success "${line}"; done <<<"${out}"

host="$(devbox_ssh_host)"
sync_to_devbox "${host}" "${src}" .config/devbox/profile.json

# Only the agent context depends on the profile, so this re-renders that one
# file rather than re-running all of bootstrap.
log_info "Rendering the agent context on ${host}..."
if out="$(ssh "${host}" 'bash /opt/devbox/container/agent-context apply devbox /opt/devbox/home' 2>&1)"; then
  [[ -z "${out}" ]] || while IFS= read -r line; do log_success "${host}: ${line}"; done <<<"${out}"
  log_success "Profile synced to ${host}; new agent sessions on either machine read it."
else
  log_error "Profile copied, but rendering failed on ${host}: ${out}"
fi
