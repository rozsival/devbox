# The Claude Code preset, home/.claude/settings.json, is merged into a live
# ~/.claude/settings.json, never copied over it the way `sync omp` copies
# config.yml: that file has other writers - moshi-hook and IDE integrations add
# `hooks` and `statusLine`, Claude itself `/model` and `/permissions` - and a
# copy would drop them. jq's `*` keeps every key the preset does not set and
# takes the preset's value for every key it does; arrays (the permission rules)
# are replaced whole, so a rule removed from the preset disappears too.

# $1 preset, $2 live file (absent counts as {}), $3 output file.
claude_settings_merge() {
  local preset="$1" live="$2" out="$3"
  if [[ -f ${live} ]]; then
    jq -s '.[0] * .[1]' "${live}" "${preset}" >"${out}"
  else
    jq '.' "${preset}" >"${out}"
  fi
}

# Applies the preset to a file on this machine. Prints `unchanged` when the live
# file already holds every preset value, else `updated` (previous copy kept as
# <file>.bak) or `created`; fails without touching the file when either side is
# not valid JSON.
# $1 preset, $2 live file.
claude_settings_apply() {
  local preset="$1" live="$2" merged
  install -d -m 755 "${live%/*}"
  merged="$(mktemp "${live}.XXXXXX")"
  if ! claude_settings_merge "${preset}" "${live}" "${merged}"; then
    rm -f "${merged}"
    return 1
  fi
  claude_settings_replace "${live}" "${merged}"
}

# The SessionStart hook that fences sessions no launcher started (the desktop
# app, see home/.local/libexec/devbox-agent/claude-session-env). Not part of
# the preset: .hooks.SessionStart already holds herdr's, moshi-hook's and IDE
# entries, and the preset merge replaces arrays whole. Appended when no entry
# runs <command> yet, nothing else touched. Prints and fails as
# claude_settings_apply; with <keep bak> set, an existing <live>.bak is left
# as is (a step earlier in the same run already saved the user's original).
# $1 live file (absent counts as {}), $2 hook command, $3 keep bak (optional).
claude_session_hook_apply() {
  local live="$1" command="$2" keep_bak="${3:-}" merged
  install -d -m 755 "${live%/*}"
  merged="$(mktemp "${live}.XXXXXX")"
  # Spelled out rather than `.hooks.SessionStart += [...]`: jaq, which some
  # laptops put on the PATH as `jq`, cannot assign through a null path.
  # shellcheck disable=SC2016 # jq variables
  if ! { if [[ -f ${live} ]]; then cat "${live}"; else echo '{}'; fi; } |
    jq --arg cmd "${command}" '
      if any(.hooks.SessionStart[]?; any(.hooks[]?; .command == $cmd)) then .
      else .hooks = ((.hooks // {}) | .SessionStart = ((.SessionStart // []) + [{hooks: [{type: "command", command: $cmd, timeout: 10}]}]))
      end' >"${merged}"; then
    rm -f "${merged}"
    return 1
  fi
  claude_settings_replace "${live}" "${merged}" "${keep_bak}"
}

# claude_session_hook_present <live file> <hook command>
claude_session_hook_present() {
  # shellcheck disable=SC2016 # jq variables
  jq -e --arg cmd "$2" 'any(.hooks.SessionStart[]?; any(.hooks[]?; .command == $cmd))' "$1" >/dev/null 2>&1
}

# Moves <merged> over <live> unless they are equal; prints created, unchanged
# or updated (previous copy kept as <live>.bak, unless <keep bak> is set and
# one exists).
# $1 live file, $2 merged file, $3 keep bak (optional).
claude_settings_replace() {
  local live="$1" merged="$2" keep_bak="${3:-}"
  chmod 644 "${merged}"
  if [[ ! -f ${live} ]]; then
    mv -f "${merged}" "${live}"
    echo created
  elif jq -en --slurpfile a "${live}" --slurpfile b "${merged}" '$a == $b' >/dev/null; then
    rm -f "${merged}"
    echo unchanged
  else
    [[ -n ${keep_bak} && -f ${live}.bak ]] || cp -p "${live}" "${live}.bak"
    mv -f "${merged}" "${live}"
    echo updated
  fi
}
