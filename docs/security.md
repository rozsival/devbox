# 🛡️ Security Model

> This container exists to run agents with bypassed permissions, where the worst case is a lost project tree, not a lost
> host. The threat model is an agent (or dependency) executing arbitrary code inside the devbox.

**Related:** [Architecture](architecture.md) · [Secrets](secrets.md) · [Docker](docker.md) · [Networking](networking.md)

---

## 🧱 Boundaries

| Boundary                   | Enforced by                                                                                                                                                                                                                                 |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| No host filesystem access  | Only `${DEVBOX_DATA_DIR}` mounted, at `/home/dev` (see accepted limit 5)                                                                                                                                                                    |
| No host root Docker daemon | `/var/run/docker.sock` not mounted; reachable daemon is rootless                                                                                                                                                                            |
| No privilege escalation    | `user: ${HOST_UID}:${HOST_GID}`, `cap_drop: [ALL]`, `no-new-privileges:true`                                                                                                                                                                |
| No public network exposure | `${BIND_ADDR}:${DEVBOX_SSH_PORT}:2222` — Tailnet address only                                                                                                                                                                               |
| No host services           | `devbox-docker-firewall`: the devbox bridge reaches only the project daemon's ports; dev's uid and its subordinate uids — the daemon, its containers, `--network host` ones included — no host address, loopback included, but the DNS stub |
| No password auth           | `PubkeyAuthentication yes`, `PasswordAuthentication no`, `UsePAM no`                                                                                                                                                                        |
| No private keys at rest    | Devbox holds no SSH private key; `AllowAgentForwarding yes` only lets `ssh -A devbox` borrow the laptop's forwarded 1Password agent for one connection                                                                                      |

## 👤 No root process at runtime

The image ends as `USER dev`; `sshd` runs unprivileged, only ever authenticating the user it already is — with
`UsePAM no` and pubkey-only auth, needing neither `/etc/shadow` nor setuid.

This is the isolation that matters: user namespaces aren't configured on the workstation, so container root would be
**host UID 0** in a runtime escape. Running as the dedicated `dev` account (UID 1001) means an escape lands as a host
user with no password, no sudo, no files outside `/home/dev`.

Verify:

```bash
ssh <workstation> 'cd ~/devbox && docker compose exec -T devbox ps -o user= -p 1'   # dev
ssh <workstation> 'cd ~/devbox && ./bin/devbox logs | grep "Server listening"'      # no "must be run as root"
```

## 🎒 What the container holds

Authority is enumerated, not ambient: each credential is scoped, separately revocable, separately attributable.

| Purpose                                          | Credential                                                               | Reach                                                    |
| ------------------------------------------------ | ------------------------------------------------------------------------ | -------------------------------------------------------- |
| Agent git where the App is installed (push)      | per-repository GitHub App installation token, one App per identity       | one repo, 1h                                             |
| Agent git elsewhere (clone, fetch only)          | the identity's fine-grained PAT, read-only                               | its named repos, read-only                               |
| Manual git, incl. signing (you)                  | the laptop's 1Password agent, forwarded per connection (`ssh -A devbox`) | same as your laptop; the container stores no private key |
| Agent `gh` on one repository (PRs, issues, runs) | that repository's GitHub App installation token, else the PAT below      | App: one repo, 1h (cached ≤30 min on tmpfs)              |
| Dashboards, CI, issues, account-wide `gh`        | one read-only fine-grained PAT per GitHub account                        | named repos, read-only                                   |
| LLM inference                                    | per-project GCP service-account key                                      | one dev project, predict-only                            |
| Project secrets                                  | that project's `.env`                                                    | one project                                              |

Notably absent: any 1Password account (`op` isn't installed), any GitHub private key, any Google user credential. See
[Secrets](secrets.md).

## 🔍 What an agent inside the devbox can reach

**Can**: the whole `/home/dev` tree — every identity's public keys (useless without the laptop's forwarded agent), every
identity's `gh` token, each configured App's private key, every project's `.env` and GCP key — plus the internet, the
LAN (Tailnet peers included, at their LAN addresses) and the rootless project Docker daemon ([Docker](docker.md)).

**Cannot**: the host filesystem outside the data dir and world-readable paths, the host's **root** Docker daemon, the
host's own services (its sshd included), other Tailnet machines over the overlay (accepted limits 1 and 8 name the
routes that remain), the devbox container's own lifecycle, root inside the container, any unpublished port, and any
1Password vault.

The consequence: an agent with shell access can push through the same App token `git`/`gh` already resolve, and read
each configured App's private key, every identity's PAT, and every project's `.env` and GCP key directly. None of that
writes as you: every PAT is read-only, so a stolen one reads what it names and nothing more, and every write an agent
makes carries an App's bot. Your own GitHub push authority stays out of reach — no private key to steal — unless an
`ssh -A devbox` connection is open (accepted limit 2).

> [!IMPORTANT]
> Treat a compromise as "revoke every identity's PAT and App key, plus the service-account key," not "rebuild a laptop."

## ⚠️ Accepted limits

These are known and deliberate, not gaps to be closed later:

1. **No egress filtering beyond the Tailnet overlay.** Outbound internet is unrestricted — the box needs it — and so is
   the LAN: the boundary cuts only the overlay (`tailscale0` and Tailscale's address ranges), so a Tailnet peer stays
   reachable at its LAN or public address like any other machine. An agent reading a poisoned issue or README can send
   whatever it holds anywhere on the internet: IAM and token scoping limit what it can _reach_, not _send_. The
   container is a containment boundary for authority, **not** confidentiality — assume anything inside can leave. A
   Tailscale exit node on the workstation removes the internet too: its traffic leaves through `tailscale0`, which the
   boundary drops for the devbox and the project daemon.
2. **A forwarded agent is open to the whole devbox while it lasts.** `ssh -A devbox` exposes the 1Password agent
   socket for the connection's lifetime, and the socket belongs to `dev`: every process in the container can use it, not
   just the shell you forwarded it into. Only agent git is fenced (HTTPS, through the `omp`/`claude` launchers, which
   also start each session without `SSH_AUTH_SOCK` — a default, since the socket stays findable under `~/.ssh/agent/`
   (OpenSSH ≥ 10.1)). That directory is on the bind mount, so any project container that bind-mounts `/home/dev`, and
   `dev` on the host, reach the socket as well. And 1Password approves per key and per application, not per use — a key
   your terminal app is already approved for (by this connection, or by anything since 1Password last locked) signs
   without a prompt. What a key can reach is therefore the limit: `devbox.pub` opens only the devbox and is never
   registered on GitHub, and `Host <workstation>` uses the default identity's key rather than `devbox.pub`. That
   narrows, not closes: a key used through `ssh -A devbox` stays approved for the terminal app until 1Password locks,
   so it can sign from the devbox too — what keeps the devbox off the workstation's sshd is `devbox-docker-firewall`.
   What a forwarded agent still reaches is your GitHub push authority, for the connection's lifetime. Plain `herdr`
   panes, `./bin/devbox shell` and a bare `ssh devbox` never forward one.
3. **No isolation between projects.** One container, one `dev` user, one bind mount: an agent in project A can read
   project B's `.env` and GCP key. Cloning something less trusted is where per-project containers or separate users stop
   being over-engineering.
4. **Secrets are plaintext at rest.** `.env` files, `gh` tokens, key files and the Claude Code login
   (`~/.claude/.credentials.json`) are unencrypted on the workstation's disk, readable by the host user. Workstation
   disk encryption and host account hygiene are part of this security model, not separate.
5. **The project Docker daemon widens reach to the `dev` account.** Anything in the container can start a container
   through that socket, including one bind-mounting a host path — but only as unprivileged `dev`: world-readable host
   files to read, only `dev`-owned files to write, never host root, the root daemon, or your home directory (`750`,
   untraversable by `dev`). The price of `docker compose up` inside the box — why the daemon gets its own dedicated
   account. dev's systemd user manager reads its units and `environment.d` from root-owned `/etc/devbox-docker`, which
   closes the path the devbox writes directly — files in the bind mount. It doesn't close the manager: a project
   container can bind-mount `/run/user/1001` (its bus, `systemd/private`, `systemd/user.control`,
   `systemd/transient`) and change the daemon's environment or start units as `dev` in the host's network namespace.
   What bounds such code is the boundary's rules for dev's uid and its subordinate uids: no host address — loopback
   included — but systemd-resolved's stub, no Tailnet overlay, and its listening sockets answer only on loopback and
   `docker0`. The same rules cover a `--network host` project container, which shares the host's network namespace.
   Not applied: running the daemon from a root-owned system unit with no user manager.
6. **A project port is one firewall rule away from the Tailnet.** Rootless Docker binds every published port on
   `0.0.0.0`, with no way to change that — `devbox-docker-firewall`, an nftables table dropping input to that daemon's
   sockets outside loopback and the devbox bridge, confines them, and keeps the host's own services and the Tailnet
   overlay away from the devbox and its project containers. `./bin/devbox doctor` fails if it is inactive or stale;
   removed (`sudo systemctl disable --now devbox-docker-firewall && sudo nft delete table inet devbox` — `stop` alone
   leaves the table loaded), every project port reaches the Tailnet and LAN, and the devbox reaches the host's sshd and
   every Tailnet peer. A container the host's _root_ daemon puts on the default bridge shares the devbox's boundary —
   give such containers their own network. See [Docker](docker.md).
7. **On the laptop, an agent is only as contained as your OS user.** The launchers, the `gh` shim and the SSH fence
   choose which credential an agent session uses _by default_ — clearing what your shell carries (an IDE's askpass,
   `GITHUB_TOKEN`, `SSH_AUTH_SOCK`) and refusing every credential prompt; they cannot stop a process running as you from
   calling the real `gh` with your OAuth login, reading the keychain, or asking the 1Password agent for a key (1Password's
   approval prompt is then the only gate). On the devbox the same bypass gains nothing — no credential broader than the
   scoped PATs and App keys exists there. Keep autonomous or bypass-permission work against orgs you own on the devbox;
   on the laptop, a `gh auth logout` (your own `gh` on fine-grained PATs too) and 1Password set to approve every SSH
   request remove what a bypass could reach.
8. **`tailscaled`'s LocalAPI relays to the Tailnet.** `/run/tailscale/tailscaled.sock` is world-accessible (`0666`),
   and its `dial` endpoint has `tailscaled`, as root, open a connection for any local caller. From 1.98 it relays only
   Tailnet routes — a peer, its sshd included — and answers a non-Tailscale address with Dial-Self; before 1.98 it
   dialled any address, so the host's own services, its sshd and loopback included, were reachable too, past the
   boundary's uid rules. `./bin/devbox doctor host` therefore fails when the running `tailscaled` is below 1.98 (read
   from `tailscale version --daemon`, falling back to the CLI's version when the daemon doesn't answer). The project
   daemon can bind-mount any host path `dev` reaches, so a project container can relay to a peer through that socket.
   The boundary stops direct connections from the devbox and its containers, not this relay. Not applied, being the
   host's decision: restricting `/run/tailscale` through a `tailscaled` drop-in, or hiding it from dev's user manager.

### Command allowlists are a guardrail, not a control

An agent's own command allowlist — forbidding `op`, `gcloud` and similar — is a useful guardrail, not a control: a
subverted agent can call the same APIs through an SDK without either binary. The boundary is what each credential can
do.

`home/.omp/agent/config.yml` ships exactly such a guardrail for OMP, seeded when absent by `bootstrap` and
`./bin/devbox agent install`: `bash.patterns` that deny `gh auth token|login|…`, an absolute-path `gh` (`*/bin/gh *` —
past the shim), unsetting or reassigning the launcher's exports (`env -u`, `unset GIT_CONFIG_GLOBAL`, `GH_CONFIG_DIR=…`;
reading them stays allowed; `env -i` prompts instead, since this repo's own smoke tests use it), keychain reads,
`gh secret`/`variable`/`repo delete`, `--no-verify` and force pushes, Vercel/Neon project deletion, API `DELETE`s and
token minting, and prompt for `op`, `gcloud`, `terraform apply` and every Vercel/Neon write, deploy, login or
database-password read ([Toolchain](toolchain.md#-omp)).

> [!WARNING]
> `deny` holds even under yolo, but the rules match command text in the `bash` tool only — not `eval`, not a script file
> — and a project's own `bash.patterns` **replaces** the list (settings arrays never merge), so such a repository has to
> carry the rules it wants itself.

`home/.claude/settings.json` is the Claude Code counterpart: `permissions.deny` and `permissions.ask` rules, written
`Bash(<pattern>)`, that mirror the OMP list with the same deny/prompt split (bare `op`/`gcloud`/`vercel` and
`*vercel token` folded into their `Bash(… *)` or `Bash(*vercel)` rule). Seeded or merged by
`bootstrap` and `./bin/devbox agent install` when `~/.claude/settings.json` has no `permissions.deny`, re-applied by
`./bin/devbox sync claude`; merge, not copy, because other tools write that file ([Toolchain](toolchain.md#-claude-code)).
The same preset also approves recoverable deletes without a prompt ([below](#-recoverable-deletes)). Claude Code
differs from OMP in four ways that matter here:

- It splits compound commands (`&&`, `;`, `|`, subshells, `$(...)`) and applies `deny` and `ask` to every subcommand,
  strips wrappers (`timeout`, `nice`, `command`, …) before matching, and matches past leading environment assignments.
  `true && GH_CONFIG_DIR=/tmp/x true`, `command gh auth token` and `/opt/homebrew/bin/gh --version` are all denied.
- `deny` holds even under `bypassPermissions`.
- Permission arrays **merge** across settings scopes (user, project, local), so a repository's own
  `.claude/settings.json` cannot drop these rules the way a project's `bash.patterns` replaces OMP's.
- Nothing in the preset corresponds to OMP's `secrets.enabled` obfuscation.

The limits are otherwise the same: rules match command text, so an interpreter one-liner or a script file walks past
them — accepted limit 7 still applies on the laptop.

## ♻️ Recoverable deletes

Deleting a file in a temp directory loses nothing that was meant to last, and deleting one git holds unchanged at
`HEAD` loses nothing at all: `git restore` brings it back. The Claude Code preset therefore ships a `PermissionRequest`
hook (matcher `Bash`), `~/.local/libexec/devbox-agent/devbox-safe-rm` from `home/.local/libexec/devbox-agent/`, that
answers such a delete's prompt with `allow` — and stays silent, leaving Claude's normal prompt, for everything else. It
never denies and never runs in plan mode. It runs whenever Claude is about to ask, whatever raised the prompt, so its
`allow` also answers an `ask` rule of your own that matches such an `rm` — that is the intent; a `deny` rule still wins
over it. The preset runs it as `/bin/bash -p` and then exits 0 whatever happened, because Claude Code reads exit 2 from
this hook as a blocking deny: privileged mode ignores `BASH_ENV`, `SHELLOPTS`, `BASHOPTS`, `CDPATH` and `GLOBIGNORE`
from the environment, and the script turns posix mode (`POSIXLY_CORRECT`) off, clears every `GIT_*` and `PERL5*`
variable, sets `GIT_NO_LAZY_FETCH=1` and `GIT_NO_REPLACE_OBJECTS=1` (a replace ref would make a deleted object look
present, and checkout would restore the replacement), forces `core.excludesFile=/dev/null` and `core.fsmonitor=false`
on every git call (`GIT_CONFIG_COUNT`), and drops every relative `PATH` entry. The preset gives it 30 s; one that runs
out of time leaves the normal prompt (95,000 tracked files take about 7–12 s). It trusts the request's JSON — the command
and above all its `cwd`, which every relative path is resolved against. Every unexpected input, error or oversized walk ends in silence: a missed approval costs a prompt, a wrong one
costs data. It approves a command only if **all** of the following hold.

**The command is only `rm`, optionally after `cd`.** Simple commands separated by `;`, newline or `&&`, each one `rm`
with nothing but `-r -R -f -v -d`, `--recursive --force --verbose --dir` and `--`, all before the first target (BSD rm
reads a later `-x` as a file name), or `cd <dir>` with one argument that is absolute, `~`-based, `.` or `./…`, with no
`..` anywhere: a bare name may resolve through a `CDPATH` the session's shell sets unseen, and `..` resolves logically
or physically depending on shell options (`set -P`, zsh's `chase_links`) the hook cannot see. After a `cd`, every later
command must hang on `&&`, since behind `;` it would also run where the `cd` failed. Anything the shell would expand,
substitute or redirect is refused: `$`, backticks, backslashes anywhere (inside double quotes the shell keeps some and
drops others), `<`, `>`, `|`, `||`, a lone `&`, `(`, `)`, `{`, `}`, unquoted `[`, `]`, `?`, `!`, `#`, `^`, `=`,
`~user` and any `~` but a leading `~` or `~/`, and a `'` straight after a closing `'` (zsh's `rcquotes` reads `''`
inside quotes as one quote). So is any blank but space, tab and newline — a form feed, a vertical tab, U+00A0, U+2028,
U+3000 and their kin read as a gap but are part of a word to the shell — and any control character. Quoted text is
literal, so `rm -rf 'app/[locale]'` qualifies.

**One glob form, judged without expanding it.** Shells disagree on what a pattern matches — by locale (`?` and
brackets byte- or character-wise; the Kelvin sign and the dotted `İ` fold to `k` and `i`), by option (zsh's `**` from
`*""*`, `NO_CASE_GLOB` folding a pattern's literal segments even on a case-sensitive file system) and by version (bash
up to 5.1 and dash expand `.*` to `.` and `..`). So a word with an unquoted `*`, `?` or `[` gets no decision, with one
exception: `*` as the whole word, or `<literal path>/*` with the `*` the entire last segment and nothing after it. That
form is judged as `rm -r` of every entry of the literal directory, dotfiles included, never the directory itself — at
least what any shell can make of it. The literal path must be plain ASCII, hold no `.` or empty component (`link//*`,
`link/./*`) and be a real directory, not a symlink; none of
its typed components may have a sibling spelled the same in another case (or exist only in another case), on any file
system; and the directory must not be empty. Every entry is then checked as a target of its own; one starting with `-`
before any `--` is refused, since rm would take it as an option, and so is one that is a symlink to a directory, which
zsh's `mark_dirs` would hand to rm as `link/`.

**Every target is recoverable.** A target is resolved as rm sees it: relative to the working directory, its directory
part through symlinks, its last component not followed — a symlink is itself the target, and `link/` with a trailing
slash, which rm follows, is refused. Nothing inside a git directory under any name passes: every directory from the
target's up to `/` is checked for `HEAD` with `objects/` and `refs/` (a repository, bare or `--separate-git-dir`),
`HEAD` with `commondir` or a `gitdir` file (a linked worktree's admin directory), and `pack/` with `info/` (an object
store, such as another repository's alternate), and git is asked `rev-parse --is-inside-git-dir` too. Then the target
must be either

- **inside a git work tree, below its toplevel** — any directory in or above the target's that holds a `.git`, looked up
  on disk rather than asked of git, which refuses a repository it distrusts. This comes first, so a checkout inside
  `/tmp` gets these rules too (a work tree with no `.git` of its own, reached through another repository's
  `core.worktree`, is not found and counts as whatever its location is), and the target must exist: a missing one has
  nothing to be checked against, so a parse that ever diverged from the shell's fails safe. The repository is the one
  found from the target's directory (a submodule or linked worktree being its own), with a commit at `HEAD`, the index
  identical to it under the target, no filter driver in the repository's own config, and no alternates
  (`objects/info/alternates`: borrowed objects restore only while their store lives, and that store may be a temp
  directory the same line deletes). It must not be the main checkout of a repository that has a linked worktree
  (`--git-dir` equal to `--git-common-dir`, and anything under its `worktrees/`): a repository worked on through
  worktrees keeps its main checkout for the person, and an approval there would also override a project hook that
  refuses edits in it — with two `PermissionRequest` hooks, either one's `allow` wins. Every enclosing repository up to
  `/` (the nearest `.git` above each toplevel: a submodule's superproject, the repository a nested clone sits in) is
  held to the same test. A plain clone with no linked worktree is judged like any other. The object store must be
  physically where it belongs: `--git-path objects` resolves to the common directory's own `objects/`, neither
  `objects/` nor `objects/pack/` is a symlink and no pack file is, since a store moved out of `.git` is plain data to
  every other check. Every index entry must also be in `HEAD`'s tree, so an intent-to-add entry (`git add -N`), which
  `diff --cached` does not show, gets no decision. Every index entry under the
  target must be a plain stage-0 file or symlink with a printable ASCII path — no assume-unchanged, skip-worktree or
  conflict, which hide changes, and no gitlink, since an uninitialised submodule restores nothing — present in the work
  tree with that type and exec bit (so a chmod hidden by `core.fileMode=false` counts), a symlink's target printable
  ASCII, and with content that `git hash-object --no-filters` hashes to the index's blob — each path passed as an
  argument, since `--stdin-paths` strips a trailing carriage return and unquotes a line starting with `"` — so neither a
  clean filter, `ident` nor end-of-line conversion hides a change. The blob must be in the object store itself
  (`cat-file` with `GIT_NO_LAZY_FETCH`): a partial clone may hold only its id. No filter or fsmonitor program runs: git
  runs with `core.fsmonitor=false`, without its untracked cache and with literal pathspecs, and nothing here makes it
  apply a filter. Empty git output proves nothing by itself, so the walk decides what is there: every file and symlink
  `find` reaches must be tracked, or have among its directories one whose whole name is `node_modules`, `.turbo`,
  `.next`, `dist`, `build`, `coverage`, `target` or `tmp` and that git reports as wholly ignored
  (`git ls-files --others --ignored --directory`, which never collapses a directory holding a tracked file) — by a rule
  of the repository's own, as committed. Every `.gitignore` from the toplevel down to the directory's parent, and the
  directory's own, that exists must be tracked, a plain stage-0 entry, byte for byte its index blob and that blob the
  one at `HEAD` — so an untracked `.gitignore`, or a `build/` line appended and not committed, makes nothing
  regenerable. The matching rule (`git check-ignore -v --no-index`) must come from one of those files in the
  directory's parent or above (its own `.gitignore` speaks only for what lies inside it) and not be a negation, never
  from `.git/info/exclude` or `core.excludesFile`, which are per machine (a global ignore of `tmp` would otherwise
  approve every repository's `tmp/`); `core.excludesFile` is forced to `/dev/null` besides, so even one naming a
  nested `.gitignore` cannot spread its rules over the whole repository. No directory above it may be ignored by any source, asked in the same
  `check-ignore` call: git descends into an ignored `private/` to find a force-added file and then lists `private/tmp/`
  as ignored by `private/`'s rule, which says nothing about `tmp/` being regenerable. A path with any component starting
  with `:` is refused, since `check-ignore` reads its input as pathspecs (`:/tmp` is the toplevel's `tmp`) and refuses
  `--literal-pathspecs`. This catches accidents, not intent: an agent that commits a `.gitignore` change first still
  passes. And no index entry may lie under it,
  compared case-insensitively (with `core.ignorecase` off, a tracked `Dist/keep.txt` is the same directory as an
  ignored `dist/` on macOS). Being merely below an ignored directory is not enough (an ignored `private/` holding `tmp/`
  is not regenerable), nor is being below a regenerable name that is not itself ignored (a tracked `build/` holding an
  ignored `private/`). Any other untracked or ignored file — work in progress, a local database, a `*.local` config, a
  secret — keeps the prompt; or
- **inside `/tmp`, outside any work tree**, never `/tmp` itself (on macOS `/private/tmp`, resolved physically). Not
  temp: any per-user temp directory (macOS's `getconf DARWIN_USER_TEMP_DIR`, `$TMPDIR`), where running apps keep live
  state such as SQLite `-wal` and `-shm` files, and which anything can point elsewhere; and `/var/tmp`, which survives
  reboots, so programs keep things there meant to last. Claude Code keeps every session's files under `claude-<uid>/<project>/<session>/` in a temp root;
  any top-level directory there whose name starts with `claude` in any case (macOS file systems ignore case, and the
  path is compared as typed) passes only as `claude*/<project>/<this session>/scratchpad/<something>`, the session
  and `scratchpad` spelled exactly, so another session's files, Claude's own state beside them and the scratchpad
  itself keep the prompt.

**Nothing protected is touched.** No target may be, contain, or lie anywhere below (on its whole physical path, so a
clone under `~/.claude/plugins/` counts) a `.git` — a nested one inside `node_modules` included — a `.env` or `.env.*`
file (`.env.example` passes), a `.claude`, a `.omp` or a `.github` (workflows that run with the repository's
credentials), or another version control system's metadata (`.hg`, `.svn`,
`.jj`, `.bzr`, `_darcs`, `CVS`, `.sl`, `.pijul`, `_MTN`, `.fslckout`, `_FOSSIL_`, `RCS`, `SCCS`), compared
case-insensitively. The whole physical path must be printable ASCII: `pwd -P` keeps a name as typed and APFS folds more
than ASCII case (`.ſvn`, with U+017F, opens `.svn`), so a non-ASCII spelling could reach a protected name unseen. Nor
may it contain or lie inside a git directory or object store under another name — loose objects in two-hex fan-out
directories, `pack-*.pack`/`.idx`/`.rev`/`.bitmap`/`.keep` files, any `*.idx` or `*.pack` in a directory named
`pack` (git loads those whatever their name), `multi-pack-index`, `commit-graph` — anything but
files, directories
and symlinks (a FIFO, socket or device is not restorable), or a name with anything but printable ASCII (a newline or
carriage return would break the hook's line-based lists, and a name that is not valid UTF-8 could be mangled on its way
through them). Nor may it involve a mount: the target and every entry below it must lie on the device of its temp root
or toplevel, so a volume mounted anywhere below `/tmp` or inside a repository — the target itself, a directory above
it, or an empty mount point inside it — gets no decision, since `rm -r` would empty a mounted file system too. A walk
that fails or passes 100,000 entries is refused.

What it does not cover: the check reads the file system when the prompt would appear, and anything that changes
between then and the moment rm runs — a file created, a commit, a checkout — is not seen; `rm` and `cd` are trusted to
be the commands their names say — aliases and functions in the session's shell are invisible to the hook — so an
alias or function of that name in your shell profile, a zsh global alias
(`alias -g`, which can rewrite any word of the line) or a `chpwd` hook running on `cd` is your own configuration and can
change what the line does; and "restorable" means from the local `.git` (never itself approved), not from a pushed
branch. `test/devbox-safe-rm.sh`, run by `make check`, holds the cases.

### OMP has no equivalent

OMP's preset is unchanged, for three reasons found in OMP 18.13 itself. `bash.patterns` does accept `approval: allow`,
but a pattern matches the whole command line with `*` spanning spaces, so `rm /tmp/*` would also approve
`rm /tmp/x ~/y`: no glob can be narrow enough. Extensions cannot approve either — a `tool_call` handler can only block
a call or rewrite its input, and `tool_approval_requested`/`resolved` are notifications. And the preset leaves
`tools.approvalMode` at OMP's default, `yolo`, where a bash command no `prompt` or `deny` pattern matches — any `rm`,
recoverable or not — already runs without a prompt; in the other modes OMP's built-in critical pattern
(`rm -rf /<path>`) prompts ahead of any `allow` pattern.

## 🚫 Deliberate boundaries

| Boundary                          | Rationale                                                                                                                                                                                                                                                                                                                   |
| --------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **No host _root_ Docker socket**  | Mounting `/var/run/docker.sock` would hand the sandbox host root, voiding the container's point. Projects needing containers get a sibling rootless daemon owned by a dedicated unprivileged host user, reached through `DOCKER_HOST` — see [Docker](docker.md) for why nesting one needs the container's `CAP_SETUID` back |
| **No root process at runtime**    | See [No root process at runtime](#-no-root-process-at-runtime)                                                                                                                                                                                                                                                              |
| **No 1Password in the container** | A live `op` session is readable by any agent in that shell, turning a one-project leak into every vault the account can read — while project secrets sit in a plaintext `.env` regardless, since the app must read them. Secrets render on the laptop, then copy in                                                         |
| **No Google user credential**     | `gcloud auth application-default login` writes a non-expiring refresh token for your whole Google identity; projects get a service-account key scoped to their own GCP project instead                                                                                                                                      |

## 🤝 Trust assumptions

1. **The Tailnet is the perimeter.** Any Tailnet device with an authorized key can reach the devbox — no second factor
   on the SSH port.
2. **`authorized_keys` trusts a GitHub account.** Every key on the `DEVBOX_GITHUB_USER` account can log in — the same
   trust model the workstation's host sshd uses. Narrow it: clear `DEVBOX_GITHUB_USER`, list keys explicitly in
   `DEVBOX_EXTRA_AUTHORIZED_KEYS`. The file itself is the bind mount's, so an agent can add a key to it: that key opens
   the devbox — from the Tailnet only — until the next container start rebuilds the file. Without root at runtime there
   is no file sshd reads that `dev` can't write. It opens nothing on the host: `docker setup` puts `DenyUsers dev` in
   the host's sshd (`/etc/ssh/sshd_config.d/devbox-docker.conf`), since `/home/dev/.ssh` is that account's too and a
   locked password doesn't stop a key login under `UsePAM yes`.
3. **The `dev` host user owns the data, and root can read everything.** The bind mount belongs to the dedicated `dev`
   account, which also owns the project Docker daemon; your host account reaches it only via `sudo`. The container
   protects the host from the agent, not the files from its owner.

---

## ❓ FAQ

### Why not gVisor, Firecracker, or a VM?

Overkill for the actual risk (a hostile dependency, not a targeted attacker), and it breaks herdr's attach model. The
cheap, high-value controls — non-root, no socket, dropped capabilities, address-scoped port — are already in place.

### Should I enable user namespace remapping on the host?

It would let the container run as root safely, but nothing here needs container root, and `userns-remap` breaks the
UID-matched bind mount that makes the data dir inspectable from the host — not worth it.

### Is `cap_drop: ALL` compatible with sshd?

Yes: sshd never changes user. Dropping `CHOWN`/`SETUID`/`SETGID` is exactly what a root-launched sshd would have needed.

### What if unprivileged sshd stops working after an OpenSSH update?

Fix the unprivileged path — it's the whole design. `cap_add` and a root-launched sshd are off the table per
[AGENTS.md](../AGENTS.md) rule 4; `./bin/devbox shell` still gets you in while sshd is broken, so there's no lock-out
risk to trade the boundary away for.

### Can I give an agent a narrower key?

Already the default: agents write only through each identity's own GitHub App, scoped to specific repositories and
permissions, and `gh` otherwise uses a read-only fine-grained PAT rather than an account-wide OAuth token. The forwarded
1Password agent stays broad for manual work because it's yours — see accepted limit 2.

### Would per-repo deploy keys be tighter than the fine-grained PAT?

Not any more: the PAT writes nothing. Every agent write goes through an installed GitHub App, which mints a token scoped
to exactly one repository for one hour; a repository without the App is read-only to agents. Install the App on the
repositories agents should change instead of adding a deploy key.

### How do I revoke access from a lost laptop?

The SSH keys are 1Password items, not files, so the laptop carries no key — but remove the _Devbox Laptop_ key from
`DEVBOX_EXTRA_AUTHORIZED_KEYS` anyway (`devbox.pub` is never registered on GitHub), restart the container
(`authorized_keys` rebuilds on every start), and drop the default identity's key from the workstation's own
`~/.ssh/authorized_keys`. What the laptop **does** hold in plaintext, if `./bin/devbox agent install` ran there, is the
agent's own credentials: one `GH_TOKEN_<SLUG>` per identity in `~/.config/devbox/secrets.env`, and each configured
identity's App pem under its own `app` directory. Revoke every identity's PAT, rotate every App private key — same list
as a container compromise above.

### Why does Claude still ask before this `rm`?

Because `devbox-safe-rm` could not prove the delete recoverable, and it says nothing rather than guess
([Recoverable deletes](#-recoverable-deletes)). The usual reasons: an untracked or modified file under the target, an
ignored file outside the regenerable directories, a `.env`, `.git` or `.claude` inside it, a `$VAR` or a second command
on the line, a `cd` to a bare directory name or through `..`, any glob but `<dir>/*`, another session's temp files, or more than
100,000 entries to walk. Run the hook by hand to check one
command; it prints the `allow` decision or nothing:

```bash
jq -n '{hook_event_name: "PermissionRequest", tool_name: "Bash", tool_input: {command: "rm -rf dist"}, cwd: env.PWD}' |
  ~/.local/libexec/devbox-agent/devbox-safe-rm
```
