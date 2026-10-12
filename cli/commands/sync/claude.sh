src="${CLAUDE_SETTINGS:-${TEMPLATE_DIR}/.claude/settings.json}"
[[ -f "${src}" ]] || log_error "No Claude Code preset at ${src}"
jq -e 'type == "object"' "${src}" >/dev/null 2>&1 || log_error "${src} is not a JSON object"

# The laptop first, so a failed devbox copy still leaves this machine current.
# Merged, not copied (cli/lib/claude_settings.sh): the hooks moshi-hook and the
# IDE integrations wrote stay.
live="${HOME}/.claude/settings.json"
case "$(claude_settings_apply "${src}" "${live}")" in
created) log_success "Claude Code preset installed at ${live}." ;;
unchanged) log_info "${live} already holds the preset." ;;
updated) log_success "Claude Code preset merged into ${live} (previous copy: ${live}.bak)." ;;
*) log_error "${live} is not valid JSON - fix it, then re-run." ;;
esac

# The devbox's file is merged here too, so the container needs nothing but
# ssh: fetch it, merge, and let sync_to_devbox keep the .bak and copy it back.
host="$(devbox_ssh_host)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
log_info "Fetching ~/.claude/settings.json from ${host}..."
ssh "${host}" 'if [ -f ~/.claude/settings.json ]; then cat ~/.claude/settings.json; fi' >"${tmp}/remote.json" ||
  log_error "Could not read ~/.claude/settings.json on ${host}"
[[ -s "${tmp}/remote.json" ]] || rm -f "${tmp}/remote.json"
claude_settings_merge "${src}" "${tmp}/remote.json" "${tmp}/settings.json" ||
  log_error "${host}:~/.claude/settings.json is not valid JSON - fix it there, then re-run."
if [[ -f "${tmp}/remote.json" ]] &&
  jq -en --slurpfile a "${tmp}/remote.json" --slurpfile b "${tmp}/settings.json" '$a == $b' >/dev/null; then
  log_info "${host}:~/.claude/settings.json already holds the preset."
else
  chmod 644 "${tmp}/settings.json"
  sync_to_devbox "${host}" "${tmp}/settings.json" .claude/settings.json
  log_success "Claude Code preset merged into ${host}:~/.claude/settings.json."
fi
log_info 'Restart any running Claude Code session on either machine to pick it up.'
