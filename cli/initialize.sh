# Runs before any command. bin/devbox is generated into the repo's bin/, so the
# repo root is one level up from it on both machines.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly ENV_FILE="${REPO_ROOT}/.env"
readonly ENV_EXAMPLE="${REPO_ROOT}/.env.example"
readonly TEMPLATE_DIR="${REPO_ROOT}/home"
readonly SERVICE='devbox'

# The laptop's install layout - the same one bootstrap creates in the container.
readonly LIBEXEC_DIR="${HOME}/.local/libexec"
readonly AGENT_DIR="${LIBEXEC_DIR}/devbox-agent"
readonly LAUNCHER_DIR="${AGENT_DIR}/launchers"
readonly BIN_DIR="${HOME}/.local/bin"
readonly CONFIG_DIR="${HOME}/.config/devbox"
readonly SSH_DIR="${HOME}/.ssh"

# `fail` counts instead of exiting, so a doctor or a --check reports everything
# that is wrong before the exit status says so; CHECK_ONLY turns the provisioning
# steps into reports.
failures=0
CHECK_ONLY='false'
