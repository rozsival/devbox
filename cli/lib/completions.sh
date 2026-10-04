# Completion candidates for the [host] arguments of deploy and sync: every
# concrete `Host` alias in ~/.ssh/config and the files it `Include`s, wildcard
# and negated patterns skipped. Runs on every <TAB>, so it only reads files.
# Words are split with `read -a`, never by unquoted expansion: `Host *` would
# otherwise glob into the current directory's file names.
completion_ssh_hosts() {
  local config="${HOME}/.ssh/config" file pattern word
  local -a files=("${config}") words
  [[ -r ${config} ]] || return 0

  # One level of Include, relative paths resolved against ~/.ssh as ssh does;
  # these are the only words meant to glob.
  while read -ra words; do
    [[ ${words[0],,} == include ]] || continue
    for pattern in "${words[@]:1}"; do
      pattern="${pattern/#\~/${HOME}}"
      [[ ${pattern} == /* ]] || pattern="${HOME}/.ssh/${pattern}"
      for file in ${pattern}; do
        [[ -r ${file} ]] && files+=("${file}")
      done
    done
  done <"${config}"

  for file in "${files[@]}"; do
    while read -ra words; do
      [[ ${words[0],,} == host ]] || continue
      for word in "${words[@]:1}"; do
        [[ ${word} == *[\*\?\!]* ]] || printf '%s\n' "${word}"
      done
    done <"${file}"
  done
}
