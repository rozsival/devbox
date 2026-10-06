# `devbox docker setup`: host-side, one-time provisioning for the project
# Docker daemon.
#
# The devbox container gets Docker by talking to a *second* daemon that runs
# rootless as a dedicated unprivileged host user (`dev`), never to the host's
# root daemon. See docs/docker.md for the reasoning; the short version is that
# the two alternatives both hand out host root:
#
#   * mounting /var/run/docker.sock - the API can bind-mount / and add caps;
#   * a nested daemon in the container - rootless needs setuid newuidmap, which
#     cap_drop: ALL plus no-new-privileges deliberately make impossible.
#
# Every step is idempotent and logged, so a re-run is a no-op. `--check` reports
# state and changes nothing.

readonly DEV_USER='dev'
readonly DEV_GROUP='devbox'
readonly DEV_UID=1001
readonly DEV_HOME='/home/dev'
readonly SOCKET_DIR='/run/devbox'
readonly SOCKET="${SOCKET_DIR}/docker.sock"
readonly TMPFILES_CONF='/etc/tmpfiles.d/devbox-docker.conf'
readonly UNIT='/etc/systemd/user/docker.service'
# dev's systemd user manager reads units, drop-ins, wants links and
# environment.d from XDG_CONFIG_HOME and XDG_DATA_HOME - by default ~/.config
# and ~/.local/share, the devbox bind mount. step_daemon points both at these
# root-owned directories instead (see manager_dropin).
readonly MANAGER_DIR='/etc/devbox-docker'
readonly MANAGER_CONFIG="${MANAGER_DIR}/config"
readonly MANAGER_DATA="${MANAGER_DIR}/share"
readonly MANAGER_DROPIN="/etc/systemd/system/user@${DEV_UID}.service.d/devbox-docker.conf"
readonly WANTS_LINK="${MANAGER_CONFIG}/systemd/user/default.target.wants/docker.service"
# Stated in the unit rather than derived from XDG_DATA_HOME, which no longer
# points into /home/dev.
readonly DATA_ROOT="${DEV_HOME}/.local/share/docker"
readonly SSHD_DROPIN='/etc/ssh/sshd_config.d/devbox-docker.conf'
readonly NFT_CONF='/etc/nftables.d/devbox-docker.nft'
readonly NFT_SERVICE='devbox-docker-firewall.service'
readonly NFT_UNIT="/etc/systemd/system/${NFT_SERVICE}"
# The devbox container sits on the default bridge (docker-compose.yml:
# network_mode: bridge), so docker0's address is both its gateway and what
# `host-gateway` resolves to inside it. The project daemon publishes there: it
# is the one host address the container can reach, and it exists whenever the
# host docker daemon does. Resolved at run time because a host may set `bip`.
readonly DEVBOX_BRIDGE='docker0'
# Tailscale's interface and the ranges it hands out: the CGNAT block for IPv4
# and its own ULA prefix for IPv6. Neither the devbox nor its project
# containers need the Tailnet - only Tailnet peers need to reach the devbox.
readonly TAILNET_IFACE='tailscale0'
readonly TAILNET_IPV4='100.64.0.0/10'
readonly TAILNET_IPV6='fd7a:115c:a1e0::/48'
# 65536 ids is the useradd default and what the daemon maps container uids into.
readonly SUBID_RANGE='165536-231071'

as_dev() {
  runuser -u "${DEV_USER}" -- env \
    XDG_RUNTIME_DIR="/run/user/${DEV_UID}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${DEV_UID}/bus" \
    PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
    "$@"
}

# -- 1. Packages --------------------------------------------------------------
# newuidmap/newgidmap come from uidmap and are what let the daemon map a range
# of subordinate ids; without them rootless docker is limited to a single uid
# and images that drop privileges (postgres, redis, node) fail to start.
step_packages() {
  local missing=()
  local pkg
  for pkg in uidmap slirp4netns; do
    dpkg-query -W -f='${Status}' "${pkg}" 2>/dev/null | grep -q 'ok installed' || missing+=("${pkg}")
  done
  if ((${#missing[@]} == 0)); then
    log_success "packages present: uidmap slirp4netns"
    return 0
  fi
  if [[ "${CHECK_ONLY}" == 'true' ]]; then
    fail "packages missing: ${missing[*]}"
    return 0
  fi
  log_info "Installing ${missing[*]}..."
  apt-get update -qq
  apt-get install -y --no-install-recommends "${missing[@]}"
}

# -- 2. The daemon's own user -------------------------------------------------
# A dedicated user, not the deploying user: an agent that reaches the daemon can
# start a container mounting any path that user can read. Owning only /home/dev
# keeps the host account, its SSH keys and its sudo rights out of reach.
step_user() {
  if getent group "${DEV_GROUP}" >/dev/null; then
    local actual_gid
    actual_gid="$(getent group "${DEV_GROUP}" | cut -d: -f3)"
    [[ "${actual_gid}" == "${DEV_UID}" ]] ||
      log_error "group ${DEV_GROUP} exists with gid ${actual_gid}, expected ${DEV_UID}; fix by hand"
  elif [[ "${CHECK_ONLY}" == 'true' ]]; then
    fail "group ${DEV_GROUP} (gid ${DEV_UID}) missing"
  else
    # Pinned, not auto-assigned: .env's HOST_GID and the container's own `dev`
    # group must agree with it, and a drifting gid shows up as files the
    # container cannot write.
    getent group "${DEV_UID}" >/dev/null &&
      log_error "gid ${DEV_UID} is already taken by $(getent group "${DEV_UID}" | cut -d: -f1)"
    log_info "Creating group ${DEV_GROUP} (gid ${DEV_UID})..."
    groupadd --gid "${DEV_UID}" "${DEV_GROUP}"
  fi

  if getent passwd "${DEV_USER}" >/dev/null; then
    local actual_uid
    actual_uid="$(id -u "${DEV_USER}")"
    [[ "${actual_uid}" == "${DEV_UID}" ]] ||
      log_error "user ${DEV_USER} exists with uid ${actual_uid}, expected ${DEV_UID}; fix by hand"
    log_success "user ${DEV_USER} present (uid ${DEV_UID})"
  elif [[ "${CHECK_ONLY}" == 'true' ]]; then
    fail "user ${DEV_USER} (uid ${DEV_UID}) missing"
  else
    getent passwd "${DEV_UID}" >/dev/null &&
      log_error "uid ${DEV_UID} is already taken by $(getent passwd "${DEV_UID}" | cut -d: -f1)"
    log_info "Creating user ${DEV_USER} (uid ${DEV_UID}, home ${DEV_HOME})..."
    # --no-create-home: the home directory is the devbox bind mount and is
    # either migrated below or created by ./bin/devbox up. A skeleton copied in
    # here would shadow the container's own bootstrap.
    useradd --uid "${DEV_UID}" --gid "${DEV_GROUP}" --home-dir "${DEV_HOME}" \
      --no-create-home --shell /bin/bash --comment 'devbox project docker' "${DEV_USER}"
    # No password, no keys: this account is never logged into, it only owns the
    # daemon and the files the container writes.
    passwd -l "${DEV_USER}" >/dev/null
  fi

  getent passwd "${DEV_USER}" >/dev/null || return 0
  if grep -q "^${DEV_USER}:" /etc/subuid && grep -q "^${DEV_USER}:" /etc/subgid; then
    log_success "subordinate id ranges present for ${DEV_USER}"
  elif [[ "${CHECK_ONLY}" == 'true' ]]; then
    fail "subuid/subgid ranges missing for ${DEV_USER}"
  else
    log_info "Adding subordinate id ranges ${SUBID_RANGE}..."
    usermod --add-subuids "${SUBID_RANGE}" --add-subgids "${SUBID_RANGE}" "${DEV_USER}"
  fi
}

# -- 2b. No host login for the daemon's user -----------------------------------
# "No password, no keys" does not hold for long: dev's home is the devbox bind
# mount, so anything in the container can write /home/dev/.ssh/authorized_keys.
# A locked password does not stop a key login under `UsePAM yes` (Ubuntu's
# default), and a login - even a shell-less `ssh -N` with forwarding - would put
# the container's agent on this host as dev, in the host's network namespace.
# DenyUsers is the one control that holds whatever else the host's sshd_config
# says; it accumulates with an AllowUsers line, it never replaces it.
#
# A function because `doctor host` compares the installed file against it.
sshd_dropin() {
  cat <<SSHD_BODY
# Managed by ./bin/devbox docker setup - do not edit.
# ${DEV_USER} owns the project Docker daemon and nothing else. Its home is the
# devbox bind mount, which anything in the container can write, so an
# authorized_keys put there must never open a login on this host.
DenyUsers ${DEV_USER}
SSHD_BODY
}

step_sshd() {
  if ! command -v sshd >/dev/null 2>&1; then
    log_success "no sshd on this host - nothing ${DEV_USER} could log in to"
    return 0
  fi
  if [[ "$(cat "${SSHD_DROPIN}" 2>/dev/null)" == "$(sshd_dropin)" ]]; then
    log_success "${SSHD_DROPIN} current"
  elif [[ "${CHECK_ONLY}" == 'true' ]]; then
    fail "${SSHD_DROPIN} missing or stale - a key written into /home/dev from the devbox could open a host login as ${DEV_USER}"
  else
    log_info "Writing ${SSHD_DROPIN}..."
    install -d -m 755 "$(dirname "${SSHD_DROPIN}")"
    sshd_dropin >"${SSHD_DROPIN}"
    chmod 644 "${SSHD_DROPIN}"
    # Validated before anything reloads: a configuration sshd rejects would
    # otherwise cost the next login - yours.
    if ! sshd -t 2>/dev/null; then
      rm -f "${SSHD_DROPIN}"
      log_error "sshd -t rejects ${SSHD_DROPIN} (removed again) - add 'DenyUsers ${DEV_USER}' to /etc/ssh/sshd_config by hand"
    fi
    # Reloads a running sshd and leaves a socket-activated one to read the file
    # on its next start; open sessions are separate processes and keep going.
    systemctl try-reload-or-restart ssh.service
  fi
  # The file only counts if sshd reads it: a sshd_config without the stock
  # `Include /etc/ssh/sshd_config.d/*.conf` never does.
  if sshd -T -C "user=${DEV_USER},host=localhost,addr=127.0.0.1" 2>/dev/null |
    grep -qiE "^denyusers( .*)? ${DEV_USER}( |\$)"; then
    log_success "host sshd refuses ${DEV_USER}"
  else
    fail "host sshd does not apply ${SSHD_DROPIN} - /etc/ssh/sshd_config lacks 'Include /etc/ssh/sshd_config.d/*.conf'; add 'DenyUsers ${DEV_USER}' there yourself"
  fi
}

# -- 3. Path identity ---------------------------------------------------------
# The daemon resolves bind-mount sources on the host. A project compose file
# saying `./data:/var/lib/postgresql/data` sends the *container* path, so the
# home directory must sit at the same absolute path on both sides or every
# relative bind mount silently resolves to an empty host directory.
step_data_dir() {
  local current
  current="$(env_get DEVBOX_DATA_DIR)"
  [[ -n "${current}" ]] || log_error "DEVBOX_DATA_DIR is empty in ${ENV_FILE} - run './bin/devbox env' first"

  if [[ "${current}" != "${DEV_HOME}" ]]; then
    if [[ "${CHECK_ONLY}" == 'true' ]]; then
      fail "DEVBOX_DATA_DIR is ${current}, must become ${DEV_HOME}"
    elif [[ -d "${current}" ]]; then
      [[ -e "${DEV_HOME}" ]] &&
        log_error "${DEV_HOME} already exists and ${current} is still in use; merge them by hand"
      grep -qx devbox <<<"$(docker ps --format '{{.Names}}' 2>/dev/null)" &&
        log_error "the devbox container is running; stop it first: ./bin/devbox down"
      log_info "Moving ${current} to ${DEV_HOME}..."
      mv "${current}" "${DEV_HOME}"
    fi
  fi
  upsert_env_key DEVBOX_DATA_DIR "${DEV_HOME}"

  [[ -d "${DEV_HOME}" ]] || {
    [[ "${CHECK_ONLY}" == 'true' ]] && fail "${DEV_HOME} missing" && return 0
    install -d -m 750 -o "${DEV_USER}" -g "${DEV_GROUP}" "${DEV_HOME}"
  }

  local owner
  owner="$(stat -c '%u:%g' "${DEV_HOME}")"
  if [[ "${owner}" == "${DEV_UID}:$(getent group "${DEV_GROUP}" | cut -d: -f3)" ]]; then
    log_success "${DEV_HOME} owned by ${DEV_USER}:${DEV_GROUP}"
  elif [[ "${CHECK_ONLY}" == 'true' ]]; then
    fail "${DEV_HOME} is owned by ${owner}, expected ${DEV_USER}:${DEV_GROUP}"
  else
    log_info "Chowning ${DEV_HOME} to ${DEV_USER}:${DEV_GROUP}..."
    chown -R "${DEV_USER}:${DEV_GROUP}" "${DEV_HOME}"
    chmod 750 "${DEV_HOME}"
  fi

  upsert_env_key HOST_UID "${DEV_UID}"
  upsert_env_key HOST_GID "$(getent group "${DEV_GROUP}" | cut -d: -f3)"
}

# -- 4. Firewall path to the published ports ----------------------------------
# Packets from the devbox container to a host address are delivered locally, so
# unlike a *published* port they do traverse INPUT and UFW's default deny stops
# them (docs/networking.md explains the published-port asymmetry). The rule is
# scoped to the bridge the devbox is on and the address the daemon publishes on,
# but not to a port - those are the projects' - so it admits every listener on
# that address; step_netfilter narrows it to the daemon's own sockets.
#
# Prints the bridge's CIDR so callers can reuse it; fails loudly, because every
# later step depends on this address.
bridge_cidr() {
  local cidr
  cidr="$(ip -4 -o addr show "${DEVBOX_BRIDGE}" 2>/dev/null | awk '{ print $4; exit }')"
  [[ -n "${cidr}" ]] ||
    log_error "${DEVBOX_BRIDGE} has no IPv4 address - start the host docker daemon first"
  printf '%s' "${cidr}"
}

step_firewall() {
  local gateway
  gateway="$(bridge_cidr)"
  gateway="${gateway%%/*}"

  command -v ufw >/dev/null 2>&1 || {
    log_info 'ufw is not installed; no firewall rule needed.'
    return 0
  }
  grep -q '^Status: active' <<<"$(ufw status 2>/dev/null)" || {
    log_info 'ufw is inactive; no firewall rule needed.'
    return 0
  }
  if grep -q "${gateway}" <<<"$(ufw status)"; then
    log_success "ufw already allows ${DEVBOX_BRIDGE} -> ${gateway}"
    return 0
  fi
  if [[ "${CHECK_ONLY}" == 'true' ]]; then
    fail "ufw does not allow ${DEVBOX_BRIDGE} -> ${gateway} (project services would be unreachable)"
    return 0
  fi
  # No `from <subnet>` clause: arriving on this interface already means a
  # container on this bridge, and deriving the subnet from the CIDR would be
  # wrong for any non-octet-aligned prefix a host set through `bip`.
  log_info "Allowing ${DEVBOX_BRIDGE} -> ${gateway}..."
  ufw allow in on "${DEVBOX_BRIDGE}" to "${gateway}" \
    comment 'devbox -> project docker published ports'
}

# -- 4b. The publish boundary -------------------------------------------------
# step_daemon makes the bridge gateway the *default* publish address, which is
# a default and not a boundary: `ports: ['0.0.0.0:8099:80']` overrides it, and a
# network created before that flag keeps its stored option. Leaving exposure to
# per-project port specs is not a boundary at all.
#
# So it is enforced here too: a small nftables table that drops input to any
# socket owned by the daemon's systemd slice unless it arrived on the devbox
# bridge or loopback. Matching by cgroup covers every port that daemon will ever
# publish, at any address, without knowing the port numbers - so published ports
# work from the devbox and from the host and nowhere else, whatever a project's
# compose file asks for.
#
# The same table is the boundary around the host's own services. step_firewall
# lets the bridge reach every port on the gateway and the host's sshd listens on
# all addresses, so from the bridge only the daemon's sockets are accepted and
# the rest is dropped - accept-then-drop rather than a single `!=` match, since
# a level-2 match on a socket whose cgroup sits higher (PID 1's own) is skipped,
# not compared, and a negated rule would wave it through. The daemon's
# containers reach the host one hop later, through slirp4netns - a `dev`
# process in the host netns - so the output chain refuses new connections from
# `dev` to any of the host's addresses, loopback included. The one exception
# is systemd-resolved's stub (127.0.0.53/54, port 53), which the daemon's own
# DNS goes through. Loopback cannot stay open on the grounds that no container
# reaches it (dockerd-rootless.sh turns off slirp4netns' host-loopback mapping):
# any project container can bind-mount /run/user/<uid> and drive dev's systemd
# user manager over its private bus, which then runs whatever it is told as
# `dev` in the host netns - one loopback connection away from the host's sshd.
#
# Unlike the DNAT case in docs/networking.md these are ordinary host-namespace
# sockets, so INPUT genuinely applies to them.
#
# And it keeps both off the Tailnet. Peers reach the devbox (its sshd is
# published on the Tailscale address), but nothing in it needs to reach a peer,
# and a forwarded agent plus a peer's sshd is a way off this machine. So no new
# connection leaves the bridge, or leaves as `dev`, through the Tailscale
# interface or towards a Tailscale address; replies to inbound sessions are
# established, so they pass. Both run after Docker's DNAT, so a root-daemon
# port published on the host's Tailscale address - the local LLMs - is already
# rewritten to its container and never matches. The address rules also cover
# tailscaled being down: the address is then no longer local and a packet to
# it would follow the default route out to the ISP.
#
# Its own `inet` table at a lower priority than ufw's chains, so the two never
# touch each other's rules; ufw still needs its one allow rule, because a table
# accepting a packet does not exempt it from later tables.
#
# A function rather than inline, because `doctor host` compares the file the
# unit loads against it: a ruleset changed here is inert until `docker setup`
# runs again.
netfilter_ruleset() {
  cat <<NFT_BODY
#!/usr/sbin/nft -f
# Managed by ./bin/devbox docker setup - do not edit.
#
# The daemon publishes on the bridge gateway by default, but a port spec can
# override that, so this table is what actually keeps project ports off the
# Tailnet and the LAN. Matching is by the listening socket's cgroup, which
# covers every port that daemon will ever publish, at any address.
#
# It also keeps the host's own services - its sshd above all - away from the
# devbox: from its bridge only the daemon's sockets answer, and uid ${DEV_UID} -
# slirp4netns for the daemon's containers, and anything a container gets dev's
# user manager to start - opens nothing on the host's addresses, loopback
# included, but systemd-resolved's stub on port 53.
#
# And it keeps both off the Tailnet: no new connection from the devbox bridge or
# from uid ${DEV_UID} through ${TAILNET_IFACE} or to a Tailscale address. Docker's
# DNAT runs first, so a root-daemon port published on the host's Tailscale
# address still works - it has become a container address by then.
#
# The conntrack rule is load-bearing: with --detach-netns the daemon runs in the
# *host* netns, so every reply to a pull, a DNS lookup or an outbound connection
# also lands on a socket in this slice. Without it the daemon has no egress at
# all - verified the hard way.

table inet devbox
delete table inet devbox

table inet devbox {
  chain input {
    type filter hook input priority filter - 10; policy accept;
    ct state established,related accept
    iifname "lo" accept
    iifname "${DEVBOX_BRIDGE}" socket cgroupv2 level 2 "user.slice/user-${DEV_UID}.slice" accept
    iifname "${DEVBOX_BRIDGE}" drop
    socket cgroupv2 level 2 "user.slice/user-${DEV_UID}.slice" drop
  }

  chain forward {
    type filter hook forward priority filter - 10; policy accept;
    iifname "${DEVBOX_BRIDGE}" ct state new oifname "${TAILNET_IFACE}" drop
    iifname "${DEVBOX_BRIDGE}" ct state new ip daddr ${TAILNET_IPV4} drop
    iifname "${DEVBOX_BRIDGE}" ct state new ip6 daddr ${TAILNET_IPV6} drop
  }

  chain output {
    type filter hook output priority filter - 10; policy accept;
    meta skuid ${DEV_UID} ct state new ip daddr { 127.0.0.53, 127.0.0.54 } meta l4proto { tcp, udp } th dport 53 accept
    meta skuid ${DEV_UID} ct state new fib daddr type local drop
    meta skuid ${DEV_UID} ct state new oifname "${TAILNET_IFACE}" drop
    meta skuid ${DEV_UID} ct state new ip daddr ${TAILNET_IPV4} drop
    meta skuid ${DEV_UID} ct state new ip6 daddr ${TAILNET_IPV6} drop
  }
}
NFT_BODY
}

# nft resolves the `socket cgroupv2` path to a cgroup *id* when the table
# loads, so the slice has to exist by then and the id goes stale if it is ever
# recreated. Ordered only after ufw, the unit raced the lingering user manager
# at boot and lost - 'cgroupv2 path fails: No such file or directory', leaving
# every project port on the Tailnet until someone ran doctor. So: pulled in by
# and ordered after user@<uid>.service, whose slice is the one matched, and
# PartOf it, so a restarted user manager (new slice, new id) reloads the table.
#
# Before the host's docker.service, which starts the devbox container: at boot
# the root daemon was restoring it while this table was still loading, so for
# those milliseconds the devbox could reach the host's sshd and the Tailnet.
# It costs the root daemon the user manager's start - it reports ready in
# ~0.1 s, before its own units run.
#
# No ExecStop: stopping the unit leaves the table in place, and `nft -f` swaps
# it atomically (its first lines delete the old table in the same
# transaction). An ExecStop that deleted it would open a gap on every restart -
# including the one PartOf= triggers whenever docker setup restarts the user
# manager - with the devbox running. Removing the boundary for good is
# `systemctl disable --now` plus `nft delete table inet devbox`.
#
# A function because `doctor host` compares the installed file against it.
netfilter_unit() {
  cat <<UNIT_BODY
# Managed by ./bin/devbox docker setup - do not edit.
[Unit]
Description=Netfilter boundary for devbox project docker ports
Documentation=file://${NFT_CONF}
After=ufw.service nftables.service user@${DEV_UID}.service
Before=docker.service
Wants=user@${DEV_UID}.service
PartOf=user@${DEV_UID}.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f ${NFT_CONF}

[Install]
WantedBy=multi-user.target user@${DEV_UID}.service
UNIT_BODY
}

step_netfilter() {
  local want
  want="$(netfilter_ruleset)"

  if ! command -v nft >/dev/null 2>&1; then
    fail 'nft is not installed - project ports would be published on every interface'
    return 0
  fi
  local conf_changed='false'
  if [[ -f "${NFT_CONF}" ]] && [[ "$(cat "${NFT_CONF}")" == "${want}" ]]; then
    log_success "${NFT_CONF} current"
  elif [[ "${CHECK_ONLY}" == 'true' ]]; then
    fail "${NFT_CONF} missing or stale - project ports would be published on every interface"
  else
    log_info "Writing ${NFT_CONF}..."
    install -d -m 755 "$(dirname "${NFT_CONF}")"
    printf '%s\n' "${want}" >"${NFT_CONF}"
    chmod 644 "${NFT_CONF}"
    conf_changed='true'
  fi

  local want_unit
  want_unit="$(netfilter_unit)"

  # The unit runs `nft -f` once, so a rewritten ruleset is inert until the
  # service is restarted: both files have to be part of the condition, or an
  # updated table sits on disk while the kernel keeps serving the old one.
  if [[ -f "${NFT_UNIT}" ]] && [[ "$(cat "${NFT_UNIT}")" == "${want_unit}" ]] &&
    [[ "${conf_changed}" == 'false' ]] && systemctl is-active --quiet "${NFT_SERVICE}"; then
    log_success "${NFT_SERVICE} active"
    return 0
  fi
  if [[ "${CHECK_ONLY}" == 'true' ]]; then
    fail "${NFT_SERVICE} missing or inactive - project ports would be published on every interface"
    return 0
  fi
  log_info "Enabling ${NFT_SERVICE}..."
  printf '%s\n' "${want_unit}" >"${NFT_UNIT}"
  chmod 644 "${NFT_UNIT}"
  systemctl daemon-reload
  # reenable, not enable: it recreates the [Install] links, so a unit that gained
  # a WantedBy= also gains its symlink. restart, not start: a running instance
  # holds the previous table.
  systemctl reenable --quiet "${NFT_SERVICE}"
  systemctl restart "${NFT_SERVICE}"
  nft list table inet devbox >/dev/null ||
    log_error "the ${NFT_SERVICE} table did not load - check: systemctl status ${NFT_SERVICE}"
  log_success "${NFT_SERVICE} loaded"
}

# -- 5. Socket directory ------------------------------------------------------
# /run/devbox must exist before the daemon starts: rootlesskit copy-ups /run
# into its own mount namespace and symlinks the entries that already exist, so a
# directory created up front is the one place a socket is visible from both
# sides. tmpfiles.d recreates it on every boot.
#
# 0711, not 0700: traverse-by-name for everyone so the deploying user can stat
# the socket (`./bin/devbox up` reports a missing daemon) without being able to
# list the directory. Using it still needs the socket's own 0660 dev:dev.
step_socket_dir() {
  local want="d ${SOCKET_DIR} 0711 ${DEV_USER} ${DEV_GROUP} -"
  if [[ -f "${TMPFILES_CONF}" ]] && grep -qxF "${want}" "${TMPFILES_CONF}"; then
    log_success "${TMPFILES_CONF} present"
  elif [[ "${CHECK_ONLY}" == 'true' ]]; then
    fail "${TMPFILES_CONF} missing or stale"
  else
    log_info "Writing ${TMPFILES_CONF}..."
    printf '%s\n' \
      '# Socket directory for the devbox project Docker daemon (./bin/devbox docker setup).' \
      "${want}" >"${TMPFILES_CONF}"
    chmod 644 "${TMPFILES_CONF}"
    systemd-tmpfiles --create "${TMPFILES_CONF}"
  fi
  if [[ -d "${SOCKET_DIR}" ]]; then
    log_success "${SOCKET_DIR} exists"
  elif [[ "${CHECK_ONLY}" == 'true' ]]; then
    fail "${SOCKET_DIR} missing"
  fi
}

# -- 6. The daemon itself -----------------------------------------------------
# The daemon runs under dev's systemd user manager, and that manager takes its
# configuration from ~/.config and ~/.local/share - the devbox bind mount. A
# unit there outranks the root-owned one below, drop-ins and wants links from
# there are merged in, and environment.d feeds every unit's environment: so
# anything in the container could rewrite the daemon's command line or have
# the host run a service of its own as dev at every boot, without ever
# touching the daemon's API. This drop-in moves both directories somewhere
# root-owned. It closes the files, not the manager's bus: a project container
# that bind-mounts /run/user/<uid> can still start units as dev, which is why
# step_netfilter holds dev's uid, not just the daemon's sockets. A running
# manager keeps the environment it started with, so it only takes effect from
# the manager's next start.
#
# A function because `doctor host` compares the installed file against it.
manager_dropin() {
  cat <<DROPIN
# Managed by ./bin/devbox docker setup - do not edit.
# dev's systemd user manager reads its units, drop-ins and environment.d here,
# not from /home/dev - the devbox bind mount.
[Service]
Environment=XDG_CONFIG_HOME=${MANAGER_CONFIG} XDG_DATA_HOME=${MANAGER_DATA}
DROPIN
}

step_daemon() {
  if loginctl show-user "${DEV_USER}" -p Linger --value 2>/dev/null | grep -qx yes; then
    log_success "linger enabled for ${DEV_USER}"
  elif [[ "${CHECK_ONLY}" == 'true' ]]; then
    fail "linger disabled for ${DEV_USER} - the daemon would stop on logout"
  else
    # Without linger there is no systemd user manager for a never-logged-in
    # account, so the daemon could neither start at boot nor survive.
    log_info "Enabling linger for ${DEV_USER}..."
    loginctl enable-linger "${DEV_USER}"
    local waited=0
    until [[ -d "/run/user/${DEV_UID}" ]] || ((waited >= 50)); do
      sleep 0.2
      waited=$((waited + 1))
    done
    [[ -d "/run/user/${DEV_UID}" ]] || log_error "/run/user/${DEV_UID} never appeared"
  fi

  # Prerequisites only (newuidmap, subordinate ids, kernel support). The tool's
  # `install` path would write the unit into ~/.config/systemd/user - the
  # bind-mounted home, where anything in the container could rewrite the
  # daemon's own command line - and enable it from there.
  if [[ "${CHECK_ONLY}" != 'true' ]]; then
    as_dev dockerd-rootless-setuptool.sh check >/dev/null ||
      log_error 'dockerd-rootless-setuptool.sh check failed - see its output above'
  fi

  # Two flags, because `--ip` alone is not enough: it is the *default* bridge's
  # host binding, so a compose project - which always creates its own
  # user-defined bridge - keeps publishing on 0.0.0.0. Verified on this host:
  # `-p 8098:80` on `bridge` bound 172.17.0.1:8098, the identical spec on a
  # compose network bound 0.0.0.0:8099. `--default-network-opt` applies the same
  # option to every bridge network the daemon creates from now on.
  #
  # This fixes the default, not the boundary: a spec with an explicit
  # `0.0.0.0:` prefix still binds everywhere, and a network created before this
  # flag keeps its stored option. step_netfilter is what makes neither matter.
  local want_unit gateway unit_changed='false'
  gateway="$(bridge_cidr)"
  gateway="${gateway%%/*}"
  want_unit="$(
    cat <<UNIT_BODY
# Managed by ./bin/devbox docker setup - do not edit. Root-owned on purpose: this file
# holds the daemon's command line, and /home/dev is writable from inside the
# devbox container. Modelled on dockerd-rootless-setuptool.sh's own template;
# --data-root is explicit because XDG_DATA_HOME no longer points into /home/dev.
[Unit]
Description=Docker Application Container Engine (Rootless, devbox projects)
Documentation=https://docs.docker.com/go/rootless/
Requires=dbus.socket

[Service]
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/usr/bin/dockerd-rootless.sh --host unix://${SOCKET} --ip ${gateway} \\
  --default-network-opt bridge=com.docker.network.bridge.host_binding_ipv4=${gateway} \\
  --data-root ${DATA_ROOT}
ExecReload=/bin/kill -s HUP \$MAINPID
TimeoutSec=0
RestartSec=2
Restart=always
StartLimitBurst=3
StartLimitInterval=60s
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
Delegate=yes
Type=notify
NotifyAccess=all
KillMode=mixed

[Install]
WantedBy=default.target
UNIT_BODY
  )"

  if [[ -f "${UNIT}" ]] && [[ "$(cat "${UNIT}")" == "${want_unit}" ]]; then
    log_success "${UNIT} current (publish address ${gateway})"
  elif [[ "${CHECK_ONLY}" == 'true' ]]; then
    fail "${UNIT} missing or stale (publish address should be ${gateway})"
  else
    log_info "Writing ${UNIT}..."
    install -d -m 755 "$(dirname "${UNIT}")"
    printf '%s\n' "${want_unit}" >"${UNIT}"
    chmod 644 "${UNIT}"
    systemctl --user --machine="${DEV_USER}@.host" daemon-reload
    unit_changed='true'
  fi

  # The manager's own configuration directories: root-owned, empty but for the
  # wants link that starts the daemon at boot. Root makes that link - `systemctl
  # --user enable` cannot, since the manager runs as dev - and it is written
  # before the drop-in below, so a restarted manager finds the unit current.
  if [[ -L "${WANTS_LINK}" && "$(readlink "${WANTS_LINK}")" == "${UNIT}" ]]; then
    log_success "${WANTS_LINK} present"
  elif [[ "${CHECK_ONLY}" == 'true' ]]; then
    fail "${WANTS_LINK} missing - the daemon would not start at boot"
  else
    log_info "Linking ${WANTS_LINK}..."
    install -d -m 755 "${MANAGER_DIR}" "${MANAGER_CONFIG}" "${MANAGER_CONFIG}/systemd" \
      "${MANAGER_CONFIG}/systemd/user" "$(dirname "${WANTS_LINK}")" "${MANAGER_DATA}"
    ln -sfn "${UNIT}" "${WANTS_LINK}"
  fi

  local manager_changed='false'
  if [[ "$(cat "${MANAGER_DROPIN}" 2>/dev/null)" == "$(manager_dropin)" ]]; then
    log_success "${MANAGER_DROPIN} current"
  elif [[ "${CHECK_ONLY}" == 'true' ]]; then
    fail "${MANAGER_DROPIN} missing or stale - dev's user manager reads its configuration from the bind mount"
  else
    log_info "Writing ${MANAGER_DROPIN}..."
    install -d -m 755 "$(dirname "${MANAGER_DROPIN}")"
    manager_dropin >"${MANAGER_DROPIN}"
    chmod 644 "${MANAGER_DROPIN}"
    systemctl daemon-reload
    manager_changed='true'
  fi

  if [[ "${CHECK_ONLY}" == 'true' ]]; then
    if systemctl --user --machine="${DEV_USER}@.host" show-environment 2>/dev/null |
      grep -qx "XDG_CONFIG_HOME=${MANAGER_CONFIG}"; then
      log_success "dev's user manager reads ${MANAGER_DIR}"
    else
      fail "dev's user manager still reads its configuration from ${DEV_HOME} - it predates the drop-in"
    fi
    if [[ -S "${SOCKET}" ]]; then
      log_success "${SOCKET} live"
    else
      fail "${SOCKET} missing"
    fi
    return 0
  fi
  # Inert once the manager reads elsewhere - removed so nothing suggests
  # otherwise: what the setup tool's own layout and this step's earlier
  # `systemctl --user enable` left in the bind mount. As dev, never root: the
  # devbox owns every directory on these paths and can swap one for a symlink,
  # which a root `rm` would follow out of /home/dev. Cosmetic, so a refusal is
  # only reported.
  as_dev rm -f "${DEV_HOME}/.config/systemd/user/docker.service" \
    "${DEV_HOME}/.config/systemd/user/default.target.wants/docker.service" ||
    log_warn "could not remove the old docker.service files under ${DEV_HOME}/.config/systemd/user"
  if [[ "${manager_changed}" == 'true' ]]; then
    # Restarts the daemon, and every project container with it (those with a
    # restart policy come back); PartOf= also reloads the step_netfilter table.
    log_info "Restarting user@${DEV_UID}.service so dev's user manager reads ${MANAGER_DIR} - project containers restart with the daemon..."
    systemctl restart "user@${DEV_UID}.service"
  elif [[ "${unit_changed}" == 'true' ]]; then
    # `start` leaves an already-running daemon alone, so a rewritten unit would
    # keep serving the old command line until the next reboot.
    log_info 'Restarting the daemon to pick up the new unit...'
    systemctl --user --machine="${DEV_USER}@.host" restart docker
  fi
  log_info 'Starting the daemon...'
  systemctl --user --machine="${DEV_USER}@.host" start docker
  systemctl --user --machine="${DEV_USER}@.host" show-environment | grep -qx "XDG_CONFIG_HOME=${MANAGER_CONFIG}" ||
    log_error "dev's user manager does not read ${MANAGER_DIR} - check: systemctl cat user@${DEV_UID}.service"
  local waited=0
  until [[ -S "${SOCKET}" ]] || ((waited >= 100)); do
    sleep 0.2
    waited=$((waited + 1))
  done
  [[ -S "${SOCKET}" ]] ||
    log_error "${SOCKET} never appeared - check with: systemctl --user --machine=${DEV_USER}@.host status docker"
}

# -- 7. Proof ----------------------------------------------------------------
# The docker CLI as dev, against the project daemon. runuser leaves HOME at
# /home/dev - the bind mount - and the CLI would read ~/.docker/config.json
# (credential helpers, proxies, contexts) and, on `docker info`, execute every
# ~/.docker/cli-plugins/docker-* on this host: its config directory is pointed
# at one that cannot exist.
dev_docker() {
  as_dev env DOCKER_HOST="unix://${SOCKET}" DOCKER_CONFIG=/nonexistent docker "$@"
}

step_smoke() {
  local server security
  server="$(dev_docker version -f '{{ .Server.Version }}')"
  security="$(dev_docker info -f '{{ .SecurityOptions }}')"
  grep -q 'rootless' <<<"${security}" || log_error "the daemon is not rootless: ${security}"
  log_success "rootless dockerd ${server} on ${SOCKET}"
  log_info 'Running hello-world as a smoke test...'
  dev_docker run --rm hello-world >/dev/null
  log_success 'container ran and exited cleanly'
}
