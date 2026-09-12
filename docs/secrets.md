# 🔐 Secrets

Nothing secret is baked into the image, fetched by `bootstrap`, or committed to this repo. Secrets arrive
through one of three paths: an interactive `op` session, a long-lived credential written once into the bind
mount, or a file you place by hand.

| Secret                      | Lives in                                  | Established by                           |
|-----------------------------|-------------------------------------------|------------------------------------------|
| `gh` tokens (per account)   | `~/.config/gh`                            | `gh auth login` (browser, once)          |
| 1Password session           | `op` agent state, expires ~30 min         | `op account add` + `eval "$(op signin)"` |
| API keys for agents         | `~/.config/devbox/secrets.env`            | you, as `op://` references               |
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
3. `op account add --address my.1password.com --email <email>`, then `eval "$(op signin)"` per shell.
4. Fill `~/.config/devbox/secrets.env` with `op://` references and run commands as `devenv <cmd>`.
5. Place the work-app GitHub App credentials in `~/.config/work/work-app/`
   (`app-id`, `app.pem` at mode 600) if you need them.

## `devenv` and `secrets.env`

`~/.config/devbox/secrets.env` holds references, never values:

```dotenv
ANTHROPIC_API_KEY=op://Private/anthropic/credential
OPENAI_API_KEY=op://Private/openai/credential
```

`devenv` (a function from `~/.bashrc.d/devbox.sh`) resolves them at call time:

```bash
devenv omp                # op run --env-file=~/.config/devbox/secrets.env -- omp
devenv pnpm test
```

The file is copied from `home/.config/devbox/secrets.env.example` if absent and never overwritten. Values
resolve only while an `op` session is active.

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
The `op` session expired. `eval "$(op signin)"` in that shell, or move the credential to a long-lived token.

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
