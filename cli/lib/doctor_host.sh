# The workstation half of `devbox doctor`.
doctor_host() {
  require_env_file

  if command -v docker >/dev/null 2>&1; then
    log_success 'docker present'
  else
    fail 'docker missing'
  fi

  if docker compose version >/dev/null 2>&1; then
    log_success "compose present: $(docker compose version --short)"
  else
    fail 'docker compose v2 missing'
  fi

  local bind_addr ssh_port addr
  bind_addr="$(env_get BIND_ADDR)"
  ssh_port="$(env_get DEVBOX_SSH_PORT)"
  addr="$(tailscale_addr)"

  # BIND_ADDR is what keeps sshd off the public internet; without a Tailscale
  # address there is nothing to compare it with, so that is a failure too.
  if [[ -z "${bind_addr}" ]]; then
    fail 'BIND_ADDR is empty'
  elif [[ -z "${addr}" ]]; then
    fail "Tailscale reports no IPv4 address - cannot verify BIND_ADDR ${bind_addr} (is tailscale installed and up?)"
  elif [[ "${bind_addr}" != "${addr}" ]]; then
    fail "BIND_ADDR is ${bind_addr} but Tailscale reports ${addr} - run './bin/devbox env'"
  else
    log_success "BIND_ADDR matches the Tailscale address (${bind_addr})"
  fi

  if grep -qE "${bind_addr}:${ssh_port}\b" <<<"$(ss -ltn 2>/dev/null)"; then
    log_success "sshd published on ${bind_addr}:${ssh_port}"
  else
    fail "nothing listening on ${bind_addr}:${ssh_port}"
  fi

  if grep -qE "0\.0\.0\.0:${ssh_port}\b" <<<"$(ss -ltn 2>/dev/null)"; then
    fail "port ${ssh_port} is published on 0.0.0.0 - the devbox is internet-exposed"
  else
    log_success "port ${ssh_port} is not published on 0.0.0.0"
  fi

  local health
  health="$(docker inspect -f '{{ .State.Health.Status }}' "${SERVICE}" 2>/dev/null || echo 'missing')"
  if [[ "${health}" == 'healthy' ]]; then
    log_success 'container healthy'
  else
    fail "container health: ${health}"
  fi

  local pid1_user
  pid1_user="$(compose exec -T "${SERVICE}" ps -o user= -p 1 2>/dev/null | tr -d ' ' || true)"
  if [[ "${pid1_user}" == 'dev' ]]; then
    log_success 'PID 1 runs as dev (no root process)'
  else
    fail "PID 1 user: ${pid1_user:-unknown}"
  fi

  log_info 'Toolchain versions:'
  # Each probe's exit status matters: a tool missing from the PATH of a login
  # shell is a broken devbox even though the loop itself would succeed.
  # shellcheck disable=SC2016 # the probe list must expand inside the container
  if ! compose exec -T "${SERVICE}" bash -lc '
    status=0
    for probe in "herdr --version" "omp --version" "claude --version" "node -v" "pnpm -v" "gh --version" \
      "lazygit --version" "wt --version" "terraform version" "git --version" \
      "docker --version" "docker compose version"; do
      # No pipe into head: a multi-line tool would take SIGPIPE (141) once head
      # exits, and the real exit code is the whole point of this loop.
      label="${probe%% *}"
      [[ "${probe}" == "docker compose"* ]] && label=compose
      if output="$($probe 2>&1)"; then
        IFS= read -r first <<< "$output"
        printf "  %-12s %s\n" "$label" "$first"
      else
        IFS= read -r first <<< "$output"
        printf "  %-12s FAILED: %s\n" "$label" "$first"
        status=1
      fi
    done
    exit "$status"
  '; then
    fail 'one or more toolchain probes failed'
  fi

  # The agent git override: `omp` and `claude` on the PATH must be the
  # launchers, reached through symlinks. A plain file there is what `omp
  # update` takes over in place - agent sessions then read ~/.gitconfig and
  # reach for SSH keys.
  local agent launcher_state
  for agent in omp claude; do
    # shellcheck disable=SC2016,SC2018 # the body expands in the container; tr keeps the ASCII state word
    launcher_state="$(compose exec -T -e AGENT="${agent}" "${SERVICE}" bash -lc '
      agent_dir="$HOME/.local/libexec/devbox-agent"
      [[ -L "${agent_dir}/${AGENT}" ]] || { echo notalink; exit 0; }
      resolved="$(command -v "${AGENT}" 2>/dev/null || true)"
      [[ "$(readlink -f "${resolved}")" == "${agent_dir}/${AGENT}-launcher" ]] || { echo bypassed; exit 0; }
      echo ok
    ' 2>/dev/null | tr -cd 'a-z')"
    case "${launcher_state}" in
    ok) log_success "agent git override: ${agent} resolves to the launcher" ;;
    notalink)
      # shellcheck disable=SC2088 # literal ~ in a message
      fail "~/.local/libexec/devbox-agent/${agent} is not a symlink to ${agent}-launcher - an ${agent} release binary may have replaced it; run ./bin/devbox bootstrap"
      ;;
    *) fail "agent git override: ${agent} does not resolve to the launcher - run './bin/devbox bootstrap'" ;;
    esac
  done

  # The identity registry itself: every identity-derived file (SSH keys and
  # config, ~/.gitconfig's per-tree includes, allowed_signers, the agent
  # gitconfigs, GitHub tokens and Apps) is skipped as one block by bootstrap
  # when this fails, so a broken registry costs configuration with no other
  # symptom until something tries to use it.
  local registry_output registry_line
  # shellcheck disable=SC2016 # the script body must expand inside the container
  if registry_output="$(compose exec -T "${SERVICE}" bash -lc '"$HOME/.local/libexec/devbox-identities" check' 2>&1)"; then
    log_success 'identity registry valid (devbox-identities check)'
  else
    fail 'identity registry check failed - everything identity-derived is skipped until it is fixed:'
    while IFS= read -r registry_line; do
      [[ -z "${registry_line}" ]] || log_warn "  ${registry_line}"
    done <<<"${registry_output}"
  fi

  # The agent gitconfigs: GIT_CONFIG_GLOBAL points into ~/.config/devbox/git, so
  # `git config --global` in a session rewrites the agent identity itself - on
  # the laptop one such call put the user's own name and email on five commits.
  # The directory mode is what stops it, since git locks beside the file. The
  # expected file set is registry-driven, not hard-coded: the root
  # agent.gitconfig plus one agent-<slug>.gitconfig per identity that has its
  # own agent_name or agent_email - so a renamed, added or dropped account is
  # caught here too, in both directions (missing and unexpected files).
  local gitconfig_state
  # shellcheck disable=SC2016 # the script body must expand inside the container
  gitconfig_state="$(compose exec -T "${SERVICE}" bash -c '
    set -e
    . "$HOME/.local/libexec/devbox-identities"
    dir="$HOME/.config/devbox/git"
    export DEVBOX_IDENTITIES_TEMPLATE_DIR=/opt/devbox/home/.config/devbox/git
    # every tree-claiming identity; the default one has no include of its own
    bad=""
    [[ -f "$dir/agent.gitconfig" && "$(di_render_agent_gitconfig)" == "$(cat "$dir/agent.gitconfig")" ]] ||
      bad="agent.gitconfig"
    expected_slugs=""
    for slug in $(di_dir_slugs); do
      expected_slugs="$expected_slugs $slug"
      name="agent-${slug}.gitconfig"
      [[ -f "$dir/$name" && "$(di_render_agent_author "$slug")" == "$(cat "$dir/$name")" ]] ||
        bad="$bad $name"
    done
    for f in "$dir"/agent-*.gitconfig; do
      [[ -e "$f" ]] || continue
      slug="$(basename "$f" .gitconfig)"
      slug="${slug#agent-}"
      case " $expected_slugs " in
      *" $slug "*) ;;
      *) bad="$bad unexpected:$(basename "$f")" ;;
      esac
    done
    if [[ -n "$bad" ]]; then
      printf "stale:%s\n" "${bad# }"
    elif [[ -w "$dir" ]]; then
      echo writable
    else
      echo ok
    fi
  ' 2>/dev/null || echo error)"
  case "${gitconfig_state}" in
  ok) log_success 'agent gitconfigs read-only and matching the registry' ;;
  writable)
    # shellcheck disable=SC2088 # literal ~ in a message
    fail "~/.config/devbox/git is writable - a stray 'git config --global' in a session would rewrite the agent identity; run './bin/devbox bootstrap'"
    ;;
  stale:*)
    # shellcheck disable=SC2088 # literal ~ in a message
    fail "~/.config/devbox/git/{${gitconfig_state#stale:}} do not match identities.conf (missing, stale, or not expected by the registry) - run './bin/devbox bootstrap'"
    ;;
  *) fail "could not check ~/.config/devbox/git against the registry - run './bin/devbox bootstrap'" ;;
  esac

  # Moshi's notifications, approvals and Chat View all arrive through this
  # daemon, which the entrypoint starts because the container has no systemd.
  # Unpaired is a warning, not a failure: the box works, the phone just gets
  # nothing. A stopped daemon is a failure - something killed it.
  local hook_state
  # shellcheck disable=SC2016,SC2018 # the body expands in the container; tr keeps the ASCII state word
  hook_state="$(compose exec -T "${SERVICE}" bash -lc '
    command -v moshi-hook >/dev/null 2>&1 || { echo absent; exit 0; }
    pgrep -f "(^|/)(moshi|moshi-hook) serve( |$)" >/dev/null 2>&1 || { echo stopped; exit 0; }
    case "$(moshi-hook status 2>/dev/null || true)" in *unpaired*) echo unpaired ;; *) echo paired ;; esac
  ' 2>/dev/null | tr -cd 'a-z')"
  case "${hook_state}" in
  paired) log_success 'moshi-hook daemon running and paired' ;;
  unpaired) log_warn "moshi-hook daemon running but unpaired - pair in the container ('moshi-hook pair --token <token>'), then './bin/devbox hook'" ;;
  stopped) fail "moshi-hook is installed but not running - './bin/devbox hook' restarts it without touching SSH sessions" ;;
  *) fail "moshi-hook is not installed - run './bin/devbox bootstrap'" ;;
  esac

  # The project daemon must be reachable from inside the container and must be
  # rootless: a rootful server here would mean the socket belongs to the host's
  # root daemon, which is exactly what this design refuses.
  local docker_info
  docker_info="$(compose exec -T "${SERVICE}" bash -lc \
    'docker info -f "{{ .ServerVersion }} {{ .SecurityOptions }}"' 2>&1 || true)"
  if [[ "${docker_info}" == *rootless* ]]; then
    log_success "project docker reachable: ${docker_info%% *} (rootless)"
  elif [[ -n "${docker_info}" && "${docker_info}" != *'Cannot connect'* && "${docker_info}" != *error* ]]; then
    fail "project docker is not rootless: ${docker_info}"
  else
    fail "project docker unreachable from the container - run: sudo ./bin/devbox docker setup --check"
  fi

  # host.docker.internal is how everything in the container reaches a project
  # service, so an unresolvable name means every published port is unreachable
  # while both halves still look healthy. The daemon's publish address has to
  # agree with it, or a project's ports land where nothing can reach them.
  local gateway publish_ip
  gateway="$(compose exec -T "${SERVICE}" \
    sh -c "getent hosts host.docker.internal | awk '{ print \$1; exit }'" 2>/dev/null | tr -cd '0-9.' || true)"
  # From the unit file, not `systemctl --machine` - the file is world-readable,
  # the other user's manager is not addressable without root.
  publish_ip="$(sed -n 's/^ExecStart=.*--ip \([0-9.]*\).*/\1/p' \
    /etc/systemd/user/docker.service 2>/dev/null | head -1 || true)"
  if [[ -z "${gateway}" ]]; then
    fail 'host.docker.internal does not resolve inside the container'
  elif [[ -n "${publish_ip}" && "${publish_ip}" != "${gateway}" ]]; then
    fail "host.docker.internal is ${gateway} but the daemon publishes on ${publish_ip}: sudo ./bin/devbox docker setup"
  else
    log_success "host.docker.internal resolves to ${gateway}${publish_ip:+ (matches the daemon publish address)}"
  fi

  # The rootless daemon publishes every project port on 0.0.0.0 and cannot be
  # told otherwise, so this table - not the daemon - is what keeps those ports
  # off the Tailnet and the LAN, and the host's own sshd out of the devbox's
  # reach. `is-active` needs no privileges; reading the table itself would, so
  # the file the unit loads stands in for it: a ruleset this checkout changed
  # stays inert until `docker setup` runs again.
  if ! systemctl is-active --quiet devbox-docker-firewall.service; then
    fail 'devbox-docker-firewall is inactive - project ports would reach the Tailnet and the LAN:'' sudo ./bin/devbox docker setup'
  elif [[ "$(cat "${NFT_CONF}" 2>/dev/null)" != "$(netfilter_ruleset)" ]]; then
    fail "${NFT_CONF} is not the ruleset this checkout writes - the host still runs an older boundary:"' sudo ./bin/devbox docker setup'
  else
    log_success 'project port boundary active and current (devbox-docker-firewall)'
  fi

  # The daemon's own configuration has to stay out of the container's reach:
  # dev's user manager reads its units and environment.d from the root-owned
  # directories the drop-in names, never from the bind mount. The file is
  # world-readable, the manager's live environment is not, so its start time
  # stands in - a manager started before the drop-in was written still reads
  # /home/dev.
  local manager_pid manager_age dropin_age
  manager_pid="$(systemctl show "user@${DEV_UID}.service" -p MainPID --value 2>/dev/null || true)"
  if [[ "$(cat "${MANAGER_DROPIN}" 2>/dev/null)" != "$(manager_dropin)" ]]; then
    fail "${MANAGER_DROPIN} is missing or stale - the project daemon's user manager reads its configuration from the bind mount:"' sudo ./bin/devbox docker setup'
  elif [[ -z "${manager_pid}" || "${manager_pid}" == 0 ]]; then
    fail "user@${DEV_UID}.service is not running, so neither is the project daemon:"' sudo ./bin/devbox docker setup'
  else
    manager_age="$(ps -o etimes= -p "${manager_pid}" | tr -d ' ')"
    dropin_age=$(($(date +%s) - $(stat -c %Y "${MANAGER_DROPIN}")))
    if ((manager_age > dropin_age)); then
      fail "user@${DEV_UID}.service predates ${MANAGER_DROPIN}, so it still reads ${DEV_HOME}:"' sudo ./bin/devbox docker setup'
    else
      log_success "project daemon's user manager reads root-owned ${MANAGER_DIR}, not the bind mount"
    fi
  fi

  log_info 'devbox command'
  devbox_command_checks

  finish_checks
}
