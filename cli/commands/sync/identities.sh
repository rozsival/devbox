src="${DEVBOX_IDENTITIES:-${HOME}/.config/devbox/identities.conf}"
[[ -f "${src}" ]] || log_error "No identity registry at ${src} - run ./bin/devbox agent install, then fill it in"

# Locally first: a registry that does not validate must not be the one the
# devbox boots from, and the same reader runs on both sides. Nothing secret
# travels - the file holds names, emails, *public* keys and paths.
DEVBOX_IDENTITIES_FILE="${src}" "${TEMPLATE_DIR}/.local/libexec/devbox-identities" check ||
  log_error "${src} is not usable; fix it before syncing"

host="$(devbox_ssh_host)"
sync_to_devbox "${host}" "${src}" .config/devbox/identities.conf

# Applying it is bootstrap's job, and bootstrap is idempotent: re-running it is
# how the generated files (ssh config, gitconfig includes, allowed_signers, the
# agent gitconfigs) catch up with the file that just landed.
log_info 'Re-running bootstrap in the container...'
if ssh "${host}" 'bash /opt/devbox/container/bootstrap.sh'; then
  log_success "Identity registry synced and applied on ${host}."
else
  log_error "Registry copied, but bootstrap failed on ${host} - run './bin/devbox bootstrap' on the workstation and read its output."
fi
