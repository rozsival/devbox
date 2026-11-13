## The agents behind the laptop's launchers.

# The real binary of an agent: the first PATH entry named after it that does
# not resolve to its launcher script, so this also holds when run from inside
# an agent session. Prints nothing when the agent is not installed.
real_agent_binary() {
  local agent="$1" dir path_dirs
  IFS=: read -ra path_dirs <<<"${PATH}"
  for dir in "${path_dirs[@]}"; do
    [[ -f ${dir}/${agent} && -x ${dir}/${agent} && ! ${dir}/${agent} -ef "${AGENT_DIR}/${agent}-launcher" ]] || continue
    printf '%s\n' "${dir}/${agent}"
    return 0
  done
}
