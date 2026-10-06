---
name: devbox-cli
description: Drives ./bin/devbox, the one CLI for the devbox workstation and the laptop - working out which machine a command must run on and how to reach it (directly, or `ssh <workstation> 'cd ~/devbox && ./bin/devbox ...'`), which commands are read-only, which are pane-safe and which kill live SSH sessions or need sudo or a human answer, reading its exit status and [OK]/[WARN]/[ERROR] output, and changing the CLI itself (cli/bashly.yml, cli/commands/, cli/lib/, make build). Use this whenever someone asks to run, check, restart or inspect the devbox - doctor, sessions, logs, keys, up, down, rebuild, bootstrap, hook, skills, env, sync omp, sync identities, agent install, install, completions, docker setup - hits "This is a workstation command" or "This is a laptop command", gets "Refusing to continue with live sessions", or wants to add or change a devbox subcommand or flag.
---

# devbox CLI

`bin/devbox` is one bashly-generated CLI for both machines: workstation commands drive the container's Docker
daemon, laptop commands push state into it, and every command is side-guarded. Drive it rather than reproducing its
steps by hand (raw `docker compose`, raw `rsync`): the commands carry preflights and guards a hand-typed equivalent
skips.

Full reference: `docs/cli.md`. For flags, trust `./bin/devbox <command> --help` over memory - it is generated from the
same `cli/bashly.yml` the command runs. Which apply step a change needs (`up` vs `rebuild` vs `bootstrap`) is the
`devbox-deploy` skill's; fixing what `doctor laptop` reports is `devbox-laptop`'s.

## 1. Where am I, and how do I reach the right side

Decide before running anything: `uname -s`, plus `/.dockerenv` for the container.

| You are on                                                     | Run directly                                                                                                        | Reach the other side                                                                              |
| -------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| macOS laptop, in the repo checkout                             | `deploy`, `sync omp`, `sync identities`, `agent install`, `doctor`                                                  | `ssh <workstation> 'cd ~/devbox && ./bin/devbox <cmd>'`                                           |
| Linux workstation, `~/devbox`                                  | `env`, `up`, `down`, `rebuild`, `bootstrap`, `skills`, `sessions`, `logs`, `hook`, `keys`, `docker setup`, `doctor` | none needed - the laptop commands are the user's to run                                           |
| Inside the container (`/.dockerenv`: herdr pane, `ssh devbox`) | nothing - every command refuses                                                                                     | none, by design: the sandbox does not drive its own host. Give the user the exact command instead |

`install` and `completions` run on either machine.

- **The workstation alias is per-laptop and never in the repo.** Resolve it as `devbox deploy` does: `$DEVBOX_HOST`,
  else `DEVBOX_HOST=` in `.push.env` at the repo root (gitignored). Neither set: ask - never guess a hostname. The
  remote checkout is `$DEVBOX_REMOTE_PATH`, default `~/devbox`.
- **Over `ssh`, call `./bin/devbox`, not `devbox`.** A non-interactive `ssh` has no `~/.local/bin` on its PATH, so the
  bare name is missing there even when `install` succeeded.
- **`sync` talks to the container, not the workstation:** its host is `$DEVBOX_SSH_HOST` / `.push.env`, then `devbox`.
- A side-guard refusal (`This is a workstation command: ...`, `This is a laptop command: ...`) means re-route, not
  work around: the guard is what keeps a laptop `up` from driving the wrong Docker daemon.
- Every `ssh`/`rsync` from the laptop authenticates through the 1Password SSH agent. A hang or `Permission denied
(publickey)` is usually 1Password locked or awaiting approval - tell the user, don't retry in a loop.

## 2. Command map by intent

| Intent                                         | Command                            | Side        | Effect on live sessions / who may run it                            |
| ---------------------------------------------- | ---------------------------------- | ----------- | ------------------------------------------------------------------- |
| Is everything healthy                          | `doctor` (`host`/`laptop` implied) | either      | read-only                                                           |
| Who is connected; why did a session drop       | `sessions`                         | workstation | read-only                                                           |
| Why did the container fail to start            | `logs` (last 100 lines)            | workstation | read-only - never `--follow`/`-f` from an agent: it does not return |
| Which identity keys are installed              | `keys`                             | workstation | read-only                                                           |
| Re-apply in-container user setup               | `bootstrap`                        | workstation | pane-safe (`docker compose exec`)                                   |
| Restart / upgrade `moshi-hook`                 | `hook`, `hook --update`            | workstation | pane-safe                                                           |
| Install optional agent skills + agent-browser  | `skills`                           | workstation | pane-safe; ~180 MB on first run                                     |
| Create or resync `.env` (`BIND_ADDR`, uid/gid) | `env`                              | workstation | edits `.env` only; never clobbers it                                |
| Build and start / apply a repo change          | `up`                               | workstation | kills sessions **if** compose recreates; a no-op `up` never asks    |
| Cache-free image                               | `rebuild`                          | workstation | always recreates - kills sessions                                   |
| Stop the devbox                                | `down`                             | workstation | kills sessions and takes the box offline - only on explicit request |
| Ship the working tree                          | `deploy [HOST] [--up]`             | laptop      | `rsync --delete` mirror of uncommitted state too; `--up` as `up`    |
| Push the laptop's OMP preset                   | `sync omp`                         | laptop      | replaces the devbox's whole `config.yml` (one `.bak` kept)          |
| Push the identity registry                     | `sync identities`                  | laptop      | validates locally, copies, re-runs bootstrap there                  |
| Laptop agent git override                      | `agent install`                    | laptop      | idempotent; prints the manual steps left                            |
| `devbox` on the PATH with completion           | `install`                          | either      | idempotent; refuses to replace a real `~/.local/bin/devbox`         |
| Provision the rootless project daemon          | `docker setup [--check]`           | workstation | `sudo`, so hand to the user; `--check` only reports what is missing |
| A shell in the container                       | `shell`                            | workstation | interactive - from an agent use `ssh devbox '<cmd>'` instead        |

## 3. Guards an agent must leave in place

**Live sessions.** `up` (when it recreates), `rebuild` and `down` count established SSH connections first. With a
terminal they prompt; without one - every agent tool call, and `deploy --up`'s `ssh -t` from a TTY-less caller - they
stop with `[ERROR] Refusing to continue with live sessions - re-run with --force.` That refusal is the correct outcome,
not an obstacle. Those sessions are the user's herdr panes, often agents mid-task, and a recreate drops them with no
client-side message. So: run `sessions`, report how many are connected and what the pending step is, and let the user
choose. Add `--force` only after an explicit go-ahead that names the cost.

**Interactive prompts an agent cannot answer.** `sudo` (`docker setup`, `docker setup --check`) wants a password over a
TTY. Hand the user the exact line, e.g. `ssh -t <workstation> 'cd ~/devbox && sudo ./bin/devbox docker setup --check'`,
and pick up from its output.

**Flags that remove a safeguard.** `sync omp --allow-unguarded` ships a config without the `bash:` guardrail block
bootstrap seeded; `deploy` ships uncommitted edits and deletes remote files absent locally. Both need the user's say-so
when the consequence is not what they asked for.

## 4. Reading results

- **Exit status is the verdict.** Every command exits non-zero on failure; `[ERROR]` lines exit 1 on the spot.
- `[INFO]`/`[OK]` go to stdout, `[WARN]`/`[ERROR]` to stderr - capture with `2>&1` or a failure looks silent. Colour
  escapes are always emitted (no TTY detection); read past them.
- `doctor` runs every check, prints each failed one as `[WARN]`, then ends with `[ERROR] N check(s) failed.` or
  `[OK] All checks passed.` Report the named failures, not just the count. The registry check failing on either side
  skips everything identity-derived - fix it first (`devbox-identities check` prints why).
- Common one-line failures: `Missing .../.env` -> `./bin/devbox env`; `BIND_ADDR is X but Tailscale reports Y` -> `env`
  then `up`; `bash version 4.2 or higher is required` on macOS -> `brew install bash`; missing `rsync` -> the remedy the
  error prints. Anything else: the FAQ at the end of `docs/cli.md` and `docs/operations.md`.
- Completion misbehaving: `./bin/devbox __complete <words...> ""` prints the raw candidates.

## 5. Changing the CLI itself

`bin/devbox` is generated - never edit it. The sources:

| Change                                       | Edit                                                                    |
| -------------------------------------------- | ----------------------------------------------------------------------- |
| A command, flag, arg, help, side, dependency | `cli/bashly.yml`                                                        |
| A command body                               | `cli/commands/<name>.sh` (nested: `cli/commands/sync/omp.sh`)           |
| Shared code                                  | `cli/lib/` (`compose.sh` session guard, `machine.sh` side filters, ...) |
| Constants every command sees                 | `cli/initialize.sh`                                                     |

- Every new command declares its side in `filters:` - `[host]`, `[laptop]` or `[machine]` (either, never the
  container) - and its `group:`.
- Read a flag with an inner dash through a quoted key: `${args['--allow-unguarded']}`. shfmt rewrites an unquoted one
  into arithmetic, a key bashly never sets; `make lint` catches it.
- Log with `log_info`/`log_success`/`log_warn`/`log_error`; a check-style command counts with `fail` and ends with
  `finish_checks`, as the doctors do.
- A destructive workstation command calls `guard_ssh_sessions '<action>'` and takes the shared `--force` flag.
- Then, on the laptop (the workstation has no Ruby/bashly): `make build`, `make check`, and commit `cli/` and
  `bin/devbox` together. Smoke-run the command on its side (`--help` first), then `deploy` to make it live there.
- Update `docs/cli.md`, the `AGENTS.md` CLI bullet and this skill in the same change.
