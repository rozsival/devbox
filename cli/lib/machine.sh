# Which side of the devbox this is. The workstation is the Linux host running
# the container; the laptop is the macOS machine deploying to it. The container
# is neither: it has the repo at /opt/devbox, but no docker and no 1Password.
in_container() { [[ -f /.dockerenv ]]; }
on_host() { [[ "$(uname -s)" == Linux ]] && ! in_container; }
on_laptop() { [[ "$(uname -s)" == Darwin ]]; }

filter_host() {
  on_host || echo 'This is a workstation command: run it on the Linux host that runs the devbox container.'
}

filter_laptop() {
  on_laptop || echo 'This is a laptop command: run it on the macOS machine you deploy from.'
}

filter_machine() {
  on_host || on_laptop || echo 'Run this on the workstation or the laptop: the container has no bin/devbox of its own.'
}

# Per-laptop SSH aliases (DEVBOX_HOST, DEVBOX_SSH_HOST) live in the gitignored
# .push.env rather than in the repo: a literal here would be one machine's name
# shipped to everyone else.
load_push_env() {
  [[ -f "${REPO_ROOT}/.push.env" ]] || return 0
  # shellcheck source=/dev/null # per-laptop, not repo content
  . "${REPO_ROOT}/.push.env"
}

# perl rather than stat: BSD and GNU stat disagree on flags, and both may be on
# a macOS PATH (coreutils' gnubin ahead of /usr/bin).
file_mode() {
  perl -e 'printf "%o\n", (stat $ARGV[0])[2] & 07777' "$1"
}
