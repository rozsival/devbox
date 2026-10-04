local -r AGENTS=(omp claude)

# -- Launchers, credential helper, fence, gh shim ------------------------------
# Kept out of ~/.local/bin on purpose: only a launcher adds this directory to
# the PATH, so the `gh` shim (tokens per directory) never intercepts your own
# gh, which keeps its OAuth login.
install -d -m 755 "${AGENT_DIR}"
for tool in omp-launcher claude-launcher gh devbox-git-credential devbox-git-no-ssh; do
  install -m 755 "${TEMPLATE_DIR}/.local/libexec/devbox-agent/${tool}" "${AGENT_DIR}/${tool}"
done
# Sourced by both launchers, never run.
install -m 644 "${TEMPLATE_DIR}/.local/libexec/devbox-agent/agent-launch" "${AGENT_DIR}/agent-launch"

# The resolver is a user-facing command (`devbox-gh-token --account`), same
# place as on the devbox.
install -d -m 755 "${BIN_DIR}"
install -m 755 "${TEMPLATE_DIR}/.local/bin/devbox-gh-token" "${BIN_DIR}/devbox-gh-token"

# `omp` and `claude` must shadow the real binaries, from a directory holding
# nothing else: it goes on your PATH ahead of ~/.local/bin, and anything more in
# it - the gh shim above all - would shadow your own tools too. Not
# ~/.local/bin itself: Claude's native install keeps its own `claude` symlink
# there and re-points it on every update, which would silently drop the
# launcher. Symlinks rather than copies, and no launcher script is itself named
# after its tool: `omp update` resolves its install target by looking `omp` up
# on the PATH and takes over a plain file it finds there in place - which used
# to be the launcher. The launchers drop their own PATH entries for `update`;
# reaching them only through a symlink is the backstop.
install -d -m 755 "${LAUNCHER_DIR}"
for agent in "${AGENTS[@]}"; do
  ln -sfn "${AGENT_DIR}/${agent}-launcher" "${LAUNCHER_DIR}/${agent}"
done
# The layout before Claude: an `omp` symlink in ~/.local/bin and in the agent
# directory. Removed so ~/.local/bin holds no launcher - but only once `omp`
# already resolves through ${LAUNCHER_DIR}, i.e. the PATH line below is in
# place. Before that, the old link is the only thing keeping `omp` fenced;
# removing it would hand the next session the real binary, your gitconfig and
# your SSH keys. The next run after the PATH line cleans it up. Only ever a
# link that still leads to the launcher, never a real install.
legacy_kept=0
if resolved="$(command -v omp 2>/dev/null)" && [[ ${resolved%/*} -ef ${LAUNCHER_DIR} ]]; then
  for link in "${BIN_DIR}/omp" "${AGENT_DIR}/omp"; do
    if [[ -L ${link} && ${link} -ef "${AGENT_DIR}/omp-launcher" ]]; then
      rm -f "${link}"
    fi
  done
elif [[ -L ${BIN_DIR}/omp && ${BIN_DIR}/omp -ef "${AGENT_DIR}/omp-launcher" ]]; then
  legacy_kept=1
fi

# -- Identity registry -----------------------------------------------------------
# One file decides who this laptop is per directory tree: ~/.config/devbox/
# identities.conf, read through devbox-identities and by nothing else. The
# devbox holds the same file (./bin/devbox sync identities copies it over), so SSH
# aliases, the agent gitconfigs and the per-account tokens on both machines come
# from one source - no identity is named anywhere else in this script. Not
# agent-only, so it is installed in libexec directly rather than under
# devbox-agent.
install -d -m 755 "${LIBEXEC_DIR}"
install -m 755 "${TEMPLATE_DIR}/.local/libexec/devbox-identities" "${LIBEXEC_DIR}/devbox-identities"
# Reachable by name from your own shell: unlike the launcher and the gh shim it
# is a read-only inspector, and the docs tell people to run `devbox-identities
# check`. ~/.local/bin is where a PATH usually already starts.
install -d -m 755 "${BIN_DIR}"
ln -sfn "${LIBEXEC_DIR}/devbox-identities" "${BIN_DIR}/devbox-identities"
install -d -m 700 "${CONFIG_DIR}"

identities_file="${CONFIG_DIR}/identities.conf"
identities_seeded=0
# Deliberately not seeded from the example. The example is a valid file - it has
# to be, to be worth copying - so installing it would render agent gitconfigs
# authoring as `your-agent <your-agent@users.noreply.github.com>` instead of
# failing the check and leaving the existing ones alone.
if [[ ! -f ${identities_file} ]]; then
  identities_seeded=1
fi

# Sourced rather than shelled out to, so the rendering below can call di_*
# directly. A broken registry must not cost the launcher, the shim or the
# credential helper installed above - only the identity-derived git
# configuration is skipped when it fails.
# shellcheck source=../home/.local/libexec/devbox-identities
. "${LIBEXEC_DIR}/devbox-identities"
identities_ok=0
slugs=''
if di_check; then
  identities_ok=1
  slugs="$(di_slugs)"
else
  log_warn "${identities_file} is not usable (devbox-identities check) - agent git configuration left untouched this run."
fi

# -- Agent git configuration ---------------------------------------------------
# Read-only, directory included: GIT_CONFIG_GLOBAL points here, so a stray
# `git config --global` in a session rewrites *these* files - that is how the
# author once became your own name and email for five commits. git writes a
# lock file beside the config it rewrites, so only a directory without write
# permission stops it; the files are reinstalled from the templates here, which
# is why they must be chmod'ed back first.
#
# Rendered, not copied: the root file comes from agent.gitconfig.tpl with the
# registry's hosts and trees substituted in, and one
# agent-<slug>.gitconfig per identity that has its own bot author. Stale files
# from a renamed or dropped identity are deleted rather than left for
# GIT_CONFIG_GLOBAL to keep including.
GIT_CONFIG_DIR="${CONFIG_DIR}/git"
install -d -m 700 "${GIT_CONFIG_DIR}"
chmod 700 "${GIT_CONFIG_DIR}"
if ((identities_ok)); then
  rm -f "${GIT_CONFIG_DIR}"/agent.gitconfig "${GIT_CONFIG_DIR}"/agent-*.gitconfig
  rendered="$(mktemp)"
  DEVBOX_IDENTITIES_TEMPLATE_DIR="${TEMPLATE_DIR}/.config/devbox/git" di_render_agent_gitconfig >"${rendered}"
  install -m 444 "${rendered}" "${GIT_CONFIG_DIR}/agent.gitconfig"
  # Every identity that claims a tree, not only those with their own bot
  # author: git applies every matching `includeIf`, so a tree nested inside
  # another would otherwise keep the outer identity's author.
  for slug in $(di_dir_slugs); do
    di_render_agent_author "${slug}" >"${rendered}"
    install -m 444 "${rendered}" "${GIT_CONFIG_DIR}/agent-${slug}.gitconfig"
  done
  rm -f "${rendered}"
fi
# Any copy from before the directory existed, or left by a since-renamed or
# dropped identity, is dead weight an agent could still be pointed at by a
# stale launcher.
rm -f "${CONFIG_DIR}/agent.gitconfig" "${CONFIG_DIR}"/agent-*.gitconfig
chmod 500 "${GIT_CONFIG_DIR}"

# The fine-grained PATs the helper falls back to where the App is not
# installed, and what the gh shim uses. Same file as on the devbox; created
# from the template once, never overwritten.
secrets_file="${CONFIG_DIR}/secrets.env"
if [[ ! -f "${secrets_file}" ]]; then
  install -m 600 "${TEMPLATE_DIR}/.config/devbox/secrets.env.example" "${secrets_file}"
fi
chmod 600 "${secrets_file}"

# The OMP guardrail: bash approval patterns that deny the obvious reach past
# the agent's scoped tokens (the human gh login, the keychain, history
# rewrites). Same template bootstrap seeds on the devbox. Create-if-absent
# only: OMP and you own the file afterwards, so an existing one is reported,
# never merged into.
omp_config="${HOME}/.omp/agent/config.yml"
omp_guard_missing=0
if [[ ! -e ${omp_config} ]]; then
  install -d -m 755 "${omp_config%/*}"
  install -m 644 "${TEMPLATE_DIR}/.omp/agent/config.yml" "${omp_config}"
elif ! grep -qE '^bash:' "${omp_config}"; then
  omp_guard_missing=1
fi

# -- Report ---------------------------------------------------------------------
log_success "Installed ${AGENT_DIR}/{agent-launch,omp-launcher,claude-launcher,gh,devbox-git-credential,devbox-git-no-ssh}, ${LAUNCHER_DIR}/{omp,claude}→launchers, ${BIN_DIR}/{devbox-gh-token,devbox-identities→libexec}, ${LIBEXEC_DIR}/devbox-identities, ${GIT_CONFIG_DIR}/agent*.gitconfig (read-only)"
path_fix=${legacy_kept}
for agent in "${AGENTS[@]}"; do
  # Same rule as the launcher: the real binary is the first PATH entry that does
  # not resolve to the launcher script, so this also holds when run from inside
  # an agent session.
  real=''
  IFS=: read -ra path_dirs <<<"${PATH}"
  for dir in "${path_dirs[@]}"; do
    [[ -f ${dir}/${agent} && -x ${dir}/${agent} && ! ${dir}/${agent} -ef "${AGENT_DIR}/${agent}-launcher" ]] || continue
    real="${dir}/${agent}"
    break
  done
  if [[ -z ${real} ]]; then
    log_info "${agent} is not installed - its launcher is ready and takes over once it is."
  elif resolved="$(command -v "${agent}" 2>/dev/null)" && [[ ${resolved} -ef "${AGENT_DIR}/${agent}-launcher" ]]; then
    log_success "'${agent}' resolves to the launcher (real binary: ${real})."
  else
    log_warn "'${agent}' resolves to ${resolved:-nothing}, not the launcher - agent sessions started now run as you."
    path_fix=1
  fi
done

echo
echo 'Remaining manual steps:'
if ((path_fix)); then
  # shellcheck disable=SC2016 # printed for the user's dotfile, expands there
  echo '  - Put the launchers first on your PATH - last line of ~/.zshrc / ~/.bashrc, after anything that prepends ~/.local/bin: export PATH="$HOME/.local/libexec/devbox-agent/launchers:$PATH" - then open a new shell and re-run ./bin/devbox agent install (it removes the old ~/.local/bin/omp link only once the new directory wins)'
fi
if ((omp_guard_missing)); then
  echo "  - ${omp_config} has no bash: block - copy the guardrail patterns from ${TEMPLATE_DIR}/.omp/agent/config.yml into it (an existing OMP config is never overwritten)"
fi
if ((identities_seeded)); then
  echo "  - Create ${identities_file}: cp ${TEMPLATE_DIR}/.config/devbox/identities.conf.example ${identities_file} and fill in one [slug] block per account (name, email, the laptop's public keys, optionally a GitHub App directory), then re-run ./bin/devbox agent install"
fi
if ((identities_ok)); then
  for slug in ${slugs}; do
    echo "  - $(di_get "${slug}" token_var) in ${secrets_file} (fine-grained; contents write on the repositories agents push without the App)"
  done
  for slug in ${slugs}; do
    app_dir="$(di_get "${slug}" app)"
    [[ -n ${app_dir} ]] || continue
    echo "  - ${app_dir}/{app-id,app.pem} (mode 600) so [${slug}] repositories get App tokens; without them the PAT is used"
  done
else
  echo "  - Fix ${identities_file} (devbox-identities check reports every problem) - the GH_TOKEN_<SLUG> and App-directory steps follow once it is usable"
fi
echo "  - check with: ./bin/devbox doctor laptop, or cd <repo> && devbox-git-credential explain <owner>/<repo>"
