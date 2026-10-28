#!/usr/bin/env bash
# Tests for the Claude Code preset merge (container/claude-settings-merge.jq,
# through cli/lib/claude_settings.sh as `devbox sync claude` and `devbox agent
# install` call it) and for the preset's PermissionRequest hook command. Run by
# `make test` (part of `make check`).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
REPO_ROOT="${root}"
preset="${root}/home/.claude/settings.json"
# shellcheck source=../cli/lib/claude_settings.sh
. "${root}/cli/lib/claude_settings.sh"

# In /tmp: the hook command case below deletes there, and a per-user temp dir is not temp.
tmp="$(TMPDIR=/tmp mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
failed=0
passed=0
# $1 name, then a command that must succeed.
pass_if() {
  local name="$1"
  shift
  if "$@"; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    echo "FAIL ${name}" >&2
  fi
}
# $1 name, $2 jq expression that must be true of $3 (a file)
assert() { pass_if "$1: $2" jq -e "$2" "$3" >/dev/null; }

own_cmd="$(jq -r '.hooks.PermissionRequest[0].hooks[0].command' "${preset}")"

# A live file as moshi-hook and an IDE leave it: their own PermissionRequest
# and Notification entries, a status line, rules of the user's own, and a stale
# copy of the preset's entry with an older timeout.
live="${tmp}/settings.json"
jq -n --arg own "${own_cmd}" '{
  model: "sonnet",
  statusLine: {type: "command", command: "status-line"},
  permissions: {deny: ["Bash(mine)"], allow: ["Bash(ls)"]},
  hooks: {
    Notification: [{matcher: "permission_prompt", hooks: [{type: "command", command: "moshi-hook claude-hook", async: true}]}],
    PermissionRequest: [
      {hooks: [{type: "command", command: "moshi-hook claude-hook", async: false}]},
      {matcher: "Bash", hooks: [{type: "command", command: $own, timeout: 5}]}
    ]
  }
}' >"${live}"

state="$(claude_settings_apply "${preset}" "${live}")"
pass_if "first merge reports updated (${state})" test "${state}" = updated
assert 'moshi-hook PermissionRequest entry kept' \
  '[.hooks.PermissionRequest[].hooks[].command] | index("moshi-hook claude-hook") != null' "${live}"
assert 'preset entry present once, current' \
  "[.hooks.PermissionRequest[] | select(.hooks[].command | contains(\"/devbox-agent/\"))] | length == 1 and .[0].hooks[0].timeout == 30" "${live}"
assert 'preset entry appended after the others' '.hooks.PermissionRequest | length == 2' "${live}"
assert 'other hook events untouched' '.hooks.Notification[0].hooks[0].command == "moshi-hook claude-hook"' "${live}"
assert 'statusLine kept' '.statusLine.command == "status-line"' "${live}"
assert 'model takes the preset value' '.model == "opus"' "${live}"
assert 'deny rules replaced by the preset' '.permissions.deny | index("Bash(mine)") == null' "${live}"
assert 'allow rules the preset does not set kept' '.permissions.allow == ["Bash(ls)"]' "${live}"
assert 'previous copy kept' '.hooks.PermissionRequest | length == 2' "${live}.bak"

state="$(claude_settings_apply "${preset}" "${live}")"
pass_if "second merge reports unchanged (${state})" test "${state}" = unchanged

fresh="${tmp}/fresh/settings.json"
state="$(claude_settings_apply "${preset}" "${fresh}")"
pass_if "a missing file is created (${state})" test "${state}" = created
pass_if 'a created file is the preset' cmp -s <(jq . "${preset}") "${fresh}"

# An entry holding both a foreign command and the preset's keeps the foreign
# one; a preset that drops its hooks uninstalls them from every event, also
# one it never set, without touching anyone else's.
mixed="${tmp}/mixed.json"
jq -n --arg own "${own_cmd}" '{
  hooks: {
    PermissionRequest: [{matcher: "Bash", hooks: [
      {type: "command", command: "ide-hook"}, {type: "command", command: $own}]}],
    PreToolUse: [{matcher: "Bash", hooks: [{type: "command", command: $own}]}],
    Stop: [{hooks: [{type: "command", command: "moshi-hook claude-hook"}]}]
  }
}' >"${mixed}"
claude_settings_merge "${preset}" "${mixed}" "${tmp}/mixed.out"
assert 'foreign command in a shared entry kept' \
  '[.hooks.PermissionRequest[].hooks[].command] | index("ide-hook") != null' "${tmp}/mixed.out"
assert 'preset command present once after a shared entry' \
  '[.hooks.PermissionRequest[].hooks[].command | select(contains("/devbox-agent/"))] | length == 1' "${tmp}/mixed.out"
assert 'stale preset entry in an event the preset does not set removed' '.hooks | has("PreToolUse") | not' \
  "${tmp}/mixed.out"
jq 'del(.hooks)' "${preset}" >"${tmp}/nohooks.json"
claude_settings_merge "${tmp}/nohooks.json" "${mixed}" "${tmp}/uninstalled.out"
assert 'a preset without hooks uninstalls its own' \
  '[.hooks[][].hooks[].command | select(contains("/devbox-agent/"))] | length == 0' "${tmp}/uninstalled.out"
assert 'and keeps every foreign command' \
  '[.hooks[][].hooks[].command] | sort == ["ide-hook", "moshi-hook claude-hook"]' "${tmp}/uninstalled.out"
jq -n '{model: "x"}' >"${tmp}/nohooks-live.json"
claude_settings_merge "${tmp}/nohooks.json" "${tmp}/nohooks-live.json" "${tmp}/nohooks.out"
assert 'no hooks key appears where neither side had one' 'has("hooks") | not' "${tmp}/nohooks.out"

# Only commands under ~/.local/libexec/devbox-agent/ are the preset's: a
# foreign script in some other devbox-agent/ directory stays.
jq -n '{hooks: {PreToolUse: [{hooks: [{type: "command", command: "/opt/acme/devbox-agent/audit.sh"}]}]}}' \
  >"${tmp}/foreign.json"
claude_settings_merge "${preset}" "${tmp}/foreign.json" "${tmp}/foreign.out"
assert 'a foreign devbox-agent/ command stays' \
  '.hooks.PreToolUse[0].hooks[0].command == "/opt/acme/devbox-agent/audit.sh"' "${tmp}/foreign.out"
# shellcheck disable=SC2016 # a literal $HOME inside the hook command
jq -n '{hooks: {PreToolUse: [{hooks: [{type: "command",
  command: "logger ran $HOME/.local/libexec/devbox-agent/devbox-safe-rm"}]}]}}' >"${tmp}/mention.json"
claude_settings_merge "${preset}" "${tmp}/mention.json" "${tmp}/mention.out"
assert 'a command that only mentions the preset path stays' \
  '.hooks.PreToolUse[0].hooks[0].command | startswith("logger ran")' "${tmp}/mention.out"
# A live file holding two JSON documents would hand the second to jq as the preset.
printf '%s\n%s\n' '{"model": "x"}' '{"model": "y"}' >"${tmp}/two.json"
# shellcheck disable=SC2016 # the sh -c program, not this shell
pass_if 'a live file with two documents is an error' \
  sh -c '! jq -s -f "$1" "$2" "$3" >/dev/null 2>&1' sh "${root}/container/claude-settings-merge.jq" \
  "${tmp}/two.json" "${preset}"

# A malformed hooks shape is an error, never silently dropped.
for shape in '{hooks: []}' '{hooks: {PreToolUse: {}}}' '{hooks: {PreToolUse: [1]}}' \
  '{hooks: {PreToolUse: [{hooks: {}}]}}'; do
  jq -n "${shape}" >"${tmp}/bad.json"
  # shellcheck disable=SC2016 # the sh -c program, not this shell
  pass_if "malformed hooks rejected: ${shape}" \
    sh -c '! jq -s -f "$1" "$2" "$3" >/dev/null 2>&1' sh "${root}/container/claude-settings-merge.jq" \
    "${tmp}/bad.json" "${preset}"
done

# bootstrap merges with the same filter (it cannot source cli/lib).
pass_if 'container/bootstrap.sh merges with container/claude-settings-merge.jq' \
  grep -q 'jq -s -f /opt/devbox/container/claude-settings-merge.jq' "${root}/container/bootstrap.sh"

# The preset's hook command, run the way Claude Code runs it (a shell, HOME
# set): silent while the script is not installed, the script's answer once it is.
request="$(jq -n --arg d "${tmp}" '{hook_event_name: "PermissionRequest", tool_name: "Bash",
  tool_input: {command: "rm -f gone.txt"}, cwd: $d, permission_mode: "default"}')"
fake_home="${tmp}/home"
mkdir -p "${fake_home}"
out="$(HOME="${fake_home}" sh -c "${own_cmd}" <<<"${request}")"
pass_if "hook command is silent without the script installed (${out})" test -z "${out}"
mkdir -p "${fake_home}/.local/libexec/devbox-agent"
install -m 755 "${root}/home/.local/libexec/devbox-agent/devbox-safe-rm" "${fake_home}/.local/libexec/devbox-agent/devbox-safe-rm"
out="$(HOME="${fake_home}" sh -c "${own_cmd}" <<<"${request}")"
pass_if "hook command answers through the installed script (${out})" \
  test "${out}" = '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'

echo "claude-settings-merge: ${passed} passed, ${failed} failed"
((failed == 0))
