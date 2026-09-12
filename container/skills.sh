#!/usr/bin/env bash
# Optional, recommended agent tooling for the devbox: three global agent skills
# and the agent-browser CLI with its Chrome build. Not part of bootstrap - it
# downloads ~180 MB of browser on first run - so it is invoked explicitly with
# `./bin/devbox skills` (or directly, from a pane). Re-running is safe: npm and
# `npx skills add` both overwrite in place, and Chrome is skipped when present.
set -euo pipefail

log_info() { echo -e "\033[0;34m[INFO]\033[0m  $*"; }
log_success() { echo -e "\033[0;32m[OK]\033[0m    $*"; }

# Pinned like every other tool in this repo; override to move a single one.
SKILLS_CLI_VERSION="${SKILLS_CLI_VERSION:-1.5.26}"
AGENT_BROWSER_VERSION="${AGENT_BROWSER_VERSION:-0.37.1}"

readonly HOME_DIR="${HOME:-/home/dev}"
export PATH="${HOME_DIR}/.local/bin:${PATH}"

# -- 1. agent-browser ---------------------------------------------------------
# `--prefix` (not NPM_CONFIG_PREFIX, which makes nvm refuse to activate its
# default Node) puts the binary in ~/.local/bin: on the non-interactive PATH and
# on the bind mount, so an image rebuild does not lose it. npm 11 blocks
# lifecycle scripts by default; the allow-list opts this one package in, which is
# what fetches the platform binary. `agent-browser install` then downloads Chrome
# into ~/.agent-browser/browsers - also the bind mount. Its `--with-deps` flag is
# unusable here (it shells out to `apt-get` as root), so the shared libraries
# Chrome links against are baked into the image instead.
log_info "Installing agent-browser ${AGENT_BROWSER_VERSION}..."
npm install -g --prefix "${HOME_DIR}/.local" \
  --allow-scripts=agent-browser "agent-browser@${AGENT_BROWSER_VERSION}"

log_info 'Installing the Chrome build for agent-browser...'
agent-browser install

# -- 2. global agent skills ---------------------------------------------------
# `--global --agent universal` installs to ~/.agents/skills and nothing else -
# the directory every agent here reads, including OMP. `--agent '*'` would also
# symlink the set into ~45 per-agent dotdirs for tools that are not installed.
# `--yes` plus an explicit `--skill` keeps it non-interactive: without both, the
# CLI prompts for scope and skill selection.
skills_add() {
  local repo="$1" skill="$2"
  log_info "Installing skill ${skill} from ${repo}..."
  npx --yes "skills@${SKILLS_CLI_VERSION}" add "${repo}" \
    --skill "${skill}" \
    --global \
    --agent universal \
    --yes
}

skills_add vercel-labs/agent-browser agent-browser
skills_add anthropics/skills skill-creator
skills_add vercel-labs/skills find-skills

log_success 'Agent skills and agent-browser ready.'
log_info "Installed: $(agent-browser --version)"
npx --yes "skills@${SKILLS_CLI_VERSION}" list --global 2>/dev/null || true
