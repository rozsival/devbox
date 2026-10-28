#!/usr/bin/env bash
# Tests for home/.local/libexec/devbox-agent/devbox-safe-rm, the Claude Code
# PermissionRequest hook that approves recoverable deletes. Run by `make test`
# (part of `make check`). Each case feeds the hook one permission request and
# expects either the allow decision or silence (the normal prompt).
#
# The hook runs under HOOK_BASH, /bin/bash by default: bash 3.2 on macOS, the
# oldest shell it must work in. Temp fixtures live in /tmp (one of them a git
# checkout, which must still get the git rules) and a claude-* directory; the
# git fixtures in a scratch directory in /tmp too (git rules come first), so
# they never sit inside this checkout - which may be a main checkout with
# linked worktrees, where nothing passes. Only the relative-PATH case needs a
# directory below the checkout.
#
# The commands under test are literal text, `$` and backticks included.
# shellcheck disable=SC2016
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${root}" # a relative PATH entry below is relative to this
hook="${root}/home/.local/libexec/devbox-agent/devbox-safe-rm"
hook_bash="${HOOK_BASH:-/bin/bash}"
allow='{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'

# In /tmp itself, not $TMPDIR: an agent session may point that into its own
# claude-<uid> directory, where only that session's scratchpad passes.
tmp="$(cd -P "$(TMPDIR=/tmp mktemp -d)" && pwd -P)"
claude_tmp="$(cd -P "$(TMPDIR=/tmp mktemp -d -t claude-devbox-test.XXXXXX)" && pwd -P)"
scratch="$(cd -P "$(TMPDIR=/tmp mktemp -d)" && pwd -P)"
relscratch="$(mktemp -d "${root}/.check-tmp.XXXXXX")"
mounted=''
user_tmp_file=''
cleanup() {
  [[ -z ${mounted} ]] || hdiutil detach -quiet -force "${mounted}" >/dev/null 2>&1 || true
  [[ -z ${user_tmp_file} ]] || rm -f "${user_tmp_file}"
  rm -rf "${tmp}" "${claude_tmp}" "${scratch}" "${relscratch}"
}
trap cleanup EXIT

passed=0
failed=0
# Run the hook the way the preset's command does (`bash -p`); a case may set
# hook_env (extra environment) or hook_flags (empty: a plain `bash` run).
hook_env=()
hook_flags='-p'
# $1 expect (allow|silent), $2 name, $3 cwd, $4 command, $5 permission mode, $6 tool
check() {
  local expect="$1" name="$2" cwd="$3" command="$4" mode="${5:-default}" tool="${6:-Bash}" out status
  # shellcheck disable=SC2086 # hook_flags is one flag or none
  out="$(jq -n --arg c "${command}" --arg d "${cwd}" --arg m "${mode}" --arg t "${tool}" \
    '{session_id: "this-session", hook_event_name: "PermissionRequest", tool_name: $t,
      tool_input: {command: $c, description: "test"}, cwd: $d, permission_mode: $m}' |
    env ${hook_env[@]+"${hook_env[@]}"} "${hook_bash}" ${hook_flags} "${hook}" 2>&1)" && status=0 || status=$?
  local want=''
  [[ ${expect} == allow ]] && want="${allow}"
  if ((status == 0)) && [[ ${out} == "${want}" ]]; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    printf 'FAIL %s: expected %s for: %s\n  exit %s, output: %s\n' "${name}" "${expect}" "${command}" "${status}" "${out}" >&2
  fi
}
approves() { check allow "$@"; }
silent() { check silent "$@"; }

# -- Fixtures ------------------------------------------------------------------
env_name='.env' # one variable, so no command line below spells the name out
mkdir -p "${tmp}/dir/sub" "${tmp}/withenv" "${tmp}/withgit/.git" "${tmp}/.claude" "${tmp}/globenv" "${tmp}/caps"
echo a >"${tmp}/a.log"
echo b >"${tmp}/b.log"
echo x >"${tmp}/dir/sub/x"
echo s >"${tmp}/withenv/${env_name}"
echo k >"${tmp}/withenv/keep.txt"
echo h >"${tmp}/withgit/.git/HEAD"
echo l >"${tmp}/globenv/a.log"
echo s >"${tmp}/globenv/${env_name}"
echo s >"${tmp}/caps/.ENV"
echo w >"${tmp}/-weird"
echo e >"${tmp}/$(printf '\360\237\230\200').log" # an emoji name: one character, four bytes
echo q >"${tmp}/[x].log"
mkfifo "${tmp}/fifo"
mkdir -p "${tmp}/withfifo" && mkfifo "${tmp}/withfifo/pipe"
# Claude Code's per-session directories: this session's scratchpad, another's.
mkdir -p "${claude_tmp}/proj/this-session/scratchpad/sub" "${claude_tmp}/proj/other-session/scratchpad"
echo s >"${claude_tmp}/proj/this-session/scratchpad/sub/f"
echo o >"${claude_tmp}/proj/other-session/scratchpad/f"
# A git checkout inside the temp root still gets the git rules.
tmprepo="${tmp}/checkout"
mkdir -p "${tmprepo}"
git -C "${tmprepo}" init -q
git -C "${tmprepo}" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -q --allow-empty -m i
echo c >"${tmprepo}/kept.txt"
git -C "${tmprepo}" add kept.txt
git -C "${tmprepo}" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -qm kept
echo u >"${tmprepo}/work.txt"

repo="${scratch}/repo"
mkdir -p "${repo}"
git -C "${repo}" init -q
git -C "${repo}" config user.name test
git -C "${repo}" config user.email test@example.invalid
git -C "${repo}" config commit.gpgsign false
printf '%s\n' 'node_modules/' 'dist/' '*.log' 'secret.db' '*.sqlite' >"${repo}/.gitignore"
mkdir -p "${repo}/clean/deep" "${repo}/mod" "${repo}/staged" "${repo}/untracked" "${repo}/envdir" "${repo}/envex" \
  "${repo}/pkg" "${repo}/lib/build" "${repo}/app/[locale]" "${repo}/.claude"
echo t >"${repo}/top.txt"
echo x >"${repo}/clean/x.txt"
echo z >"${repo}/clean/deep/z.txt"
echo m >"${repo}/mod/m.txt"
echo s >"${repo}/staged/s.txt"
echo e >"${repo}/envdir/${env_name}"
echo k >"${repo}/envdir/keep.txt"
echo e >"${repo}/envex/${env_name}.example"
echo p >"${repo}/pkg/package.json"
echo b >"${repo}/lib/build/keep.txt"
echo p >"${repo}/app/[locale]/page.tsx"
echo a >"${repo}/au.txt"
echo c >"${repo}/.claude/settings.json"
mkdir -p "${repo}/x/dist"
echo k >"${repo}/x/dist/keep.js"
git -C "${repo}" add -A
git -C "${repo}" add -f x/dist/keep.js
# An uninitialised submodule: a gitlink entry over an empty directory.
mkdir -p "${repo}/sub"
git -C "${repo}" update-index --add --cacheinfo "160000,$(printf '%040d' 1),sub"
git -C "${repo}" commit -qm fixtures
# Changes after the commit, one kind per directory.
echo changed >>"${repo}/mod/m.txt"
echo changed >>"${repo}/staged/s.txt"
git -C "${repo}" add staged/s.txt
echo u >"${repo}/untracked/u.txt"
echo u >"${repo}/clean-untracked.txt"
git -C "${repo}" update-index --assume-unchanged au.txt
echo changed >>"${repo}/au.txt"
mkdir -p "${repo}/pkg/node_modules/dep" "${repo}/dist"
echo i >"${repo}/pkg/node_modules/dep/index.js"
echo o >"${repo}/dist/out.js"
echo db >"${repo}/secret.db"
echo n >"${repo}/lib/build/notes.log"  # ignored, but lib/build itself is not
echo db >"${repo}/x/dist/local.sqlite" # ignored, but x/dist holds a tracked file
mkdir -p "${repo}/pkg2/node_modules/gitdep/.git"
echo p >"${repo}/pkg2/package.json"
git -C "${repo}" add pkg2/package.json
git -C "${repo}" commit -qm pkg2 -- pkg2/package.json # only it: staged/s.txt stays staged
echo h >"${repo}/pkg2/node_modules/gitdep/.git/HEAD"
# Changes git diff does not see: ident and end-of-line conversion turn the
# work tree back into the blob, and core.fileMode off hides a chmod.
printf '%s\n' 'ident.txt ident' 'eol.txt text' >"${repo}/.gitattributes"
printf '%s\n' '$Id$' >"${repo}/ident.txt"
printf 'a\nb\n' >"${repo}/eol.txt"
echo m >"${repo}/mode.txt"
# Ignored directories that are not regenerable, holding ones that look it.
printf '%s\n' 'private/' '.vscode/' >>"${repo}/.gitignore"
mkdir -p "${repo}/lib2/build"
echo k >"${repo}/lib2/build/keep.txt"
git -C "${repo}" add .gitattributes .gitignore ident.txt eol.txt mode.txt lib2/build/keep.txt
git -C "${repo}" commit -qm attributes -- .gitattributes .gitignore ident.txt eol.txt mode.txt lib2/build/keep.txt
printf '%s\n' '$Id: not-the-blob $' >"${repo}/ident.txt"
printf 'a\r\nb\r\n' >"${repo}/eol.txt"
git -C "${repo}" config core.fileMode false
chmod +x "${repo}/mode.txt"
mkdir -p "${repo}/private/tmp" "${repo}/private/build" "${repo}/.vscode/build" "${repo}/lib2/build/private"
echo k >"${repo}/private/tmp/id_ed25519"
echo k >"${repo}/private/build/x"
echo k >"${repo}/.vscode/build/x"
echo k >"${repo}/lib2/build/private/key"
# Untracked notes several levels down, which a recursive ** reaches.
mkdir -p "${repo}/deep/a/b"
echo n >"${repo}/deep/a/b/notes.md"
# A repository whose own config defines a filter driver.
frepo="${scratch}/filtered"
mkdir -p "${frepo}"
git -C "${frepo}" init -q
echo f >"${frepo}/f.txt"
git -C "${frepo}" add f.txt
git -C "${frepo}" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -qm f
git -C "${frepo}" config filter.upper.clean 'tr a-z A-Z'
# Git directories under other names, in temp.
git init -q --separate-git-dir "${tmp}/sep.git" "${tmp}/sepwt"
git init -q --bare "${tmp}/bare.git"
# A name with a newline; Claude's directory spelled in other cases.
mkdir -p "${tmp}/nl" "${claude_tmp}/bash-edit-diff"
echo n >"${tmp}/nl/a"$'\n'"b"
claude_base="${claude_tmp##*/}"
claude_upper="${claude_tmp%/*}/CLAUDE-${claude_base#claude-}"
claude_mixed="Claude-${claude_base#claude-}"
# Round 3: the glob form, case siblings, CR and quote names, a space in an
# ignored name, ignore rules from outside the repository, a case-folded index,
# a symlink target ending in a newline.
mkdir -p "${tmp}/globdir/sub" "${tmp}/emptydir" "${tmp}/dotdot/a" "${tmp}/dotdot/b" "${tmp}/uni"
echo g >"${tmp}/globdir/a"
echo g >"${tmp}/globdir/.hidden"
echo g >"${tmp}/globdir/sub/x"
echo b >"${tmp}/dotdot/b/keep"
echo u >"${tmp}/uni/$(printf 'e\303\251').txt"
mkdir -p "${repo}/cdir" "${repo}/b" "${repo}/crdir" "${repo}/qdir" "${repo}/qok" "${repo}/dist build" \
  "${repo}/tmp" "${repo}/coverage" "${repo}/nllink"
echo p >"${repo}/cdir/precious"
echo x >"${repo}/b/x"
cr=$'\r'
echo same >"${repo}/crdir/out.txt"
echo same >"${repo}/crdir/out.txt${cr}"
echo same >"${repo}/qdir/x"
echo same >"${repo}/qdir/\"x\""
echo q >"${repo}/qok/\"q\""
# At the top level, so the path git hash-object sees starts with the quote.
echo same >"${repo}/qt"
echo same >"${repo}/\"qt\""
ln -s "target"$'\n' "${repo}/nllink/l"
git -C "${repo}" add crdir qdir qok nllink qt '"qt"'
git -C "${repo}" commit -qm names -- crdir qdir qok nllink qt '"qt"'
echo modified >"${repo}/crdir/out.txt${cr}"
echo modified >"${repo}/qdir/\"x\""
echo modified >"${repo}/\"qt\""
printf '%s\n' 'dist build/' >>"${repo}/.gitignore"
git -C "${repo}" commit -qm "dist build" -- .gitignore # committed: an uncommitted .gitignore change counts for nothing
echo s >"${repo}/dist build/secret"
echo 'coverage/' >>"${repo}/.git/info/exclude"
echo 'tmp/' >"${scratch}/global-ignore"
git -C "${repo}" config core.excludesFile "${scratch}/global-ignore"
echo p >"${repo}/tmp/precious"
echo r >"${repo}/coverage/report"
# A case-folded index: core.ignorecase off, Dist/ tracked and modified, dist/ ignored.
cirepo="${scratch}/ci"
mkdir -p "${cirepo}/Dist"
git -C "${cirepo}" init -q
git -C "${cirepo}" config core.ignorecase false
echo k >"${cirepo}/Dist/keep.txt"
printf '%s\n' 'dist/' >"${cirepo}/.gitignore"
git -C "${cirepo}" add -A
git -C "${cirepo}" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -qm ci
echo modified >"${cirepo}/Dist/keep.txt"
# A partial clone: a tracked file whose blob the object store does not hold.
git -C "${frepo}" config uploadpack.allowFilter true
pclone="${scratch}/partial"
git clone -q --no-checkout --filter=blob:none "file://${frepo}" "${pclone}" 2>/dev/null
git -C "${pclone}" read-tree HEAD
echo f >"${pclone}/f.txt"
# Git directories: bare with a linked worktree, ancestors of every target.
git clone -q --bare "${tmprepo}" "${tmp}/bare2.git"
git -C "${tmp}/bare2.git" worktree add -q "${tmp}/bwt" 2>/dev/null
# Case siblings on a case-sensitive file system (skipped where they fold).
mkdir -p "${tmp}/cs/dir"
echo d >"${tmp}/cs/dir/f"
if mkdir "${tmp}/cs/DIR" 2>/dev/null; then cs_fs=1; else cs_fs=0; fi
# A name that is not valid UTF-8 (a Linux file system takes it; APFS refuses).
mkdir -p "${tmp}/bad"
if { : >"${tmp}/bad/$(printf '\377')"; } 2>/dev/null; then bad_name=1; else bad_name=0; fi
# Round 4: .gitignore edits not committed (and one that is), an untracked
# nested .gitignore, a leading `:` read as pathspec magic, alternates in temp,
# git object stores under other names, a clone below ~/.claude, other VCS
# metadata, a relative PATH entry.
gi_commit() { git -C "$1" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -qm "$2"; }
for v in unstaged staged committed; do
  r="${scratch}/gi-${v}"
  mkdir -p "${r}/build"
  git -C "${r}" init -q
  printf '%s\n' 'node_modules/' >"${r}/.gitignore"
  git -C "${r}" add .gitignore
  gi_commit "${r}" ignore
  echo d >"${r}/build/design.md"
  echo 'build/' >>"${r}/.gitignore"
  case "${v}" in
  staged) git -C "${r}" add .gitignore ;;
  committed) git -C "${r}" add .gitignore && gi_commit "${r}" build ;;
  esac
done
mkdir -p "${repo}/notes/tmp"
printf '%s\n' 'tmp' >"${repo}/notes/.gitignore"
echo n >"${repo}/notes/tmp/x"
crepo="${scratch}/colon"
mkdir -p "${crepo}/a/build" "${crepo}/:a/build"
git -C "${crepo}" init -q
printf '%s\n' 'build/' >"${crepo}/a/.gitignore"
git -C "${crepo}" add a/.gitignore
gi_commit "${crepo}" colon
printf '%s\n' 'build/' >"${crepo}/:a/.gitignore"
echo p >"${crepo}/:a/build/precious"
git clone -q --bare "${tmprepo}" "${tmp}/cache.git"
mkdir -p "${tmp}/cache" "${tmp}/loose"
cp -R "${tmp}/cache.git/objects" "${tmp}/cache/objects"
fanout="$(cd "${tmp}/cache/objects" && for d in [0-9a-f][0-9a-f]; do
  echo "${d}"
  break
done)"
cp -R "${tmp}/cache/objects/${fanout}" "${tmp}/loose/${fanout}"
altrepo="${scratch}/alt"
git clone -q --shared "${tmp}/cache.git" "${altrepo}"
echo "${tmp}/cache/objects" >"${altrepo}/.git/objects/info/alternates"
drepo="${scratch}/dot/.claude/plugins/m"
mkdir -p "${drepo}/hooks"
git -C "${drepo}" init -q
echo h >"${drepo}/hooks/x"
git -C "${drepo}" add hooks
gi_commit "${drepo}" hooks
mkdir -p "${tmp}/hgrepo/.hg" "${tmp}/cvsdir/CVS" "${tmp}/jjrepo/.jj"
echo r >"${tmp}/hgrepo/.hg/requires"
echo r >"${tmp}/cvsdir/CVS/Root"
echo r >"${tmp}/jjrepo/.jj/x"
mkdir -p "${relscratch}/relbin"
printf '%s\n' '#!/bin/sh' 'exit 1' >"${relscratch}/relbin/git"
chmod +x "${relscratch}/relbin/git"
# Round 4b: an ignored ancestor git descends into for a force-added file, a
# `:` component, exact symlink targets, a per-user temp directory.
mkdir -p "${repo}/private/tmp"
echo t >"${repo}/private/tracked.txt"
echo k >"${repo}/private/tmp/keys.db"
git -C "${repo}" add -f private/tracked.txt
git -C "${repo}" commit -qm forced -- private/tracked.txt
printf '%s\n' 'tmp/' >"${crepo}/.gitignore"
git -C "${crepo}" add .gitignore
gi_commit "${crepo}" tmp
mkdir -p "${crepo}/:/tmp" "${crepo}/tmp"
echo p >"${crepo}/:/tmp/precious"
mkdir -p "${repo}/slink" "${repo}/slink2"
ln -s 'a ' "${repo}/slink/l"
ln -s a "${repo}/slink2/l"
git -C "${repo}" add slink slink2
git -C "${repo}" commit -qm links -- slink slink2
ln -sfn 'a ' "${repo}/slink2/l"
if [[ "$(uname -s)" == Darwin ]]; then
  user_tmp_file="$(mktemp "$(getconf DARWIN_USER_TEMP_DIR)devbox-safe-rm.XXXXXX")"
fi
# Round 5: a non-ASCII spelling APFS folds onto a protected name, replace
# refs, an object store of packs only, core.excludesFile naming a nested
# .gitignore, a repository below a node_modules, more VCS metadata.
long_s="$(printf '\305\277')" # U+017F, which APFS folds to s
mkdir -p "${tmp}/svnwc/.svn/pristine" "${repo}/pkg3/node_modules/dep/.svn/pristine"
echo p >"${tmp}/svnwc/.svn/pristine/x"
echo w >"${tmp}/svnwc/.svn/wc.db"
echo p >"${repo}/pkg3/node_modules/dep/.svn/pristine/x"
rrepo="${scratch}/replace"
mkdir -p "${rrepo}"
git -C "${rrepo}" init -q
echo one >"${rrepo}/f.txt"
git -C "${rrepo}" add f.txt
gi_commit "${rrepo}" one
blob_one="$(git -C "${rrepo}" rev-parse HEAD:f.txt)"
blob_two="$(echo two | git -C "${rrepo}" hash-object -w --stdin)"
git -C "${rrepo}" replace "${blob_one}" "${blob_two}"
rm -f "${rrepo}/.git/objects/${blob_one:0:2}/${blob_one:2}"
mkdir -p "${tmp}/store/pack"
git -C "${tmprepo}" rev-list --objects --all | git -C "${tmprepo}" pack-objects -q "${tmp}/store/pack/pack" >/dev/null
pack_idx="$(cd "${tmp}/store/pack" && for f in pack-*.idx; do echo "${f}"; done)"
xrepo="${scratch}/excludes"
mkdir -p "${xrepo}/apps/web" "${xrepo}/src/dist"
git -C "${xrepo}" init -q
printf '%s\n' 'dist' >"${xrepo}/apps/web/.gitignore"
echo s >"${xrepo}/src/main.txt"
git -C "${xrepo}" add apps src
gi_commit "${xrepo}" excludes
git -C "${xrepo}" config core.excludesFile apps/web/.gitignore
echo d >"${xrepo}/src/dist/data"
nmrepo="${scratch}/nm/node_modules/proj"
mkdir -p "${nmrepo}/.claude"
git -C "${nmrepo}" init -q
echo c >"${nmrepo}/.claude/settings.json"
git -C "${nmrepo}" add .claude
gi_commit "${nmrepo}" claude
mkdir -p "${tmp}/vcs"
for v in .sl .pijul _MTN RCS SCCS; do
  mkdir -p "${tmp}/vcs/${v}-holder/${v}"
  echo v >"${tmp}/vcs/${v}-holder/${v}/x"
done
for v in .fslckout _FOSSIL_; do
  mkdir -p "${tmp}/vcs/${v}-holder"
  echo v >"${tmp}/vcs/${v}-holder/${v}"
done
# Round 6: a repository with a linked worktree, a repository nested in its
# main checkout, and a plain clone of it.
wrepo="${scratch}/wt-main"
mkdir -p "${wrepo}"
git -C "${wrepo}" init -q
echo t >"${wrepo}/tracked.txt"
git -C "${wrepo}" add tracked.txt
gi_commit "${wrepo}" tracked
git -C "${wrepo}" worktree add -q "${scratch}/wt-linked" 2>/dev/null
git clone -q "${wrepo}" "${scratch}/wt-clone"
mkdir -p "${wrepo}/m/nested"
git -C "${wrepo}/m/nested" init -q
echo n >"${wrepo}/m/nested/n"
git -C "${wrepo}/m/nested" add n
gi_commit "${wrepo}/m/nested" n
# Final review: renamed packs in a moved object store, a symlink retargeted
# to a name ending in a newline, a nested repository in a main checkout with
# worktrees, .github, a glob through link//, an intent-to-add entry.
for v in a b; do
  r="${scratch}/packs-${v}"
  mkdir -p "${r}"
  git -C "${r}" init -q
  echo a >"${r}/a.txt"
  git -C "${r}" add a.txt
  gi_commit "${r}" a
  git -C "${r}" repack -adq
  git -C "${r}" prune
done
movedstore="${tmp}/movedstore"
mkdir -p "${movedstore}"
mv "${scratch}/packs-a/.git/objects" "${movedstore}/o"
ln -s "${movedstore}/o" "${scratch}/packs-a/.git/objects"
rm -rf "${movedstore}/o/info"
for f in "${movedstore}/o/pack/"pack-*; do mv "${f}" "${movedstore}/o/pack/foo.${f##*.}"; done
rb="${scratch}/packs-b"
printf '%s\n' 'build/' >"${rb}/.gitignore"
git -C "${rb}" add .gitignore
gi_commit "${rb}" ignore
git -C "${rb}" repack -adq
mkdir -p "${rb}/build"
mv "${rb}/.git/objects" "${rb}/build/objs"
ln -s ../build/objs "${rb}/.git/objects"
rm -rf "${rb}/build/objs/info"
for f in "${rb}/build/objs/pack/"pack-*; do mv "${f}" "${rb}/build/objs/pack/foo.${f##*.}"; done
mkdir -p "${repo}/nlink"
ln -s target "${repo}/nlink/l"
git -C "${repo}" add nlink
git -C "${repo}" commit -qm nlink -- nlink
ln -sfn "target"$'\n' "${repo}/nlink/l"
mkdir -p "${repo}/.github"
echo w >"${repo}/.github/x"
git -C "${repo}" add .github
git -C "${repo}" commit -qm github -- .github
mkdir -p "${tmp}/linkglob/real"
echo r >"${tmp}/linkglob/real/f"
ln -s real "${tmp}/linkglob/link"
itarepo="${scratch}/ita"
mkdir -p "${itarepo}"
git -C "${itarepo}" init -q
: >"${itarepo}/e1"
git -C "${itarepo}" add e1
gi_commit "${itarepo}" e1
: >"${itarepo}/empty"
git -C "${itarepo}" add -N empty
ln -s /etc/hosts "${repo}/link"
ln -s "${repo}" "${tmp}/via"
ln -s "${repo}/clean" "${tmp}/dirlink"

# -- Approved ------------------------------------------------------------------
approves 'temp file' "${tmp}" "rm ${tmp}/a.log"
approves 'temp file, relative' "${tmp}" 'rm -f a.log'
approves 'temp dir, every allowed flag' "${tmp}" "rm -rRfvd --recursive --force --verbose --dir -- ${tmp}/dir"
approves 'glob form: every entry of a temp dir' "${tmp}" "rm -rf ${tmp}/globdir/*"
approves 'glob form: * alone' "${tmp}/globdir" 'rm -rf *'
silent 'prefix glob' "${tmp}" "rm -f ${tmp}/*.log"
silent 'prefix glob, relative' "${tmp}" 'rm -f ./*.log'
silent 'glob next to a quoted bracket' "${tmp}" "rm -f ${tmp}/'['*"
approves "this session's scratchpad" "${tmp}" "rm -rf ${claude_tmp}/proj/this-session/scratchpad/sub"
approves 'clean file in a checkout in temp' "${tmp}" "rm ${tmprepo}/kept.txt"
silent 'glob without a match' "${tmp}" "rm -f ${tmp}/nothing-*.tmp"
approves 'temp path that does not exist' "${tmp}" "rm -rf ${tmp}/gone"
approves 'temp symlink itself' "${tmp}" "rm ${tmp}/dirlink"
approves 'file named like an option after --' "${tmp}" "rm -- ${tmp}/-weird"
approves 'tracked clean file' "${repo}" 'rm top.txt'
approves 'tracked clean dir' "${repo}" "rm -rf ${repo}/clean"
approves 'tracked clean dir, quoted' "${repo}" "rm -r '${repo}/clean/deep' \"${repo}/clean/x.txt\""
approves 'tracked clean dir with brackets' "${repo}" "rm -rf '${repo}/app/[locale]'"
approves 'glob form inside a quoted bracket dir' "${repo}" "rm -f '${repo}/app/[locale]/'*"
approves 'glob form, relative, in a bracket cwd' "${repo}" "cd './app/[locale]' && rm -f *"
approves '.env.example is a template' "${repo}" 'rm -rf envex'
approves 'node_modules' "${repo}" 'rm -rf pkg/node_modules'
approves 'dir holding tracked files and node_modules' "${repo}" 'rm -rf pkg'
approves 'dist and node_modules together' "${repo}" 'rm -rf dist pkg/node_modules'
approves 'cd then rm' "${tmp}" "cd ${repo} && rm -rf clean dist"
approves 'cd ./ then rm' "${repo}" 'cd ./clean && rm -f x.txt'
approves 'several rm commands' "${repo}" "rm -f ${tmp}/a.log; rm -rf ${repo}/dist && rm top.txt"
approves 'trailing semicolon' "${repo}" 'rm top.txt;'
approves 'through a symlinked parent into the repo' "${tmp}" "rm ${tmp}/via/top.txt"
# `..` in cd resolves logically or physically depending on shell options.
silent 'cd ..' "${tmp}/via" 'cd .. && rm a.log'
silent 'cd ../x' "${repo}/clean" 'cd ../clean && rm x.txt'
silent 'cd with .. inside' "${repo}" 'cd ./clean/../clean && rm x.txt'
if [[ ${repo} == "${HOME}"/* ]]; then
  approves 'home-relative path into the repo' "${repo}" "rm ~/${repo#"${HOME}"/}/top.txt"
fi

# -- Silent --------------------------------------------------------------------
silent 'untracked file' "${repo}" 'rm clean-untracked.txt'
silent 'dir with an untracked file' "${repo}" 'rm -rf untracked'
silent 'modified file' "${repo}" 'rm mod/m.txt'
silent 'staged file' "${repo}" 'rm -f staged/s.txt'
silent 'assume-unchanged file' "${repo}" 'rm au.txt'
silent 'ignored but not regenerable' "${repo}" 'rm secret.db'
silent 'ignored file in a tracked dir named build' "${repo}" 'rm -rf lib/build'
silent 'env file in a dir, tracked and clean' "${repo}" 'rm -rf envdir'
silent 'env file in a temp dir' "${tmp}" "rm -rf ${tmp}/withenv"
silent 'env file, upper case' "${tmp}" "rm -f ${tmp}/caps/.ENV"
silent 'glob reaching a hidden env file' "${tmp}" "rm -f ${tmp}/globenv/*"
silent '.git dir' "${repo}" 'rm -rf .git'
silent 'inside .git' "${repo}" 'rm -rf .git/hooks'
silent 'temp dir holding a .git' "${tmp}" "rm -rf ${tmp}/withgit"
silent '.claude in the repo' "${repo}" 'rm .claude/settings.json'
silent '.claude in temp' "${tmp}" "rm -rf ${tmp}/.claude"
silent 'repo root' "${tmp}" "rm -rf ${repo}"
silent 'repo root as .' "${repo}" 'rm -rf .'
silent 'parent dir as ..' "${repo}/clean" 'rm -rf ..'
silent 'temp root' "${tmp}" 'rm -rf /tmp'
silent 'temp root, trailing slash' "${tmp}" 'rm -rf /private/tmp/'
silent 'user temp root' "${tmp}" "rm -rf ${tmp%/*}"
silent 'outside temp and git' "${tmp}" 'rm -f /etc/hosts'
silent 'home directory' "${tmp}" 'rm -rf ~'
silent 'untracked symlink in the repo' "${repo}" 'rm link'
silent 'symlink with a trailing slash' "${tmp}" "rm -rf ${tmp}/dirlink/"
silent 'through a symlinked parent to an untracked file' "${tmp}" "rm ${tmp}/via/untracked/u.txt"
silent 'variable' "${tmp}" "rm -rf \$TMPDIR/a.log"
silent 'braced variable' "${tmp}" "rm -rf \"\${HOME}/x\""
silent 'command substitution' "${tmp}" 'rm -rf $(echo a.log)'
silent 'backticks' "${tmp}" 'rm -rf `echo a.log`'
silent 'extra command after' "${tmp}" "rm ${tmp}/a.log && ls"
silent 'extra command before' "${tmp}" "echo hi; rm ${tmp}/a.log"
silent 'pipe' "${tmp}" "rm -v ${tmp}/a.log | cat"
silent 'or-list' "${tmp}" "rm ${tmp}/a.log || true"
silent 'background' "${tmp}" "rm ${tmp}/a.log &"
silent 'redirection' "${tmp}" "rm ${tmp}/a.log >/dev/null"
silent 'stderr redirection' "${tmp}" "rm ${tmp}/a.log 2>&1"
silent 'rm -i' "${tmp}" "rm -i ${tmp}/a.log"
silent 'rm -I' "${tmp}" "rm -I ${tmp}/a.log"
silent 'rm --interactive' "${tmp}" "rm --interactive=never ${tmp}/a.log"
silent 'rm --no-preserve-root' "${tmp}" "rm --no-preserve-root ${tmp}/a.log"
silent 'option after a target' "${tmp}" "rm ${tmp}/a.log -r"
silent 'no target' "${tmp}" 'rm -rf'
silent 'absolute rm path' "${tmp}" "/bin/rm ${tmp}/a.log"
silent 'env prefix' "${tmp}" "FOO=1 rm ${tmp}/a.log"
silent 'sudo' "${tmp}" "sudo rm ${tmp}/a.log"
silent 'cd then ;' "${tmp}" "cd ${repo}; rm top.txt"
silent 'cd to a bare name (CDPATH)' "${repo}" 'cd clean && rm x.txt'
silent 'cd -' "${repo}" 'cd - && rm top.txt'
silent 'recursive ** glob' "${tmp}" "rm -f ${tmp}/**/x"
silent 'brace expansion' "${tmp}" "rm -f ${tmp}/{a,b}.log"
silent 'bracket glob' "${tmp}" "rm -f ${tmp}/[ab].log"
silent 'question-mark glob' "${tmp}" "rm -f ${tmp}/?.log"
silent 'glob with non-ASCII text' "${tmp}" "rm -f ${tmp}/$(printf '\303\251')*"
silent 'backslash' "${tmp}" "rm ${tmp}/a\\.log"
silent 'backslash in double quotes' "${tmp}" "rm \"${tmp}/a\\.log\""
silent 'backslash in single quotes' "${tmp}" "rm '${tmp}/a\\.log'"
silent 'form feed' "${tmp}" "rm ${tmp}/a.log"$'\f'"${HOME}"
silent 'vertical tab' "${tmp}" "rm ${tmp}/a.log"$'\v'"${HOME}"
silent 'no-break space' "${tmp}" "rm ${tmp}/a.log$(printf '\302\240')x"
silent 'line separator' "${tmp}" "rm ${tmp}/a.log$(printf '\342\200\250')x"
silent 'ideographic space' "${tmp}" "rm ${tmp}/a.log$(printf '\343\200\200')x"
silent 'untracked file in a checkout in temp' "${tmp}" "rm ${tmprepo}/work.txt"
silent 'checkout in temp as a whole' "${tmp}" "rm -rf ${tmprepo}"
silent "another session's scratchpad" "${tmp}" "rm -f ${claude_tmp}/proj/other-session/scratchpad/f"
silent 'a scratchpad itself' "${tmp}" "rm -rf ${claude_tmp}/proj/this-session/scratchpad"
silent 'the claude temp dir' "${tmp}" "rm -rf ${claude_tmp}"
silent '/var/tmp is not temp' "${tmp}" 'rm -f /var/tmp/devbox-safe-rm-test-missing'
silent 'fifo' "${tmp}" "rm -f ${tmp}/fifo"
silent 'dir holding a fifo' "${tmp}" "rm -rf ${tmp}/withfifo"
silent 'uninitialised submodule' "${repo}" 'rm -rf sub'
silent 'ignored file under a tracked dist' "${repo}" 'rm -rf x/dist'
silent 'nested .git inside node_modules' "${repo}" 'rm -rf pkg2/node_modules'
silent 'tilde user' "${tmp}" 'rm -f ~root/x'
silent 'comment' "${tmp}" "rm ${tmp}/a.log # done"
silent 'unterminated quote' "${tmp}" "rm '${tmp}/a.log"
silent 'trailing &&' "${tmp}" "rm ${tmp}/a.log &&"
silent 'empty command' "${tmp}" "; rm ${tmp}/a.log"
silent 'empty target' "${tmp}" "rm ''"
silent 'plan mode' "${tmp}" "rm ${tmp}/a.log" plan
silent 'other tool' "${tmp}" "rm ${tmp}/a.log" default Write
silent 'not rm at all' "${tmp}" 'ls -la'
silent 'control character' "${tmp}" "rm ${tmp}/a.log"$'\001'

# -- Review findings ---------------------------------------------------------
silent 'claude dir in upper case, a project in it' "${tmp}" "rm -rf ${claude_upper}/proj"
silent 'claude dir in upper case, its own state' "${tmp}" "rm -rf ${claude_upper}/bash-edit-diff"
silent 'claude dir in mixed case, relative' "${tmp}" "cd ${tmp%/*} && rm -rf ${claude_mixed}"
silent 'another session through an upper-case claude dir' "${tmp}" \
  "rm -f ${claude_upper}/proj/other-session/scratchpad/f"
silent 'scratchpad spelled in upper case' "${tmp}" "rm -rf ${claude_tmp}/proj/this-session/SCRATCHPAD/sub"
silent 'session spelled in upper case' "${tmp}" "rm -rf ${claude_tmp}/proj/THIS-SESSION/scratchpad/sub"
silent 'empty double quotes make a recursive **' "${repo}" 'rm -f *""*/notes.md'
silent 'empty single quotes make a recursive **' "${repo}" "rm -f *''*/notes.md"
silent 'recursive ** into scratchpads' "${tmp}" "rm -rf ${claude_tmp}/*\"\"*/scratchpad"
silent 'rcquotes doubled quote' "${tmp}" "rm '${tmp}/it''s.md'"
silent 'missing file in a work tree' "${repo}" 'rm -f gone.txt'
silent 'ident hides a change' "${repo}" 'rm ident.txt'
silent 'end-of-line conversion hides a change' "${repo}" 'rm eol.txt'
silent 'chmod hidden by core.fileMode false' "${repo}" 'rm mode.txt'
silent 'repository defining a filter driver' "${frepo}" 'rm f.txt'
silent 'tmp below an ignored private/' "${repo}" 'rm -rf private/tmp'
silent 'build below an ignored private/' "${repo}" 'rm -rf private/build'
silent 'build below an ignored .vscode/' "${repo}" 'rm -rf .vscode/build'
silent 'ignored private/ below a tracked build/' "${repo}" 'rm -rf lib2/build'
silent 'separate git dir in temp' "${tmp}" "rm -rf ${tmp}/sep.git"
silent 'inside a separate git dir' "${tmp}" "rm -f ${tmp}/sep.git/HEAD"
silent 'bare repository in temp' "${tmp}" "rm -rf ${tmp}/bare.git"
silent 'name with a newline' "${tmp}" "rm -rf ${tmp}/nl"
silent 'glob reaching a symlink to a directory (zsh mark_dirs)' "${tmp}" "rm -f ${tmp}/dirl*"
silent 'bracket negation' "${repo}" 'rm [!a]'
silent 'bracket holding only !' "${repo}" 'rm [!]'
silent 'bracket with a quoted !' "${repo}" "rm ['!']a]"
silent 'bracket closed by a quoted ]' "${repo}" "rm [x']'"
approves 'still approves a clean file' "${repo}" 'rm top.txt'
hook_env=("GIT_DIR=${tmp}/bare.git" "GIT_WORK_TREE=/")
approves 'GIT_DIR and GIT_WORK_TREE from the session are ignored' "${repo}" 'rm top.txt'
hook_env=("BASH_ENV=${scratch}/bash-env")
printf '%s\n' "echo '${allow}'; exit 0" >"${scratch}/bash-env"
silent 'BASH_ENV is not read' "${repo}" 'rm clean-untracked.txt'
hook_env=("GLOBIGNORE=*/${env_name}")
hook_flags=''
silent 'GLOBIGNORE from the environment hides no match, plain bash' "${tmp}" "rm -f ${tmp}/globenv/*"
hook_env=()
hook_flags='-p'
# -- Round 3 -------------------------------------------------------------------
silent 'k* (Kelvin sign folds to k)' "${tmp}" 'rm -f k*'
silent 'i* (dotted I folds to i)' "${tmp}" 'rm -f i*'
silent 'glob form with the dir typed in another case' "${repo}" 'rm -rf CDIR/*'
silent 'glob in a middle segment' "${repo}" 'rm -f */X'
silent '.*/b (bash <= 5.1 and dash reach ..)' "${tmp}/dotdot/a" 'rm -rf .*/b'
silent 'glob form followed by quotes' "${tmp}" "rm -rf ${tmp}/globdir/*\"\""
silent 'glob form on an empty dir' "${tmp}" "rm -rf ${tmp}/emptydir/*"
silent 'glob form on a symlinked dir' "${tmp}" "rm -rf ${tmp}/dirlink/*"
silent 'glob form reaching a hidden env file' "${tmp}" "rm -f ${tmp}/globenv/*"
silent 'glob form on a non-ASCII dir' "${tmp}" "rm -rf ${tmp}/$(printf 'e\303\251')/*"
if ((cs_fs)); then
  silent 'glob form with a case sibling on a case-sensitive file system' "${tmp}" "rm -rf ${tmp}/cs/dir/*"
fi
silent 'non-ASCII name inside a temp dir' "${tmp}" "rm -rf ${tmp}/uni"
if ((bad_name)); then
  silent 'name that is not valid UTF-8' "${tmp}" "rm -rf ${tmp}/bad"
fi
silent 'modified name ending in CR beside a clean twin' "${repo}" 'rm -rf crdir'
silent 'modified "x" beside a clean x, in a dir' "${repo}" 'rm -rf qdir'
silent 'modified "qt" beside a clean qt, at the top level' "${repo}" "rm '\"qt\"'"
approves 'clean file named with quotes' "${repo}" 'rm -rf qok'
silent 'symlink target ending in a newline' "${repo}" 'rm -rf nllink'
silent 'ignored name with a space holding a regenerable word' "${repo}" "rm -rf 'dist build'"
silent 'tmp ignored only by core.excludesFile' "${repo}" 'rm -rf tmp'
silent 'coverage ignored only by info/exclude' "${repo}" 'rm -rf coverage'
silent 'index entry under an ignored dir, case-folded' "${cirepo}" 'rm -rf dist'
silent 'blob missing from a partial clone' "${pclone}" 'rm f.txt'
silent 'objects of a bare repository' "${tmp}" "rm -rf ${tmp}/bare.git/objects"
silent 'glob form in a bare repository' "${tmp}" "rm -rf ${tmp}/bare.git/*"
silent 'refs and HEAD of a bare repository' "${tmp}" "rm -rf ${tmp}/bare.git/refs ${tmp}/bare.git/HEAD"
silent 'worktrees of a bare repository' "${tmp}" "rm -rf ${tmp}/bare2.git/worktrees"
silent 'objects and refs of a separate git dir' "${tmp}" "rm -rf ${tmp}/sep.git/objects ${tmp}/sep.git/refs"
hook_env=("POSIXLY_CORRECT=1")
approves 'POSIXLY_CORRECT does not break the hook' "${repo}" 'rm top.txt'
hook_env=()

# -- Round 4 -------------------------------------------------------------------
silent '.gitignore line added, not committed' "${scratch}/gi-unstaged" 'rm -rf build'
silent '.gitignore line added and staged' "${scratch}/gi-staged" 'rm -rf build'
approves '.gitignore line committed (intent passes)' "${scratch}/gi-committed" 'rm -rf build'
silent 'rule from an untracked nested .gitignore' "${repo}" 'rm -rf notes/tmp'
silent 'leading : read as pathspec magic' "${crepo}" "rm -rf ':a/build'"
silent 'objects borrowed through alternates' "${altrepo}" 'rm kept.txt'
silent 'an object store under another name' "${tmp}" "rm -rf ${tmp}/cache/objects"
silent 'a dir holding an object store' "${tmp}" "rm -rf ${tmp}/cache"
silent 'a fan-out dir inside an object store' "${tmp}" "rm -rf ${tmp}/cache/objects/${fanout}"
silent 'loose objects on their own' "${tmp}" "rm -rf ${tmp}/loose"
silent 'a clone below .claude' "${drepo}" 'rm -rf hooks'
silent '.hg metadata' "${tmp}" "rm -rf ${tmp}/hgrepo"
silent 'CVS metadata' "${tmp}" "rm -rf ${tmp}/cvsdir"
silent '.jj metadata' "${tmp}" "rm -rf ${tmp}/jjrepo"
hook_env=("PATH=${relscratch#"${root}"/}/relbin:${PATH}")
approves 'a relative PATH entry holding a broken git is dropped' "${repo}" 'rm top.txt'
hook_env=()

# -- Round 4b ------------------------------------------------------------------
silent 'regenerable name below an ignored ancestor git descends into' "${repo}" 'rm -rf private/tmp'
silent 'a component starting with : (:/tmp is the toplevel tmp to git)' "${crepo}" "rm -rf ':/tmp'"
approves 'clean symlink whose target ends in a space' "${repo}" 'rm -rf slink'
silent 'symlink retargeted to the same name plus a space' "${repo}" 'rm -rf slink2'
if [[ -n ${user_tmp_file} ]]; then
  silent 'per-user temp directory (DARWIN_USER_TEMP_DIR) is not temp' "${tmp}" "rm -f ${user_tmp_file}"
fi
missing_blob="$(git -C "${pclone}" ls-files -s f.txt | awk '{ print $2 }')"
if GIT_NO_LAZY_FETCH=1 git -C "${pclone}" cat-file -e "${missing_blob}" 2>/dev/null; then
  failed=$((failed + 1))
  echo 'FAIL the hook fetched a missing blob into the partial clone' >&2
else
  passed=$((passed + 1))
fi

# -- Round 5 -------------------------------------------------------------------
silent 'long s spelling of .svn, relative' "${tmp}/svnwc" "rm -rf .${long_s}vn/pristine"
silent 'long s spelling of .svn, a file' "${tmp}" "rm -f ${tmp}/svnwc/.${long_s}vn/wc.db"
silent 'long s spelling of .svn inside node_modules' "${repo}" "rm -rf pkg3/node_modules/dep/.${long_s}vn/pristine"
silent 'replace ref standing in for a deleted blob' "${rrepo}" 'rm f.txt'
silent 'an object store of packs only' "${tmp}" "rm -rf ${tmp}/store"
silent 'its pack directory' "${tmp}" "rm -rf ${tmp}/store/pack"
silent 'one pack index' "${tmp}" "rm -f ${tmp}/store/pack/${pack_idx}"
silent 'core.excludesFile naming a nested .gitignore' "${xrepo}" 'rm -rf src/dist'
silent 'a repository below a node_modules, its .claude' "${nmrepo}" 'rm -rf .claude'
for v in .sl .pijul _MTN RCS SCCS .fslckout _FOSSIL_; do
  silent "${v} metadata" "${tmp}" "rm -rf ${tmp}/vcs/${v}-holder"
done

# -- Round 6 -------------------------------------------------------------------
silent 'main checkout of a repository with a linked worktree' "${wrepo}" 'rm tracked.txt'
approves 'the same delete in its linked worktree' "${scratch}/wt-linked" 'rm tracked.txt'
approves 'a plain clone with no linked worktree' "${scratch}/wt-clone" 'rm tracked.txt'

# -- Final review --------------------------------------------------------------
silent 'renamed packs in a moved object store, with a tracked file' "${scratch}/packs-a" \
  "rm -r a.txt ${movedstore}/o"
silent 'the moved object store alone' "${tmp}" "rm -rf ${movedstore}/o"
silent 'a tracked file in a repository whose objects are a symlink' "${scratch}/packs-a" 'rm a.txt'
silent 'renamed packs in an ignored build/' "${rb}" 'rm -rf build'
silent 'symlink retargeted to a name ending in a newline' "${repo}" 'rm nlink/l'
silent 'a repository nested in a main checkout with worktrees' "${wrepo}/m/nested" 'rm n'
silent 'tracked, clean .github' "${repo}" 'rm -rf .github'
silent 'a file in tracked, clean .github' "${repo}" 'rm .github/x'
silent 'glob form through link//' "${tmp}/linkglob" 'rm -rf link//*'
silent 'glob form through link/./' "${tmp}/linkglob" 'rm -rf link/./*'
approves 'glob form on the real dir' "${tmp}/linkglob" 'rm -rf real/*'
silent 'intent-to-add entry' "${itarepo}" 'rm empty'

# A mount point, as the target and inside it (macOS: a scratch disk image).
if [[ "$(uname -s)" == Darwin ]] && command -v hdiutil >/dev/null 2>&1; then
  mkdir -p "${tmp}/holder/mnt"
  if hdiutil create -quiet -size 1m -fs HFS+ -volname devbox-safe-rm "${scratch}/m.dmg" >/dev/null 2>&1 &&
    hdiutil attach -quiet -nobrowse -mountpoint "${tmp}/holder/mnt" "${scratch}/m.dmg" >/dev/null 2>&1; then
    mounted="${tmp}/holder/mnt"
    mkdir -p "${mounted}/proj" && echo p >"${mounted}/proj/f"
    silent 'a mount point itself' "${tmp}" "rm -rf ${tmp}/holder/mnt"
    silent 'a dir holding a mount point' "${tmp}" "rm -rf ${tmp}/holder"
    silent 'a dir on a mount below the temp root' "${tmp}" "rm -rf ${mounted}/proj"
    silent 'a dir on a mount, relative' "${tmp}" "cd ${mounted} && rm -rf proj"
    silent 'glob form on a mount' "${tmp}" "rm -rf ${mounted}/*"
    hdiutil detach -quiet -force "${mounted}" >/dev/null 2>&1 && mounted=''
  else
    echo 'devbox-safe-rm: no disk image could be mounted; skipping the mount cases' >&2
  fi
fi

# -- Inputs the fixtures must still hold ---------------------------------------
# Every case above only asks; none deletes. Prove it for the riskiest ones.
for f in "${repo}/top.txt" "${repo}/mod/m.txt" "${tmp}/a.log" "${tmp}/withenv/${env_name}"; do
  [[ -e ${f} ]] || {
    echo "FAIL fixture ${f} disappeared" >&2
    failed=$((failed + 1))
  }
done

echo "devbox-safe-rm: ${passed} passed, ${failed} failed (hook under ${hook_bash})"
((failed == 0))
