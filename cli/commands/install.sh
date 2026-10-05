link="$(devbox_link)"
target="$(devbox_target)"
file="$(devbox_completion_file)"

# Only ever replaces a symlink: a real file there is someone else's `devbox`.
if [[ -e ${link} && ! -L ${link} ]]; then
  log_error "${link} exists and is not a symlink - move it aside, then re-run"
fi
if [[ "$(readlink "${link}" 2>/dev/null)" != "${target}" ]]; then
  install -d -m 755 "${BIN_DIR}"
  ln -sfn "${target}" "${link}"
  log_info "linked ${link} -> ${target}"
fi

if [[ ! -f ${file} ]] || ! cmp -s "${file}" <(devbox_completion_script); then
  install -d -m 755 "${file%/*}"
  devbox_completion_script >"${file}.$$"
  mv "${file}.$$" "${file}"
  log_info "wrote ${file}"
fi

devbox_command_checks
finish_checks
