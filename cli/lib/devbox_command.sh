# `devbox` by name, on both machines: a symlink in ~/.local/bin onto this
# checkout's bin/devbox, plus bash completion where bash-completion's lazy
# loader looks for it (~/.local/share/bash-completion/completions/<command>),
# so it costs nothing until the first <TAB> after `devbox`.

devbox_link() { printf '%s\n' "${BIN_DIR}/devbox"; }
devbox_target() { printf '%s\n' "${REPO_ROOT}/bin/devbox"; }
devbox_completion_file() {
  printf '%s\n' "${XDG_DATA_HOME:-${HOME}/.local/share}/bash-completion/completions/devbox"
}

# The completion file's exact content. The bashly script only forwards each
# <TAB> to `devbox __complete`, so it holds no command list and a re-run is
# needed only when bashly's own completion function changes.
devbox_completion_script() {
  # shellcheck disable=SC2016 # literal backticks
  printf '# Written by `devbox install` from `devbox completions bash`: re-run it, never edit.\n'
  send_completions bash
}

# How a fresh login shell sees `devbox` - what a new herdr pane, `ssh` session
# or terminal tab gets, independent of the PATH this process inherited (a
# non-interactive `ssh host cmd`, as `deploy` runs `install`, has neither
# ~/.local/bin nor bash-completion). Prints `path=<resolved>` and, for a bash
# login shell, `loader=yes` when bash-completion's lazy loader is defined.
devbox_fresh_shell() {
  local shell="${SHELL:-/bin/bash}"
  # shellcheck disable=SC2016 # expands in the probed shell
  env -i HOME="${HOME}" USER="${USER:-}" LOGNAME="${LOGNAME:-${USER:-}}" SHELL="${shell}" TERM=dumb \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin "${shell}" -lic \
    'printf "path=%s\n" "$(command -v devbox)"
     [ -n "${BASH_VERSION:-}" ] && declare -F _comp_load __load_completion >/dev/null && echo loader=yes
     exit 0' </dev/null 2>/dev/null || true
}

# The bash-completion setup this side needs, for the hints below.
devbox_completion_hint() {
  if on_laptop; then
    # shellcheck disable=SC2016 # a command for the user to run
    echo 'brew install bash-completion@2, then source "$(brew --prefix)/etc/profile.d/bash_completion.sh" from ~/.bashrc'
  else
    echo 'sudo apt-get install -y bash-completion, then source /usr/share/bash-completion/bash_completion from ~/.bashrc (Ubuntu'"'"'s default ~/.bashrc does)'
  fi
}

# Reports through `fail`, so `install` and both doctors share one definition
# of "installed".
devbox_command_checks() {
  local link target file probe resolved
  link="$(devbox_link)"
  target="$(devbox_target)"
  file="$(devbox_completion_file)"

  if [[ -L ${link} && "$(readlink "${link}")" == "${target}" ]]; then
    log_success "${link} -> ${target}"
  else
    fail "${link} is not a symlink onto ${target} - run ${target} install"
  fi

  if [[ -f ${file} ]] && cmp -s "${file}" <(devbox_completion_script); then
    log_success "bash completion at ${file}"
  else
    fail "bash completion at ${file} missing or stale - run ${target} install"
  fi

  probe="$(devbox_fresh_shell)"
  resolved="$(sed -n 's/^path=//p' <<<"${probe}")"
  if [[ ${resolved} == "${link}" ]]; then
    log_success "a login shell (${SHELL:-/bin/bash}) resolves devbox to ${link}"
  elif [[ -z ${resolved} ]]; then
    # shellcheck disable=SC2016 # literal $HOME/$PATH in the hint
    fail "a login shell (${SHELL:-/bin/bash}) does not find devbox - add ~/.local/bin to its PATH: export PATH=\"\$HOME/.local/bin:\$PATH\""
  else
    fail "a login shell resolves devbox to ${resolved}, ahead of ${link} - remove it or put ~/.local/bin first on the PATH"
  fi

  if [[ ${SHELL:-/bin/bash} != */bash ]]; then
    log_info "login shell ${SHELL} is not bash: completion is installed for bash only - for zsh, put 'source <(devbox completions zsh)' in ~/.zshrc after compinit"
  elif grep -qx 'loader=yes' <<<"${probe}"; then
    log_success 'a login shell loads bash-completion, which lazy-loads devbox completion'
  else
    fail "a login shell does not load bash-completion, so devbox completion never loads - $(devbox_completion_hint)"
  fi
}
