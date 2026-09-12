#!/usr/bin/env bash
# Idempotent per-user setup for the devbox. Runs as `dev` from the entrypoint on
# every container start, and by hand through `./bin/devbox bootstrap`. Every step
# is guarded, so a re-run is a no-op that only reprints the checklist.
set -euo pipefail

log_info() { echo -e "\033[0;34m[INFO]\033[0m  $*"; }
log_success() { echo -e "\033[0;32m[OK]\033[0m    $*"; }
log_warn() { echo -e "\033[1;33m[WARN]\033[0m  $*" >&2; }

readonly HOME_DIR="${HOME:-/home/dev}"
readonly SSH_DIR="${HOME_DIR}/.ssh"
readonly TEMPLATE_DIR='/opt/devbox/home'

export PATH="${HOME_DIR}/.local/bin:${PATH}"

# Manual, human-only follow-ups collected while bootstrapping and printed once at
# the end. Nothing here is ever attempted automatically.
declare -a ACTIONS=()
register_action() { ACTIONS+=("$1"); }

# -- 1. OMP -------------------------------------------------------------------
# Deliberately not in the image: installing it here to ~/.local/bin (the
# installer's default PI_INSTALL_DIR, on the bind mount) keeps `omp update`
# working without an image rebuild.
if command -v omp >/dev/null 2>&1; then
  log_info "OMP already installed: $(command -v omp)"
else
  log_info 'Installing OMP...'
  curl -fsSL https://omp.sh/install.sh | sh
fi

# -- 2. SSH identity keys -----------------------------------------------------
# Passphrase-less and generated in place: the private keys never leave the bind
# mount, are per-host and individually revocable on GitHub, and unattended agents
# must be able to push without a passphrase prompt.
for identity in personal work; do
  key="${SSH_DIR}/id_${identity}"
  if [[ ! -f "${key}" ]]; then
    log_info "Generating ${key}..."
    ssh-keygen -q -t ed25519 -N '' -C "devbox-${identity}" -f "${key}"
    register_action "Add ${key}.pub to GitHub twice - once as an Authentication key, once as a Signing key."
  fi
  chmod 600 "${key}"
  chmod 644 "${key}.pub"
done

# -- 3. ~/.ssh/config ---------------------------------------------------------
# Rendered every run: it is generated, not hand-edited.
install -m 600 "${TEMPLATE_DIR}/.ssh/config.tpl" "${SSH_DIR}/config"

# -- 4. known_hosts -----------------------------------------------------------
# Seeded from the authenticated GitHub meta API. Without it the first
# agent-driven `git push` blocks forever on a TOFU prompt.
known_hosts="${SSH_DIR}/known_hosts"
if ! grep -q '^github.com ' "${known_hosts}" 2>/dev/null; then
  log_info 'Seeding GitHub host keys into known_hosts...'
  if github_keys="$(curl -fsSL --max-time 15 https://api.github.com/meta | jq -r '.ssh_keys[]')" &&
    [[ -n "${github_keys}" ]]; then
    {
      [[ -f "${known_hosts}" ]] && cat "${known_hosts}"
      while IFS= read -r github_key; do
        [[ -n "${github_key}" ]] && printf 'github.com %s\n' "${github_key}"
      done <<<"${github_keys}"
    } | sort -u >"${known_hosts}.new"
    mv "${known_hosts}.new" "${known_hosts}"
    chmod 600 "${known_hosts}"
  else
    log_warn 'Could not fetch https://api.github.com/meta; known_hosts left untouched.'
    register_action "Seed GitHub host keys: ssh-keyscan github.com >> ${known_hosts}"
  fi
fi

# -- 5. ~/.gitconfig ---------------------------------------------------------
# Template copy once (aliases, colors, whitespace rules), then always re-apply the
# derived values, so regenerated identity settings never fight hand edits.
gitconfig="${HOME_DIR}/.gitconfig"
if [[ ! -f "${gitconfig}" ]]; then
  log_info 'Installing ~/.gitconfig from the template...'
  install -m 644 "${TEMPLATE_DIR}/.gitconfig" "${gitconfig}"
fi

git config --global user.name "${GIT_PERSONAL_NAME:-}"
git config --global user.email "${GIT_PERSONAL_EMAIL:-}"
git config --global user.signingkey "${SSH_DIR}/id_personal.pub"
# The macOS laptop signs through 1Password's op-ssh-sign, which has no headless
# Linux equivalent; git's default ssh-keygen signer is used instead.
git config --global gpg.format ssh
git config --global commit.gpgsign true
git config --global tag.gpgsign true
git config --global gpg.ssh.allowedSignersFile "${SSH_DIR}/allowed_signers"
git config --global init.defaultBranch main
git config --global pull.rebase true
git config --global pull.ff only
git config --global push.default simple
git config --global push.followTags true
# shellcheck disable=SC2088 # git expands `~` in include paths itself
git config --global includeIf.'gitdir:~/projects/work/'.path '~/.config/work/.gitconfig'

# -- 6. work identity ------------------------------------------------------
mkdir -p "${HOME_DIR}/.config/work"
work_gitconfig="${HOME_DIR}/.config/work/.gitconfig"
git config --file "${work_gitconfig}" user.name "${GIT_WORK_NAME:-}"
git config --file "${work_gitconfig}" user.email "${GIT_WORK_EMAIL:-}"
git config --file "${work_gitconfig}" user.signingkey "${SSH_DIR}/id_work.pub"
# Rewrites existing `git@github.com:` remotes inside ~/projects/work/ onto the
# work key. New clones must use the alias directly
# (`git clone github-work:<org>/<repo> ~/projects/work/<repo>`), because URL
# rewriting from an includeIf file cannot apply before the repo directory exists.
git config --file "${work_gitconfig}" url.'github-work:'.insteadOf 'git@github.com:'

# -- 7. allowed_signers -------------------------------------------------------
# So `git log --show-signature` verifies locally.
{
  printf '%s %s\n' "${GIT_PERSONAL_EMAIL:-}" "$(cut -d' ' -f1,2 "${SSH_DIR}/id_personal.pub")"
  printf '%s %s\n' "${GIT_WORK_EMAIL:-}" "$(cut -d' ' -f1,2 "${SSH_DIR}/id_work.pub")"
} >"${SSH_DIR}/allowed_signers"
chmod 644 "${SSH_DIR}/allowed_signers"

# -- 8. work-app GitHub App credentials ---------------------------------
# Secrets: bootstrap creates the directory and never fetches the contents.
creds_dir="${HOME_DIR}/.config/work/work-app"
mkdir -p "${creds_dir}"
chmod 700 "${creds_dir}"
if [[ ! -f "${creds_dir}/app.pem" ]]; then
  register_action "Place the work-app app credentials: printf '%s' '<app-id>' > ${creds_dir}/app-id, copy the private key to ${creds_dir}/app.pem from the laptop, then chmod 600 ${creds_dir}/app.pem"
fi

# -- 9. Shell -----------------------------------------------------------------
install -d -m 755 "${HOME_DIR}/.bashrc.d"
install -m 644 "${TEMPLATE_DIR}/.bashrc.d/devbox.sh" "${HOME_DIR}/.bashrc.d/devbox.sh"

# The bind mount shadows the image's /home/dev, so a fresh data directory has no
# dotfiles at all - and without ~/.profile a login shell (herdr panes,
# `./bin/devbox shell`) never sources ~/.bashrc. Seed the distro skeleton;
# `cp -n` never touches a file the user already has.
cp -n /etc/skel/.bashrc /etc/skel/.profile /etc/skel/.bash_logout "${HOME_DIR}/" 2>/dev/null || true

bashrc="${HOME_DIR}/.bashrc"
touch "${bashrc}"
if ! grep -q '.bashrc.d' "${bashrc}"; then
  log_info 'Registering ~/.bashrc.d/*.sh in ~/.bashrc...'
  # Prepended, not appended: Ubuntu's skeleton ~/.bashrc returns early for
  # non-interactive shells, and `ssh devbox <cmd>` (how agents and tooling call
  # in) is exactly that. devbox.sh guards its own interactive-only parts.
  loader="$(mktemp)"
  cat >"${loader}" <<'BASHRC'
# -- devbox -------------------------------------------------------------------
for devbox_rc in "$HOME"/.bashrc.d/*.sh; do
  [ -r "$devbox_rc" ] && . "$devbox_rc"
done
unset devbox_rc

BASHRC
  cat "${bashrc}" >>"${loader}"
  mv "${loader}" "${bashrc}"
  chmod 644 "${bashrc}"
fi

if ! grep -q worktrunk "${bashrc}"; then
  log_info 'Installing the worktrunk shell integration...'
  # `wt config shell install` has no --yes flag and reads a confirmation from
  # stdin, which is closed here; feed it one.
  printf 'y\n' | wt config shell install bash || log_warn 'wt config shell install failed; run it by hand.'
fi

# -- 10. Tool credentials -----------------------------------------------------
# One box-wide file of plain KEY=value pairs, sourced by every shell (see
# home/.bashrc.d/devbox.sh) so `ssh devbox <cmd>` sees the same environment a
# pane does. Deliberately not 1Password-backed: the container holds no vault
# access, so values are written here by hand or rendered on the laptop and
# copied in. Per-project secrets belong in the project's own .env, never here.
secrets_dir="${HOME_DIR}/.config/devbox"
mkdir -p "${secrets_dir}"
chmod 700 "${secrets_dir}"
secrets_file="${secrets_dir}/secrets.env"
if [[ ! -f "${secrets_file}" ]]; then
  install -m 600 "${TEMPLATE_DIR}/.config/devbox/secrets.env.example" "${secrets_file}"
  register_action "Fill ${secrets_file} with GH_TOKEN and any model API keys, then reconnect."
fi
# A credential file that became group- or world-readable is worth fixing
# silently; it is on the bind mount and survives every rebuild.
chmod 600 "${secrets_file}"

# Leftovers from the op-era layout. /home/dev outlives every rebuild, so a file
# written when `op run` resolved these references is still here - and this file
# is now sourced directly, which would export the literal `op://...` string into
# every shell. Warn instead of editing someone's credential file.
if grep -q 'op://' "${secrets_file}" 2>/dev/null; then
  log_warn "${secrets_file} still holds op:// references; they are now exported verbatim."
  register_action "Replace the op:// references in ${secrets_file} with plain values (op is no longer installed; render them on the laptop)"
fi
if [[ -f "${secrets_dir}/secrets.work.env" ]]; then
  register_action "Delete the orphaned ${secrets_dir}/secrets.work.env (the per-account op files are gone; one secrets.env now serves every project)"
fi

# Read here so the gh check below sees the same GH_TOKEN an interactive shell
# would: bootstrap runs from the entrypoint and under `docker compose exec`,
# neither of which sources ~/.bashrc.
if [[ -r "${secrets_file}" ]]; then
  set -a
  # shellcheck source=/dev/null # a runtime credential file, not repo content
  . "${secrets_file}"
  set +a
fi

# -- 11. gh -------------------------------------------------------------------
# `gh auth status` also succeeds on a GH_TOKEN from secrets.env, which is the
# intended path: a fine-grained, expiring, read-mostly token beats the full
# read/write OAuth scopes `gh auth login --web` stores in plaintext here.
gh config set git_protocol ssh
if ! gh auth status >/dev/null 2>&1; then
  register_action "Add a fine-grained GitHub token to ${secrets_file} as GH_TOKEN (scopes: contents/actions/checks read, plus issues or pull-requests write only if agents should post)"
fi

# -- 12. OMP config -----------------------------------------------------------
omp_config_dir="${HOME_DIR}/.omp/agent"
mkdir -p "${omp_config_dir}"
if [[ ! -f "${omp_config_dir}/config.yml" ]]; then
  log_info 'Seeding ~/.omp/agent/config.yml...'
  install -m 644 "${TEMPLATE_DIR}/.omp/agent/config.yml" "${omp_config_dir}/config.yml"
fi

# -- 13. Summary --------------------------------------------------------------
echo
echo '== devbox identity =========================================================='
for identity in personal work; do
  printf '%-10s %s\n' "${identity}" "$(cat "${SSH_DIR}/id_${identity}.pub")"
done
echo
echo 'sshd host key fingerprint:'
ssh-keygen -lf "${SSH_DIR}/host/ssh_host_ed25519_key.pub"

if ((${#ACTIONS[@]} > 0)); then
  echo
  echo '== remaining manual steps =================================================='
  for action in "${ACTIONS[@]}"; do
    echo "  - ${action}"
  done
fi
echo '============================================================================'
log_success 'Bootstrap complete.'
