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
  chmod 644 "${merged}"
  if [[ ! -f ${live} ]]; then
    mv -f "${merged}" "${live}"
    echo created
  elif jq -en --slurpfile a "${live}" --slurpfile b "${merged}" '$a == $b' >/dev/null; then
    rm -f "${merged}"
    echo unchanged
  else
    cp -p "${live}" "${live}.bak"
    mv -f "${merged}" "${live}"
    echo updated
  fi
}
