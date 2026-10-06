[[ -n "${args[--check]:-}" ]] && CHECK_ONLY='true'

[[ -f "${ENV_FILE}" ]] || log_error "Missing ${ENV_FILE} - run './bin/devbox env' first"
# --check probes as the daemon's user and reads root-owned units, so it needs
# the same privileges as the apply path; it simply changes nothing.
[[ "${EUID}" -eq 0 ]] ||
  log_error 'This command inspects and provisions a host user, a systemd unit and /run - run it with sudo.'

step_packages
step_user
step_sshd
step_data_dir
step_firewall
step_netfilter
if getent passwd "${DEV_USER}" >/dev/null; then
  step_socket_dir
  step_daemon
  [[ "${CHECK_ONLY}" == 'true' ]] || step_smoke
elif [[ "${CHECK_ONLY}" == 'true' ]]; then
  fail "remaining steps need the ${DEV_USER} user - re-run without --check to provision"
fi

upsert_env_key DEVBOX_DOCKER_SOCKET_DIR "${SOCKET_DIR}"

if [[ "${CHECK_ONLY}" == 'true' ]]; then
  ((failures == 0)) || log_error "${failures} item(s) missing - re-run without --check to provision."
  log_success 'Rootless project docker is fully provisioned.'
  exit 0
fi
# A step that could not apply - sshd rejecting its config, say - reports and
# lets the rest run, so the exit status is where it surfaces.
((failures == 0)) || log_error "${failures} step(s) could not be applied - see the warnings above, fix them and re-run."
log_success 'Done. Next: ./bin/devbox rebuild (as your own user, not root).'
