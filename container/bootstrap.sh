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

export PATH="${HOME_DIR}/.local/libexec/devbox-agent:${HOME_DIR}/.local/bin:${PATH}"

# Manual, human-only follow-ups collected while bootstrapping and printed once at
# the end. Nothing here is ever attempted automatically.
declare -a ACTIONS=()
register_action() { ACTIONS+=("$1"); }

# -- 1. OMP -------------------------------------------------------------------
# Deliberately not in the image: installing it here to ~/.local/bin (the
# installer's default PI_INSTALL_DIR, on the bind mount) keeps `omp update`
# working without an image rebuild. Checked by path, not `command -v`: the
# launcher installed in §12 answers to `omp` on the PATH set above.
if [[ -x "${HOME_DIR}/.local/bin/omp" ]]; then
  log_info "OMP already installed: ${HOME_DIR}/.local/bin/omp"
else
  log_info 'Installing OMP...'
  curl -fsSL https://omp.sh/install.sh | sh
fi

# -- 2. Identity registry -----------------------------------------------------
# One file decides who this box is in which tree: ~/.config/devbox/
# identities.conf, read through devbox-identities and by nothing else. Both are
# installed before anything derived from them runs. The config lives on the bind
# mount, so it survives every rebuild, and it is the same file the laptop holds
# (./bin/sync-identities copies it over) - which is why no identity is named in
# .env, in docker-compose.yml or anywhere in this script.
secrets_dir="${HOME_DIR}/.config/devbox"
git_config_dir="${secrets_dir}/git"
libexec_dir="${HOME_DIR}/.local/libexec"
install -d -m 755 "${HOME_DIR}/.local/bin" "${libexec_dir}"
install -m 755 "${TEMPLATE_DIR}/.local/libexec/devbox-identities" "${libexec_dir}/devbox-identities"
# Reachable by name: it is a user-facing inspector (`devbox-identities check`,
# `for`, `show`) that the docs and every checklist tell people to run, and
# devbox.sh puts ~/.local/bin on the PATH while ~/.local/libexec is deliberately
# not. A symlink rather than a copy, so laptop-doctor's byte comparison keeps
# having exactly one file to compare.
ln -sfn "${libexec_dir}/devbox-identities" "${HOME_DIR}/.local/bin/devbox-identities"
install -d -m 700 "${secrets_dir}"

identities_file="${secrets_dir}/identities.conf"
# Deliberately NOT seeded from the example. The example is a *valid* file - it
# has to be, to be worth copying - so seeding it would let the identity steps
# below run against `Your Name <you@example.com>` and quietly re-stamp a box
# that already had an identity. An absent file fails the check instead, which
# writes nothing and puts the copy command in the checklist.
if [[ ! -f "${identities_file}" ]]; then
  register_action "Create ${identities_file}: cp /opt/devbox/home/.config/devbox/identities.conf.example ${identities_file} and fill in one [slug] block per account (name, email, the laptop's public keys, optionally a GitHub App directory), then ./bin/devbox bootstrap - until then this box has no git identity"
fi

# A broken registry must cost configuration, never SSH access: everything
# derived from it is skipped in one place and the checklist says so. The
# library is sourced rather than shelled out to, so the sections below can use
# di_* directly.
# shellcheck source=../home/.local/libexec/devbox-identities
. "${libexec_dir}/devbox-identities"
identities_ok=true
if ! di_check; then
  identities_ok=false
  log_warn 'identities.conf is not usable; no identity-derived configuration written this run.'
  # Only when the file exists: a missing one already has its "create it" action
  # above, and two entries for one cause read like two problems.
  if [[ -f "${identities_file}" ]]; then
    register_action "Fix ${identities_file} (./bin/devbox shell -- devbox-identities check prints every problem), then ./bin/devbox bootstrap"
  fi
fi

if ${identities_ok}; then
  slugs="$(di_slugs)"

  # -- 3. SSH identities: public keys only ------------------------------------
  # The devbox generates no keys and holds no private key for any forge. Manual
  # git work as yourself runs over the laptop's forwarded 1Password agent; the
  # public keys installed here are what selects the right forwarded key per
  # account (IdentitiesOnly + IdentityFile <pub> in ~/.ssh/config) and what git
  # names as the signing key. Two files per identity because GitHub registers
  # authentication and signing keys separately and each account uses a different
  # key for each; signing with the auth key verifies locally and shows
  # Unverified on GitHub. Agent sessions never see the forwarded agent: their
  # git goes over HTTPS with per-operation tokens (§12).
  mkdir -p "${SSH_DIR}"
  chmod 700 "${SSH_DIR}"
  for slug in ${slugs}; do
    for pair in 'id:pubkey:authentication' 'signing:signing_pubkey:signing'; do
      prefix="${pair%%:*}"
      field="${pair#*:}"
      what="${field#*:}"
      field="${field%%:*}"
      file="${SSH_DIR}/${prefix}_${slug}.pub"
      value="$(di_get "${slug}" "${field}")"
      if [[ -n ${value} ]]; then
        printf '%s\n' "${value}" >"${file}"
        chmod 644 "${file}"
      elif [[ ! -f "${file}" ]]; then
        register_action "Set ${field} for [${slug}] in ${identities_file} to the laptop's ${what} public key, then ./bin/devbox bootstrap"
      fi
    done
    # A private key generated by an earlier bootstrap is exactly what this
    # layout removes. Its fingerprint goes into the checklist first, because
    # once the file is gone nothing here can name the GitHub entry to revoke.
    if [[ -f "${SSH_DIR}/id_${slug}" ]]; then
      fingerprint="$(ssh-keygen -lf "${SSH_DIR}/id_${slug}.pub" 2>/dev/null | cut -d' ' -f2 || printf 'unknown')"
      rm -f "${SSH_DIR}/id_${slug}"
      log_warn "Removed the devbox-generated private key ${SSH_DIR}/id_${slug}; revoke it on GitHub."
      register_action "Revoke the retired devbox-${slug} key on GitHub (fingerprint ${fingerprint}) - both its Authentication and its Signing entry"
    fi
  done

  # -- 4. ~/.ssh/config -------------------------------------------------------
  # Rendered every run: it is generated, not hand-edited. One block per forge
  # host; the key comes from the ssh tag git passes for an identity's orgs
  # (`ssh -P <slug>`, §7), else the host's plain key - no alias hosts.
  rendered="$(mktemp)"
  di_render_ssh_config >"${rendered}"
  install -m 600 "${rendered}" "${SSH_DIR}/config"
  rm -f "${rendered}"

  # -- 5. known_hosts ---------------------------------------------------------
  # Seeded from each forge's own meta API. Without it the first agent-driven
  # `git push` blocks forever on a TOFU prompt.
  known_hosts="${SSH_DIR}/known_hosts"
  for slug in ${slugs}; do
    host="$(di_get "${slug}" host)"
    grep -q "^${host} " "${known_hosts}" 2>/dev/null && continue
    log_info "Seeding ${host} host keys into known_hosts..."
    if host_keys="$(curl -fsSL --max-time 15 "$(di_get "${slug}" api)/meta" | jq -r '.ssh_keys[]?')" &&
      [[ -n "${host_keys}" ]]; then
      {
        [[ -f "${known_hosts}" ]] && cat "${known_hosts}"
        while IFS= read -r host_key; do
          [[ -n "${host_key}" ]] && printf '%s %s\n' "${host}" "${host_key}"
        done <<<"${host_keys}"
      } | sort -u >"${known_hosts}.new"
      mv "${known_hosts}.new" "${known_hosts}"
      chmod 600 "${known_hosts}"
    else
      log_warn "Could not fetch $(di_get "${slug}" api)/meta; known_hosts left untouched."
      register_action "Seed ${host} host keys: ssh-keyscan ${host} >> ${known_hosts}"
    fi
  done

  # -- 6. ~/.gitconfig --------------------------------------------------------
  # Template copy once (aliases, colors, whitespace rules), then always re-apply
  # the derived values, so regenerated identity settings never fight hand edits.
  gitconfig="${HOME_DIR}/.gitconfig"
  if [[ ! -f "${gitconfig}" ]]; then
    log_info 'Installing ~/.gitconfig from the template...'
    install -m 644 "${TEMPLATE_DIR}/.gitconfig" "${gitconfig}"
  fi

  default_slug="$(di_default)"
  git config --global user.name "$(di_get "${default_slug}" name)"
  git config --global user.email "$(di_get "${default_slug}" email)"
  # Your own commits in a pane sign with the laptop key behind the forwarded
  # 1Password agent: ssh-keygen -Y sign takes a public key file and signs
  # through SSH_AUTH_SOCK when no private key is on disk. Without a forwarded
  # agent a manual commit fails to sign, which is the intended shape of the
  # escape hatch.
  git config --global user.signingkey "${SSH_DIR}/signing_${default_slug}.pub"
  git config --global gpg.format ssh
  git config --global commit.gpgsign true
  git config --global tag.gpgsign true
  git config --global gpg.ssh.allowedSignersFile "${SSH_DIR}/allowed_signers"
  git config --global init.defaultBranch main
  git config --global pull.rebase true
  git config --global pull.ff only
  git config --global push.default simple
  git config --global push.followTags true

  # -- 7. Your identity per tree and per GitHub owner -------------------------
  # Two kinds of generated file, both included from ~/.gitconfig:
  #   user-<slug>.gitconfig  author + signing key, by `gitdir:` for its `dir`
  #   org-<slug>.gitconfig   the same plus `core.sshCommand = ssh -P <slug>`,
  #                          by `hasconfig:remote.*.url:` for its `orgs` - which
  #                          holds during a first `git clone`, so remotes stay
  #                          plain `git@<host>:<org>/<repo>`
  # The include lists are rewritten every run: an identity that was renamed or
  # dropped leaves an entry behind otherwise, and git would keep applying a
  # stale name, email, signing key or ssh tag.
  # Read-only from §13 on; lifted back here because this run regenerates it.
  install -d -m 700 "${git_config_dir}"
  chmod 700 "${git_config_dir}"
  rm -f "${git_config_dir}"/user-*.gitconfig "${git_config_dir}"/org-*.gitconfig
  # Only entries pointing at a file this script generates. ~/.gitconfig is
  # "template once, hand edits kept", so an includeIf the user added for
  # something of their own must survive every start - sweeping the whole
  # `includeIf.*` namespace would delete it on the next boot.
  while IFS= read -r entry; do
    [[ ${entry} == *"${git_config_dir}/user-"*.gitconfig || ${entry} == *"${git_config_dir}/org-"*.gitconfig ]] || continue
    git config --global --unset-all "${entry%% *}" 2>/dev/null || true
  done < <(git config --global --get-regexp '^includeif\.(gitdir|hasconfig):.*\.path$' 2>/dev/null || true)
  # Shortest `dir` first: git applies every matching include and the last one
  # read wins, so a nested tree's identity has to be written last.
  for slug in $(di_dir_slugs); do
    # The tree itself, so a clone into it works on a fresh box and so `git`
    # resolves the include path against a real directory. The entrypoint
    # creates ~/projects and stops there: only the registry knows the names.
    mkdir -p "$(di_get "${slug}" dir)"
    rendered="$(mktemp)"
    di_render_user_gitconfig "${slug}" >"${rendered}"
    install -m 444 "${rendered}" "${git_config_dir}/user-${slug}.gitconfig"
    rm -f "${rendered}"
    git config --global "includeIf.gitdir:$(di_get "${slug}" dir)/.path" "${git_config_dir}/user-${slug}.gitconfig"
  done
  # After every `gitdir:` include, so the owner wins over the tree: a personal
  # repository cloned into a work tree still pushes with your personal key.
  for slug in ${slugs}; do
    [[ -n "$(di_get "${slug}" orgs)" ]] || continue
    rendered="$(mktemp)"
    di_render_org_gitconfig "${slug}" >"${rendered}"
    install -m 444 "${rendered}" "${git_config_dir}/org-${slug}.gitconfig"
    rm -f "${rendered}"
    while IFS= read -r url; do
      git config --global "includeIf.hasconfig:remote.*.url:${url}.path" "${git_config_dir}/org-${slug}.gitconfig"
    done < <(di_org_urls "${slug}")
  done
  # Clones from the SSH-alias era: nothing resolves `git@<slug>.<host>:` now.
  # Named, not rewritten - a project's remotes are the user's.
  stale_remotes="$(di_alias_remotes | awk '{printf "%sgit -C %s remote set-url %s %s", sep, $1, $2, $3; sep = "; "}')"
  [[ -z ${stale_remotes} ]] ||
    register_action "Point clones still on an SSH alias at the plain host (aliases are gone; orgs select the key): ${stale_remotes}"

  # -- 8. allowed_signers -----------------------------------------------------
  # So `git log --show-signature` verifies your own commits locally; agent
  # commits are unsigned by design (§12).
  di_render_allowed_signers >"${SSH_DIR}/allowed_signers"
  chmod 644 "${SSH_DIR}/allowed_signers"

  # -- 9. GitHub App credentials ----------------------------------------------
  # Secrets: bootstrap creates each `app` directory and never fetches the
  # contents. The credential helper (§12) mints a repository-scoped installation
  # token from them for every git operation on a repository the App is installed
  # on, and falls back to that identity's PAT everywhere else.
  for slug in ${slugs}; do
    creds_dir="$(di_get "${slug}" app)"
    [[ -n ${creds_dir} ]] || continue
    mkdir -p "${creds_dir}"
    chmod 700 "${creds_dir}"
    if [[ ! -f "${creds_dir}/app.pem" ]]; then
      register_action "Place the [${slug}] App credentials: printf '%s' '<app-id>' > ${creds_dir}/app-id, copy the private key to ${creds_dir}/app.pem from the laptop, then chmod 600 ${creds_dir}/app.pem - until then agents push those repositories with the PAT"
    fi
  done
fi

# -- 10. Shell ----------------------------------------------------------------
install -d -m 755 "${HOME_DIR}/.bashrc.d"
install -m 644 "${TEMPLATE_DIR}/.bashrc.d/devbox.sh" "${HOME_DIR}/.bashrc.d/devbox.sh"

# The bind mount shadows the image's /home/dev, so a fresh data directory has no
# dotfiles at all - and without ~/.profile a login shell (herdr panes,
# `./bin/devbox shell`) never sources ~/.bashrc. Seed the distro skeleton;
# `cp -n` never touches a file the user already has.
cp -n /etc/skel/.bashrc /etc/skel/.profile /etc/skel/.bash_logout "${HOME_DIR}/" 2>/dev/null || true

# Bash prefers ~/.bash_profile over ~/.profile for login shells, and this one
# runs ~/.profile first: the skeleton file ends by prepending ~/.local/bin,
# *after* it has sourced ~/.bashrc, which put the real omp binary ahead of the
# agent launcher in every login shell (an interactive `ssh devbox`, a herdr
# pane, `./bin/devbox shell`). Generated, reinstalled on every run.
install -m 644 "${TEMPLATE_DIR}/.bash_profile" "${HOME_DIR}/.bash_profile"

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

# -- 11. Tool credentials -----------------------------------------------------
# One box-wide file of plain KEY=value pairs, sourced by every shell (see
# home/.bashrc.d/devbox.sh) so `ssh devbox <cmd>` sees the same environment a
# pane does. Deliberately not 1Password-backed: the container holds no vault
# access, so values are written here by hand or rendered on the laptop and
# copied in. Per-project secrets belong in the project's own .env, never here.
# The directory itself is created in §2, beside identities.conf.
secrets_file="${secrets_dir}/secrets.env"
if [[ ! -f "${secrets_file}" ]]; then
  install -m 600 "${TEMPLATE_DIR}/.config/devbox/secrets.env.example" "${secrets_file}"
  register_action "Fill ${secrets_file} with one GH_TOKEN_<IDENTITY> per identity in ${identities_file} and any model API keys, then reconnect."
fi
# A credential file that became group- or world-readable is worth fixing
# silently; it is on the bind mount and survives every rebuild.
chmod 600 "${secrets_file}"

# Leftovers from the op-era layout. /home/dev outlives every rebuild, so a file
# written when `op run` resolved these references is still here - and this file
# is now sourced directly, which would export the literal `op://...` string into
# every shell. Warn instead of editing someone's credential file.
#
# Assignments only: the shipped template mentions `op://` in a comment, so a
# bare `grep op://` would flag every fresh install.
if grep -qE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=.*op://' "${secrets_file}" 2>/dev/null; then
  log_warn "${secrets_file} still holds op:// references; they are now exported verbatim."
  register_action "Replace the op:// references in ${secrets_file} with plain values (op is no longer installed; render them on the laptop)"
fi

# -- 12. gh -------------------------------------------------------------------
# One fine-grained token per account, chosen from the working directory by the
# same rule git uses for identities: the `dir` prefixes in identities.conf.
# The `gh` shim resolves it per invocation, because an agent's cwd is a project
# while the shell that started it was opened in $HOME - a GH_TOKEN exported at
# startup would pin one account for the whole session. The shim lives in the
# agent directory (§13), which devbox.sh puts first on every PATH here.
#
# `gh auth login` is deliberately not part of this: its web flow can only ask
# for `repo` + `read:org` + `gist` (the floor is hard-coded upstream; `--scopes`
# only adds), i.e. non-expiring read/write on every repo either account can
# reach, stored in plaintext because the container has no keyring.
install -d -m 755 "${HOME_DIR}/.local/bin"
install -m 755 "${TEMPLATE_DIR}/.local/bin/devbox-gh-token" "${HOME_DIR}/.local/bin/devbox-gh-token"
rm -f "${HOME_DIR}/.local/bin/gh" # pre-§13 location of the shim
agent_dir="${HOME_DIR}/.local/libexec/devbox-agent"
install -d -m 755 "${agent_dir}"
install -m 755 "${TEMPLATE_DIR}/.local/libexec/devbox-agent/gh" "${agent_dir}/gh"

# Every `gh` here goes through that shim: the agent directory is first on the
# PATH exported at the top of this script. stderr is dropped because the shim
# reports an unconfigured account on every call, and the checklist below says
# the same thing once, in the place people actually read.
gh config set git_protocol ssh 2>/dev/null

# A plain GH_TOKEN= line still works - the resolver returns it for every
# directory - but it overrides every per-account variable, so nothing is ever
# chosen per tree. Grep the file rather than the environment: this is advice
# about secrets.env, not about whatever the caller happens to export.
if grep -qE '^[[:space:]]*GH_TOKEN=' "${secrets_file}" 2>/dev/null; then
  log_warn "${secrets_file} sets a box-wide GH_TOKEN; it overrides the per-account tokens."
  register_action "Split the box-wide GH_TOKEN in ${secrets_file} into one GH_TOKEN_<IDENTITY> per identity in ${identities_file} (as written, the per-directory choice never applies)"
fi

# One check per identity, driven by the registry: the directory that selects it
# is the only input the resolver takes. Adding an account is a block in
# identities.conf and a token in secrets.env - nothing here changes.
if ${identities_ok}; then
  for slug in ${slugs}; do
    dir="$(di_get "${slug}" dir)"
    # Ask the resolver instead of reading the variables here, so this check
    # exercises the exact path `gh` takes - including secrets.env being read
    # directly - and needs no assumption about bootstrap's own cwd.
    if ! token="$(devbox-gh-token "${dir:-${HOME_DIR}}" 2>/dev/null)" || [[ -z "${token}" ]]; then
      register_action "Add a fine-grained GitHub token for the ${slug} account to ${secrets_file} as $(di_get "${slug}" token_var) (contents write on the repositories agents push without an App; actions and checks read; issues or pull-requests write only if agents should post)"
    elif ! GH_TOKEN="${token}" GH_HOST="$(di_get "${slug}" host)" timeout 15 gh auth status >/dev/null 2>&1; then
      # Present but rejected - expired, revoked, or the forge unreachable; a
      # variable-is-set check cannot see any of those. `timeout` because this
      # runs from the entrypoint before `exec sshd`: no check may delay SSH
      # access.
      register_action "The GitHub token for the ${slug} account is rejected by gh - check expiry and revocation (or network, if this box just came up) and re-issue it in ${secrets_file}"
    fi
  done
fi

# -- 13. Agent git override ---------------------------------------------------
# What makes one clone serve both you and an agent: the `omp` launcher exports
# GIT_CONFIG_GLOBAL=~/.config/devbox/git/agent.gitconfig (HTTPS rewrites, the
# per-operation credential helper, the bot author, signing off) and a
# GIT_SSH_COMMAND that refuses, for its own process tree only. The directory is
# first on the PATH from devbox.sh so `omp` resolves to the launcher ahead of
# ~/.local/bin/omp. All generated files: reinstalled on every run.
#
# `omp` here is a symlink to the launcher script, never the script itself:
# `omp update` resolves what to replace by looking `omp` up on the PATH, and
# would take over a plain file in place. The launcher drops its own PATH entries
# for that subcommand so the update lands on ~/.local/bin/omp (§1); the symlink
# is the backstop, since the updater refuses to replace a script behind one.
for tool in omp-launcher devbox-git-credential devbox-git-no-ssh; do
  install -m 755 "${TEMPLATE_DIR}/.local/libexec/devbox-agent/${tool}" "${agent_dir}/${tool}"
done
ln -sfn "${agent_dir}/omp-launcher" "${agent_dir}/omp"

# The gitconfigs and their directory are read-only: GIT_CONFIG_GLOBAL points in
# there, so `git config --global` in a session would rewrite them - on the
# laptop one such call replaced the agent author with the user's own name and
# email, and five commits carried it. git needs a lock file beside the config it
# rewrites, so a directory without write permission is what stops it;
# reinstalling is why both modes are lifted here first.
#
# Rendered, not copied: the root file comes from agent.gitconfig.tpl with the
# registry's hosts and trees substituted in, and one
# agent-<slug>.gitconfig per identity that claims a tree - every one of them,
# including those inheriting the default author, because git applies every
# matching include and a nested tree would otherwise keep the outer author.
# Stale files from a renamed or dropped identity are deleted rather than left
# for GIT_CONFIG_GLOBAL to keep including.
install -d -m 700 "${git_config_dir}"
chmod 700 "${git_config_dir}"
if ${identities_ok}; then
  # Render first, replace second. A failed render must not be able to leave an
  # agent session with no HTTPS rewrite and no credential helper, which is a
  # session that would try SSH with keys it does not have.
  rendered="$(mktemp)"
  if DEVBOX_IDENTITIES_TEMPLATE_DIR="${TEMPLATE_DIR}/.config/devbox/git" di_render_agent_gitconfig >"${rendered}" &&
    [[ -s ${rendered} ]]; then
    rm -f "${git_config_dir}"/agent.gitconfig "${git_config_dir}"/agent-*.gitconfig
    install -m 444 "${rendered}" "${git_config_dir}/agent.gitconfig"
    for slug in $(di_dir_slugs); do
      di_render_agent_author "${slug}" >"${rendered}"
      install -m 444 "${rendered}" "${git_config_dir}/agent-${slug}.gitconfig"
    done
  else
    log_warn 'Rendering agent.gitconfig failed; the previous one is left in place.'
    register_action "Rendering ${git_config_dir}/agent.gitconfig failed - run './bin/devbox bootstrap' and read the error; agent sessions keep the previous configuration until it succeeds"
  fi
  rm -f "${rendered}"
fi
# Copies from before the directory existed: nothing reads them now. Globbed, so
# a dropped identity's file goes too.
rm -f "${secrets_dir}"/agent.gitconfig "${secrets_dir}"/agent-*.gitconfig
chmod 500 "${git_config_dir}"

# -- 14. OMP config -----------------------------------------------------------
omp_config_dir="${HOME_DIR}/.omp/agent"
mkdir -p "${omp_config_dir}"
if [[ ! -f "${omp_config_dir}/config.yml" ]]; then
  log_info 'Seeding ~/.omp/agent/config.yml...'
  install -m 644 "${TEMPLATE_DIR}/.omp/agent/config.yml" "${omp_config_dir}/config.yml"
fi

# -- 15. moshi-hook -----------------------------------------------------------
# Companion daemon for the Moshi phone client: it owns the Unix socket the OMP
# extension posts lifecycle events to, serves the local gateway on
# 127.0.0.1:24543 that the app reaches over its own SSH forward, and holds the
# WebSocket that turns those events into push notifications and approvals.
# Installed here rather than in the image for the same reason as OMP (§1): it
# lands in ~/.local/bin on the bind mount, so `moshi-hook update` works without
# a rebuild. That is also why there is no ARG pin - a pin on a self-updating
# bind-mount tool only records the version of the first install. The daemon is
# started by the entrypoint: there is no systemd in this container, so
# `moshi-hook service install` cannot be used.
#
# Fetched directly instead of `curl … install.sh | sh`: upstream's installer
# *skips* verification when checksums.txt or sha256sum is unavailable and
# installs the download anyway, while this repo verifies wherever upstream
# publishes a checksum. The version comes from upstream's own "latest" pointer
# and is then held fixed for both fetches, so the tarball and the checksum can
# never describe two different releases.
if command -v moshi-hook >/dev/null 2>&1; then
  log_info "moshi-hook already installed: $(command -v moshi-hook)"
else
  log_info 'Installing moshi-hook...'
  case "$(uname -m)" in
  x86_64 | amd64) moshi_arch='x86_64' ;;
  aarch64 | arm64) moshi_arch='arm64' ;;
  *) moshi_arch='' ;;
  esac
  moshi_cdn='https://cdn.getmoshi.app/hook'
  moshi_tmp="$(mktemp -d)"
  if [[ -z "${moshi_arch}" ]]; then
    log_warn "Unsupported architecture $(uname -m); skipping moshi-hook."
  elif ! moshi_version="$(curl -fsSL --max-time 15 "${moshi_cdn}/latest/version.txt" | tr -d '[:space:]')" ||
    [[ -z "${moshi_version}" ]]; then
    log_warn 'Could not resolve the latest moshi-hook version; skipping.'
  else
    moshi_asset="moshi-hook_Linux_${moshi_arch}.tar.gz"
    if curl -fsSL --max-time 180 "${moshi_cdn}/${moshi_version}/${moshi_asset}" -o "${moshi_tmp}/${moshi_asset}" &&
      curl -fsSL --max-time 15 "${moshi_cdn}/${moshi_version}/checksums.txt" -o "${moshi_tmp}/checksums.txt" &&
      (cd "${moshi_tmp}" && grep -F "  ${moshi_asset}" checksums.txt | sha256sum -c -) >/dev/null 2>&1 &&
      tar -xzf "${moshi_tmp}/${moshi_asset}" -C "${moshi_tmp}" moshi-hook; then
      install -m 0755 "${moshi_tmp}/moshi-hook" "${HOME_DIR}/.local/bin/moshi-hook"
      # The installer ships this alias too; `moshi <dir>` and `moshi diff` are
      # documented entry points and neither needs the daemon.
      ln -sf moshi-hook "${HOME_DIR}/.local/bin/moshi"
      log_success "Installed moshi-hook ${moshi_version}."
    else
      log_warn 'moshi-hook download or checksum verification failed; skipping.'
    fi
  fi
  rm -rf "${moshi_tmp}"
fi

if command -v moshi-hook >/dev/null 2>&1; then
  # Idempotent, and the cure for the daemon's "agent hooks missing or stale"
  # warning: the extension is generated by the installer, so it has to be
  # rewritten whenever the binary changes. Scoped to OMP deliberately - it is
  # the agent this box runs, and an unscoped install also writes project-local
  # files for agents that are not installed here.
  moshi-hook install --target omp >/dev/null 2>&1 ||
    log_warn 'moshi-hook install --target omp failed; agent events may be stale.'
  # Captured rather than piped into `grep -q`: status prints ~20 lines, grep
  # exits at the first match, and the resulting SIGPIPE makes the pipeline fail
  # under `set -o pipefail` - so the piped form silently never fires.
  moshi_status="$(moshi-hook status 2>/dev/null || true)"
  if [[ "${moshi_status}" == *unpaired* ]]; then
    register_action "Pair with Moshi: copy the token from Settings -> Hooks in the app, run 'moshi-hook pair --token <token>' in the container, then './bin/devbox hook' on the workstation to restart the daemon (while unpaired it is socket-only: no notifications, no approvals)"
  fi
fi

# -- 16. Summary --------------------------------------------------------------
echo
echo '== devbox identities ========================================================'
if ${identities_ok}; then
  for slug in ${slugs}; do
    dir="$(di_get "${slug}" dir)"
    printf '%-14s %-12s %-22s %s\n' "${slug}" "$(di_get "${slug}" host)" "$(di_get "${slug}" orgs | tr '\n' ' ' | sed 's/ $//')" "${dir:-(default - every other tree)}"
    if [[ -f "${SSH_DIR}/id_${slug}.pub" ]]; then
      printf '%-12s %s\n' '' "$(cat "${SSH_DIR}/id_${slug}.pub")"
    else
      printf '%-12s %s\n' '' '(no authentication public key - see the checklist)'
    fi
  done
else
  echo "none: ${identities_file} is not usable"
fi
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
