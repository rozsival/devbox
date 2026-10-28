# Merges the Claude Code preset into a live ~/.claude/settings.json:
# `jq -s -f claude-settings-merge.jq <live> <preset>`. One filter for every
# writer - cli/lib/claude_settings.sh (`devbox sync claude`, `devbox agent
# install`) and container/bootstrap.sh - so the three cannot drift.
#
# Everything but `hooks` is jq's `*`: every key the preset does not set stays,
# the ones it sets take its value, arrays (the permission rules) are replaced
# whole. `hooks` cannot be: moshi-hook and IDE integrations add entries to the
# same event arrays (PermissionRequest among them), and a whole-array replace
# would drop theirs. The preset owns exactly the hook commands that run a
# script from ~/.local/libexec/devbox-agent/: those are removed from every live
# event - also
# from an event the preset no longer sets, so dropping a hook from the preset
# uninstalls it - and from inside an entry that also holds someone else's
# command, which stays. An entry or event left empty by that goes; then the
# preset's entries are appended. A re-run changes nothing.
# A malformed `hooks` (not an object of arrays of objects whose `hooks` is an
# array) is an error, so the caller reports the file instead of silently
# dropping what it cannot read.
# Owned: a command that is one of the preset's, or that has the preset's own
# shape - it starts by naming a script in ~/.local/libexec/devbox-agent/ - so
# an older preset's command is replaced too, while a foreign command that only
# mentions such a path somewhere stays.
def owned($own): (.command? // "") as $c | ($c | type) == "string"
  and (($own | index($c)) != null or ($c | startswith("f=\"$HOME/.local/libexec/devbox-agent/")));
def check_hooks:
  if type != "object" then error("hooks is not an object")
  elif any(.[]; type != "array") then error("a hooks event is not an array")
  elif any(.[][]; type != "object" or ((.hooks? // []) | type) != "array") then error("a hooks entry is malformed")
  else . end;
def prune_entry($own):
  if (.hooks? | type) == "array" and any(.hooks[]; owned($own)) then
    .hooks |= map(select(owned($own) | not)) | select(.hooks != [])
  else
    .
  end;

if length != 2 then error("expected exactly two JSON documents, the live file and the preset") else . end
| .[0] as $live
| .[1] as $preset
| [($preset.hooks // {})[][]?.hooks[]?.command | strings] as $own
| ($live.hooks // {} | check_hooks) as $_
| ($preset.hooks // {} | check_hooks) as $_
| ($live * ($preset | del(.hooks)))
| if ($live | has("hooks")) or ($preset | has("hooks")) then
    .hooks = ((($live.hooks // {})
        | with_entries(.value as $was | .value |= map(prune_entry($own)) | select(.value != [] or $was == [])))
      as $kept
      | reduce (($preset.hooks // {}) | to_entries[]) as $event ($kept;
          .[$event.key] = ((.[$event.key] // []) + $event.value)))
    | if .hooks == {} and ($live | has("hooks") | not) then del(.hooks) else . end
  else
    .
  end
