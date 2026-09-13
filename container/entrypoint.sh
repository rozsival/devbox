#!/usr/bin/env bash
# PID 1 of the devbox container. Runs as `dev`, never as root: it prepares the
# bind-mounted home, assembles authorized_keys, runs the bootstrap, and becomes
# sshd. Order matters - directories before keys, keys before sshd, or the box
# starts unreachable.
set -euo pipefail

log_info() { echo -e "\033[0;34m[INFO]\033[0m  $*"; }
log_success() { echo -e "\033[0;32m[OK]\033[0m    $*"; }
log_warn() { echo -e "\033[1;33m[WARN]\033[0m  $*" >&2; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; }

readonly HOME_DIR="${HOME:-/home/dev}"
readonly SSH_DIR="${HOME_DIR}/.ssh"
readonly HOST_KEY="${SSH_DIR}/host/ssh_host_ed25519_key"
readonly AUTHORIZED_KEYS="${SSH_DIR}/authorized_keys"

# -- 1. Home skeleton ---------------------------------------------------------
mkdir -p \
  "${SSH_DIR}/host" \
  "${HOME_DIR}/.local/bin" \
  "${HOME_DIR}/.config" \
  "${HOME_DIR}/.bashrc.d" \
  "${HOME_DIR}/projects/rozsival" \
  "${HOME_DIR}/projects/work"
chmod 700 "${SSH_DIR}"
# StrictModes rejects a group- or world-writable home.
chmod go-w "${HOME_DIR}"

# -- 2. sshd host key ---------------------------------------------------------
if [[ ! -f "${HOST_KEY}" ]]; then
  log_info 'Generating sshd host key...'
  ssh-keygen -q -t ed25519 -N '' -C 'devbox-host' -f "${HOST_KEY}"
fi
chmod 600 "${HOST_KEY}"

# -- 3. authorized_keys -------------------------------------------------------
# Rebuilt on every start so rotating a key on GitHub is a container restart, not
# a manual edit.
assembled="$(mktemp)"
trap 'rm -f "${assembled}"' EXIT

if [[ -n "${DEVBOX_GITHUB_USER:-}" ]]; then
  if curl -fsSL --max-time 15 "https://github.com/${DEVBOX_GITHUB_USER}.keys" >>"${assembled}"; then
    log_info "Fetched public keys for GitHub user ${DEVBOX_GITHUB_USER}."
  else
    log_warn "Could not fetch https://github.com/${DEVBOX_GITHUB_USER}.keys; keeping the existing authorized_keys."
    : >"${assembled}"
  fi
fi

if [[ -n "${DEVBOX_EXTRA_AUTHORIZED_KEYS:-}" ]]; then
  printf '%s\n' "${DEVBOX_EXTRA_AUTHORIZED_KEYS}" >>"${assembled}"
fi

if [[ -s "${assembled}" ]]; then
  grep -Ev '^[[:space:]]*(#|$)' "${assembled}" | sort -u >"${AUTHORIZED_KEYS}"
  chmod 600 "${AUTHORIZED_KEYS}"
  log_success "authorized_keys holds $(wc -l <"${AUTHORIZED_KEYS}" | tr -d ' ') key(s)."
elif [[ -s "${AUTHORIZED_KEYS}" ]]; then
  log_warn 'Reusing the authorized_keys already present in the home volume.'
else
  log_error 'No authorized keys available: set DEVBOX_GITHUB_USER or DEVBOX_EXTRA_AUTHORIZED_KEYS.'
  log_error 'Refusing to start an unreachable sshd.'
  exit 1
fi

# -- 4. Bootstrap -------------------------------------------------------------
# A partial bootstrap is better than no SSH access to a half-configured box, so a
# failure here logs and continues.
if [[ "${DEVBOX_SKIP_BOOTSTRAP:-0}" != '1' ]]; then
  if ! /opt/devbox/container/bootstrap.sh; then
    # shellcheck disable=SC2016 # literal command name in a message
    log_warn 'Bootstrap failed; continuing so SSH stays available. Re-run `./bin/devbox bootstrap`.'
  fi
fi

# -- 5. Project port mirror ---------------------------------------------------
# Forwards live in this container's netns, so recreating it drops them while the
# project containers - owned by the sibling daemon - keep running and keep their
# published ports. Re-syncing here is what makes `devbox-ports` a thing the user
# never has to remember after a rebuild. Best-effort: the daemon may not be
# provisioned, and an unreachable one must not cost SSH access.
#
# DOCKER_HOST is passed explicitly: ~/.bashrc.d/devbox.sh exports it for shells,
# and PID 1 is not one.
if DOCKER_HOST='unix:///run/devbox/docker.sock' /usr/local/bin/devbox-ports >/dev/null 2>&1; then
  log_success 'Mirrored the project daemon ports onto 127.0.0.1.'
else
  log_info 'No project ports mirrored (the project daemon is not reachable yet).'
fi

# -- 6. sshd ------------------------------------------------------------------
log_info 'Starting sshd on port 2222...'
exec /usr/sbin/sshd -D -e -f /opt/devbox/container/sshd_config
