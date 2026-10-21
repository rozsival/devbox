#!/usr/bin/env bash
# Optional, recommended agent tooling for the devbox: two global agent skills.
# Not part of bootstrap, so it is invoked explicitly with `./bin/devbox skills`
# (or directly, from a pane). Re-running is safe: `npx skills add` overwrites in
# place.
set -euo pipefail

log_info() { echo -e "\033[0;34m[INFO]\033[0m  $*"; }
log_success() { echo -e "\033[0;32m[OK]\033[0m    $*"; }

# Pinned like every other tool in this repo; override to move a single one.
SKILLS_CLI_VERSION="${SKILLS_CLI_VERSION:-1.5.26}"
# The skills too: a bare `owner/repo` installs whatever the default branch holds
# at that moment, and a skill is instructions an agent follows. A GitHub tree
# URL pins the ref (the CLI fails on one that does not exist). Where the
# repository tags its releases, the tag of the tool already pinned above is
# used, so a skill and the CLI it drives move together; anthropics/skills has
# no tags, hence a commit.
SKILL_CREATOR_REF="${SKILL_CREATOR_REF:-683bc88e56f3e09ba94f7055977f3d3aa499f202}"

# `--global --agent universal claude-code` installs to ~/.agents/skills - the
# directory OMP reads - and symlinks each skill into ~/.claude/skills, the only
# one Claude Code reads. `--agent '*'` would also symlink the set into ~45
# per-agent dotdirs for tools that are not installed. `--yes` plus an explicit
# `--skill` keeps it non-interactive: without both, the CLI prompts for scope
# and skill selection.
skills_add() {
  local repo="$1" skill="$2"
  log_info "Installing skill ${skill} from ${repo}..."
  npx --yes "skills@${SKILLS_CLI_VERSION}" add "${repo}" \
    --skill "${skill}" \
    --global \
    --agent universal claude-code \
    --yes
}

skills_add "https://github.com/anthropics/skills/tree/${SKILL_CREATOR_REF}" skill-creator
skills_add "https://github.com/vercel-labs/skills/tree/v${SKILLS_CLI_VERSION}" find-skills

log_success 'Agent skills ready.'
npx --yes "skills@${SKILLS_CLI_VERSION}" list --global 2>/dev/null || true
