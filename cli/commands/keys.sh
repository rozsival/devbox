require_env_file
if compose exec -T "${SERVICE}" true >/dev/null 2>&1; then
  log_info 'Reading identities.conf from the container (its authoritative copy).'
  # shellcheck disable=SC2016 # the script body must expand inside the container
  compose exec -T "${SERVICE}" bash -c '
    set -e
    . "$HOME/.local/libexec/devbox-identities"
    for slug in $(di_slugs); do
      printf "%-12s ssh tag %s, orgs %s\n" "$slug" "$(di_get "$slug" tag)" "$(di_get "$slug" orgs | tr "\n" " ")"
      for kind in id signing; do
        if [[ "$kind" == signing ]]; then field=signing_pubkey; else field=pubkey; fi
        file="$HOME/.ssh/${kind}_${slug}.pub"
        if [[ -f "$file" ]]; then
          printf "%-12s %-8s %s\n" "" "$kind" "$(cat "$file")"
        else
          printf "%-12s %-8s %s\n" "" "$kind" "(not set - $field for [$slug] in ~/.config/devbox/identities.conf)"
        fi
      done
    done
    echo
    echo "sshd host key fingerprint:"
    ssh-keygen -lf "$HOME/.ssh/host/ssh_host_ed25519_key.pub"
  '
else
  local reader data_dir identities_file slug field kind file
  reader="${REPO_ROOT}/home/.local/libexec/devbox-identities"
  data_dir="$(env_get DEVBOX_DATA_DIR)"
  identities_file="${data_dir}/.config/devbox/identities.conf"
  log_warn "Container not reachable; reading ${identities_file} directly."
  for slug in $(DEVBOX_IDENTITIES_FILE="${identities_file}" "${reader}" list); do
    printf '%-12s ssh tag %s, orgs %s\n' "${slug}" \
      "$(DEVBOX_IDENTITIES_FILE="${identities_file}" "${reader}" get "${slug}" tag)" \
      "$(DEVBOX_IDENTITIES_FILE="${identities_file}" "${reader}" get "${slug}" orgs | tr '\n' ' ')"
    for kind in id signing; do
      if [[ "${kind}" == signing ]]; then field=signing_pubkey; else field=pubkey; fi
      file="${data_dir}/.ssh/${kind}_${slug}.pub"
      if [[ -f "${file}" ]]; then
        printf '%-12s %-8s %s\n' '' "${kind}" "$(cat "${file}")"
      else
        printf '%-12s %-8s %s\n' '' "${kind}" "(not set - ${field} for [${slug}] in ~/.config/devbox/identities.conf)"
      fi
    done
  done
  echo
  if [[ -f "${data_dir}/.ssh/host/ssh_host_ed25519_key.pub" ]]; then
    echo 'sshd host key fingerprint:'
    ssh-keygen -lf "${data_dir}/.ssh/host/ssh_host_ed25519_key.pub"
  else
    log_warn 'sshd host key not found on the bind mount.'
  fi
fi
echo
log_info "These are the laptop's own keys; nothing needs pasting anywhere."
