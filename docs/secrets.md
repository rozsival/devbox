# 🔐 Secrets

Nothing secret is baked into the image, fetched by `bootstrap`, or committed to this repo. Secrets arrive
through one of three paths: an interactive `op` session, a long-lived credential written once into the bind
mount, or a file you place by hand.

| Secret                      | Lives in                                  | Established by                           |
|-----------------------------|-------------------------------------------|------------------------------------------|
| `gh` tokens (per account)   | `~/.config/gh`                            | `gh auth login` (browser, once)          |
| 1Password sessions (two)    | `op` agent state, expire ~30 min          | `op account add` + `op signin --account` |
| API keys for agents         | `secrets.env`, `secrets.work.env`      | you, as `op://` references               |
| GitHub App (work-app) | `~/.config/work/work-app/`       | you, `app-id` + `app.pem` at mode 600    |
| SSH keys (both identities)  | `~/.ssh/id_personal`, `~/.ssh/id_work` | `bootstrap`, passphrase-less             |

All of these are on the `/home/dev` bind mount, so they survive container and image rebuilds and are
established once per host.

## Manual checklist

`bootstrap` prints exactly what is left; nothing below is ever automated, because all of it needs a browser
or a secret.

1. Add both keys from `./bin/devbox keys` to GitHub **twice each** - once as an Authentication key, once as a
   Signing key. See [Git identities](git.md#github-registration).
2. `gh auth login --hostname github.com --git-protocol ssh --web` inside the devbox (repeat per account,
   switch with `gh auth switch`). The token persists in `~/.config/gh` on the bind mount.
3. Add **both** 1Password accounts, each under its own shorthand, then sign in to the one you need:
   `op account add --address <OP_PERSONAL_ADDRESS> --email <OP_PERSONAL_EMAIL> --shorthand personal`
   `op account add --address <OP_WORK_ADDRESS> --email <OP_WORK_EMAIL> --shorthand work`
   `eval "$(op signin --account personal)"` per shell (sessions are per account).
4. Fill `~/.config/devbox/secrets.env` (personal) and `secrets.work.env` (work) with `op://`
   references, then run commands as `devenv <cmd>` or `OP_ACCOUNT=work devenv <cmd>`.
5. Place the work-app GitHub App credentials in `~/.config/work/work-app/`
   (`app-id`, `app.pem` at mode 600) if you need them.

## Two accounts

`op` holds both the personal and the work account, distinguished by the shorthands `personal` and
`work`. Selection follows `op`'s own precedence: the `--account` flag, then `OP_ACCOUNT`, then the most
recent `op signin`. Relying on "most recent" with two accounts added is how you get
`could not resolve item` on a reference that exists - always be explicit:

```bash
eval "$(op signin --account work)"        # session for one account
op --account work item list               # one-off read
op account list                              # shorthands currently added
```

`.env` on the workstation carries `OP_PERSONAL_ADDRESS`/`_EMAIL` and `OP_WORK_ADDRESS`/`_EMAIL`. They are
hints only: `bootstrap` interpolates them into the printed `op account add` commands and never runs them,
because the Secret Key and master password are interactive by design. Clear an email to drop that account
from the checklist.

## `devenv` and the secrets files

Each account gets its own env file, because `op run` resolves references against a single account per call:

| Account    | File                                   | Command                        |
|------------|----------------------------------------|--------------------------------|
| `personal` | `~/.config/devbox/secrets.env`         | `devenv <cmd>`                 |
| `work`  | `~/.config/devbox/secrets.work.env` | `OP_ACCOUNT=work devenv …`  |

Both hold references, never values:

```dotenv
ANTHROPIC_API_KEY=op://Private/anthropic/credential
OPENAI_API_KEY=op://Private/openai/credential
```

`devenv` (a function from `~/.bashrc.d/devbox.sh`) picks the account from `OP_ACCOUNT` (default `personal`),
maps it to the matching file, and resolves at call time:

```bash
devenv omp                        # op run --account personal --env-file=…/secrets.env -- omp
OP_ACCOUNT=work devenv pnpm test
```

Both files are copied from `home/.config/devbox/secrets.env.example` if absent and never overwritten. Values
resolve only while a session for **that** account is active.

## 1Password stays interactive

`op` sessions expire after roughly 30 minutes idle, so an unattended agent cannot re-authenticate. Anything an
agent needs unattended must be a long-lived credential written once into the devbox - the `gh` token in
`~/.config/gh`, a token in `~/.terraformrc` - rather than fetched per run through `op`.

The escape hatch, if that becomes limiting: a 1Password service-account token plus a dedicated shared vault.
That is not wired up - it would need `OP_SERVICE_ACCOUNT_TOKEN` added to `.env.example` and passed through the
compose `environment:` block - and service accounts cannot read Private vaults, so it is a vault migration
rather than a flag flip. No other part of the design changes.

## ❓ FAQ

**Why does `.env` on the host hold no secrets?**
By design - it holds addressing and identity configuration only (`BIND_ADDR`, UID/GID, emails). It is
gitignored and excluded from `bin/push`, but it is not a secret store.

**Can I put a raw API key in `secrets.env`?**
It would work - `op run` passes through plain values - but then the secret sits in cleartext on the bind
mount. Prefer an `op://` reference, or the tool's own credential store.

**My agent run failed with an unresolved `op://` reference.**
Either the session for that account expired - `eval "$(op signin --account <shorthand>)"` in that shell - or
the reference lives in the other account. Sessions and references are per account: a personal vault item is
unresolvable while `OP_ACCOUNT=work` is in effect. Move the credential to a long-lived token if an
unattended agent needs it.

**Can one `devenv` call mix personal and work secrets?**
No. `op run` authenticates as one account per invocation, which is why there are two env files. If a single
command genuinely needs both, copy the item into one account's vault (or a shared vault) and reference it
from that account's file.

**Does OMP see my keys in plaintext?**
`~/.omp/agent/config.yml` sets `secrets: { enabled: true }`, which obfuscates environment secrets before they
can reach a provider. Keep that setting if you inject keys with `devenv`.

**How do I rotate a leaked key?**
Revoke it on GitHub (`gh ssh-key delete`) or in 1Password, then `./bin/devbox bootstrap` regenerates only what
is missing - delete the old key file first if you want a fresh pair, and re-register it.

**Are secrets visible to the workstation's host user?**
Yes. The bind mount is owned by `HOST_UID` and the host user can read it. The container protects the host from
the agent, not the agent's files from the host owner.

**What happens to secrets on `./bin/devbox rebuild`?**
Nothing - they are in `/home/dev` on the host, not in the image.
