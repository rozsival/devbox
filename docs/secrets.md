# 🔐 Secrets

> Nothing secret is baked into the image, fetched by `bootstrap`, or committed to this repo. The container holds **no
> 1Password or Google account** — `op` isn't installed. Secrets are rendered on the laptop, where approving access is
> yours, and copied in.

**Related:** [Git Identities](git.md) · [Security Model](security.md) · [Installation](installation.md)

---

## 🗂️ Overview

> [!WARNING]
> A deliberate reduction of authority, not an oversight — the container isolates the host filesystem and contains
> credentials; it's **not** a confidentiality boundary. Assume anything inside can leave; put nothing in not worth its
> blast radius. See [Security Model](security.md).

### Layers

| Layer                  | Holds                                    | Scope of a leak                                    |
| ---------------------- | ---------------------------------------- | -------------------------------------------------- |
| Identity (public keys) | `~/.ssh/id_<slug>.pub`, one per identity | none alone — selects the forwarded key GitHub sees |
| Box-wide tools         | `secrets.env`, agent logins, App keys    | every agent on the box                             |
| Per project            | that project's `.env`                    | one project                                        |

### Where each secret lives

Everything is on the `/home/dev` bind mount, so it survives rebuilds and is set up once per host.

| Secret                                 | Lives in                                                             | Set up by                                                                   |
| -------------------------------------- | -------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| SSH public keys, one pair per identity | `~/.ssh/id_*.pub` (authentication), `~/.ssh/signing_*.pub` (signing) | `bootstrap`, from `identities.conf` — no private key present                |
| `gh` tokens, one per identity          | `~/.config/devbox/secrets.env`                                       | you, a fine-grained PAT each ([below](#-github-cli))                        |
| OMP login                              | `~/.omp/agent/agent.db`                                              | you, once, `/login` in `omp` ([below](#omp))                                |
| Claude Code login                      | `~/.claude/.credentials.json`                                        | you, once, `/login` in `claude` ([below](#claude-code))                     |
| Model API keys (optional)              | `~/.config/devbox/secrets.env`                                       | you, only for providers you use by key                                      |
| GitHub App credentials (optional)      | the directory the identity's `app` field names                       | you, `app-id` + `app.pem` at mode 600 ([Git](git.md#devbox-git-credential)) |
| Per-project secrets                    | `<project>/.env`                                                     | you, rendered on the laptop ([below](#-per-project-secrets))                |
| GCP service-account key                | `~/.config/gcloud/<gcp-project>-*.json`                              | you, one per project, mode 600 ([below](#provisioning-a-key))               |

---

## ✅ Manual checklist

Everything here needs a browser or a secret, so none of it is automated. `bootstrap` prints the steps still open, except
the OMP login.

| #   | Step                         | Details                                                                                                      |
| --- | ---------------------------- | ------------------------------------------------------------------------------------------------------------ |
| 1   | Set identity public keys     | `pubkey` and `signing_pubkey` per identity in `identities.conf` — see [Git Identities](git.md#-signing)      |
| 2   | Fill `secrets.env`           | A `GH_TOKEN_<SLUG>` per identity ([permissions](#permissions-per-token)); model API keys only if you use any |
| 3   | Place GitHub App credentials | If an identity has an `app` field: `app-id` and `app.pem` (mode 600) in that directory                       |
| 4   | Log the agents in            | `/login` once in `omp` and once in `claude` — see [Agent logins](#-agent-logins)                             |

---

## 🔑 `secrets.env`

### What it holds

`~/.config/devbox/secrets.env` holds plain `KEY=value` pairs at mode 600: one GitHub token per identity, plus any model
API key you choose to use. `bootstrap` installs it from `home/.config/devbox/secrets.env.example` if absent and never
overwrites it.

```dotenv
GH_TOKEN_PERSONAL=github_pat_...
GH_TOKEN_WORK=github_pat_...
```

> [!IMPORTANT]
> Only credentials **every** project shares belong here — a per-project secret here reaches every agent on every other
> project, defeating the layering.

### How it is loaded

On the devbox, `~/.bashrc.d/devbox.sh` sources it under `set -a` in every shell, interactive or not — agents arrive as
`ssh devbox <cmd>`. It then unsets every `GH_TOKEN_<SLUG>`: only `devbox-gh-token` needs them, and it reads them from the
file by name, so a dev server or an install script never inherits every account's PAT. Other keys stay exported.

On the laptop, `./bin/devbox agent install` creates the same file, but no shell sources it: only `devbox-gh-token` and
`devbox-git-credential` read it, in agent sessions. Your own `gh` keeps its OAuth login.

Neither copy travels: `devbox sync` carries `identities.conf` and the agent presets, never secrets.

---

## 🐙 GitHub CLI

### One token per identity

Each identity in `identities.conf` gets its own fine-grained token, `GH_TOKEN_<SLUG>` (the slug upper-cased;
`devbox-identities get <slug> token_var`). The working directory picks which one, by the same `dir` rule that picks a
git identity:

| Working directory    | Variable            | Identity           |
| -------------------- | ------------------- | ------------------ |
| everywhere else      | `GH_TOKEN_PERSONAL` | personal (default) |
| `~/projects/work/**` | `GH_TOKEN_WORK`     | work               |

```bash
cd ~/projects/work/<repo>
devbox-gh-token --account     # work
gh repo view --json nameWithOwner
```

### How a token is resolved

`~/.local/libexec/devbox-agent/gh` is a shim ahead of the real `gh` on the PATH. It asks `devbox-gh-token` for a token
on every call and exports it for that call only; nothing exports `GH_TOKEN` at shell startup. Resolving per call is what
lets the account follow the tree: an agent's session opens in `$HOME` and only later works in a project.

`devbox-gh-token` takes the first of:

| Order | Source                                                                                 |
| ----- | -------------------------------------------------------------------------------------- |
| 1     | an explicit `GH_TOKEN` in the environment — even empty, which means "no token"         |
| 2     | the identity's variable in the environment, set for one command                        |
| 3     | the same variable read directly from `secrets.env` — so a new token needs no reconnect |

A missing token is an error, never a fallback to another identity's: `devbox-gh-token` exits non-zero naming the unset
variable, and `gh` runs unauthenticated. `devbox-gh-token --identity <slug>` returns one identity's token regardless of
directory or an inherited `GH_TOKEN`; `bootstrap` and `devbox doctor laptop` use it to check every token.

### Enterprise hosts

For an identity on a GitHub Enterprise Server `host`, the shim exports `GH_ENTERPRISE_TOKEN` instead of `GH_TOKEN` —
the only variable gh reads for such a host, and one it never sends to `github.com`. It also exports `GH_HOST=<host>`
when `GH_HOST` is unset, since gh refuses a host it has no login for. `devbox-identities get <slug> gh_env` names the
variable.

### Agent sessions use the App

In an agent session (`GIT_CONFIG_GLOBAL` points at `agent.gitconfig`, which only the `omp`/`claude` launchers set), a
command about **one repository** uses that repository's App installation token from
`devbox-git-credential token <owner>/<repo>` — the same token agent git pushes with, so PRs and comments carry the bot
author like the commits do.

| Uses the App token (when installed on the repo)                             | Keeps the PAT                                                |
| --------------------------------------------------------------------------- | ------------------------------------------------------------ |
| `pr`, `issue`, `run`, `workflow`, `release`, `label`, `cache`, `ruleset`    | `repo`, `search`, `api user` — anything naming no repository |
| `gh api repos/<owner>/<repo>/...`, and `gh api graphql` inside a repository | repositories without the App                                 |
| `project` with `--owner` naming the checkout's owner                        | `project` with `--owner @me`, another owner, or none         |
|                                                                             | every `gh` outside an agent session                          |

The repository comes from `-R`/`--repo`, then `GH_REPO`, then the `origin` remote; for `project` it is always the
checkout, since a project belongs to an owner rather than a repository. An agent that needs the PAT inside a repository
asks for it explicitly: `GH_TOKEN=$(devbox-gh-token) gh ...`.

> [!CAUTION]
> A failed App lookup or mint (broken `app.pem`, API outage) makes `gh` exit 1 rather than fall back to the PAT and act
> as someone else. Failures are never cached; successful tokens are, for up to 30 minutes
> ([Git Identities](git.md#devbox-git-credential)).

### Permissions per token

Where a permission has to live follows which token answers. With your own account's repos having no App and an org's
repos having the org's App, that gives three sets. A fine-grained PAT has exactly one resource owner, so the org's PAT
is a separate token on its own identity ([Git Identities](git.md#can-two-identities-be-the-same-github-account)). All
are _Repository permissions_ unless marked; `Metadata: read` is mandatory and added by GitHub.

#### PAT on your account's repos (no App)

The PAT does all agent work here: git through the credential helper and every `gh` command.

| Permission      | Level               | For                                                                                                   |
| --------------- | ------------------- | ----------------------------------------------------------------------------------------------------- |
| Contents        | **write**           | agent clone, pull and push; `gh pr merge`                                                             |
| Pull requests   | **write**           | `gh pr create`, `gh pr comment`, `gh pr review` — **read** if agents should not post                  |
| Issues          | **write**           | `gh issue create`, `gh issue comment` — **read** if agents should not post                            |
| Actions         | **write**           | `gh run rerun`, `gh run cancel`, `gh workflow run` — **read** covers only `gh run list/view/watch`    |
| Commit statuses | read                | `gh pr checks`                                                                                        |
| Workflows       | **write**, optional | pushes that change `.github/workflows/` — without it GitHub rejects them, and you push those yourself |

There is no _Checks_ row: fine-grained PATs
[cannot call the Checks API](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens#fine-grained-personal-access-tokens-limitations)
at all, so with a PAT `gh pr checks` relies on commit statuses and may not show check runs. Nor is there a _Projects_
row: a fine-grained PAT cannot reach a project owned by a user account either — only a classic PAT can, which this setup
does not use. Put a board agents should work under an org.

#### PAT on an org's repos (org App installed)

Agents only use this token for commands that name no repository, plus the `gh` you type yourself in a devbox pane.

| Permission                     | Level    | For                                                                                                                 |
| ------------------------------ | -------- | ------------------------------------------------------------------------------------------------------------------- |
| Metadata                       | read     | `gh repo list`, `gh search repos`, `gh repo view` — the minimum agents need from this token                         |
| Contents                       | read     | `gh repo view`'s README, `gh search code`                                                                           |
| Issues, Pull requests          | read     | `gh search issues`, `gh search prs` across the org, if agents search                                                |
| Optional, from the first table | as there | only for `gh` you run by hand on the devbox — Actions **write** if you re-run CI there with `gh run rerun` yourself |
| Projects (_organization_)      | read     | optional — your own `gh project` in a devbox pane; agents' go to the App                                            |

An org repo _without_ the App falls back to this PAT for everything, so it needs the first table. The org must allow
fine-grained PATs (org settings → _Personal access tokens_); if it requires approval, a new token stays pending until an
owner approves it.

#### The org's App

Set under the App's settings → _Permissions & events_. Each token is minted for one repository with the installation's
whole permission set, so this table is exactly what an agent can do there.

| Permission                | Level               | For                                                                                                   |
| ------------------------- | ------------------- | ----------------------------------------------------------------------------------------------------- |
| Contents                  | **write**           | agent clone, pull and push; `gh pr merge`                                                             |
| Pull requests             | **write**           | `gh pr create`, `gh pr comment`, `gh pr review` — the bot authors them                                |
| Issues                    | **write**           | `gh issue create`, `gh issue comment`                                                                 |
| Actions                   | **write**           | `gh run rerun`, `gh run cancel`, `gh workflow run` — **read** covers only `gh run list/view/watch`    |
| Checks                    | read                | `gh pr checks`                                                                                        |
| Commit statuses           | read                | `gh pr checks`                                                                                        |
| Workflows                 | **write**, optional | pushes that change `.github/workflows/` — without it GitHub rejects them, and you push those yourself |
| Projects (_organization_) | **write**, optional | `gh project item-add`, `item-edit`, …; `gh pr create --project`, `gh issue edit --add-project`        |

An App installed on your own account works the same way: its repos follow this table, and that account's PAT shrinks to
the second one.

#### Changing App permissions

> [!IMPORTANT]
> A permission change is only a request: the installation keeps the old set until an org owner accepts it (org settings
> → _GitHub Apps_ → the App → _Review request_). A token minted before that keeps the old permissions for up to 30
> minutes — delete `devbox-agent-<uid>/` (under `$XDG_RUNTIME_DIR`, else `/dev/shm`, else `$TMPDIR`) to mint a fresh
> one.

### Why not `gh auth login`

- **Scope:** its web flow can't ask for less than `repo`, `read:org`, `gist` (`--scopes` only adds) — read **and
  write** on every repo the account reaches, with no expiry. A fine-grained PAT names its repos and expires.
- **One active account:** `gh auth switch` changes a global setting in `~/.config/gh`, which two agents in two orgs
  would race, and any `GH_TOKEN` in the environment makes stored accounts inert anyway.
- **No keyring:** the container would store the login in plaintext, like `secrets.env` — not the deciding factor, but no
  better either.

---

## 🤖 Agent logins

Both agents log in with a subscription, not an API key. Each login lives on the bind mount, survives rebuilds, and is
readable by any agent on the box — the same blast radius as `secrets.env`. If the box is compromised, revoke it at the
provider and log in again.

### OMP

Run `omp` in a pane and `/login` (or `omp login <provider>` from a shell) and follow the provider's prompts. The
credentials land in `~/.omp/agent/agent.db`. OMP needs no API key in `secrets.env`; add one
only for a provider you deliberately use by key.

Already logged in on the laptop? Copy that login over instead: `omp auth export | ssh devbox omp auth import -`. It
carries every credential the laptop's OMP holds, API keys included, so the devbox then holds all of them.

### Claude Code

Run `claude` in a pane and `/login`, the same way. The credentials land in `~/.claude/.credentials.json`; `bootstrap`
lists the login as outstanding until that file exists.

`claude-launcher` unsets `ANTHROPIC_API_KEY` for Claude's process tree: Claude would otherwise bill such a key instead
of the subscription. A `claude` started by absolute path, bypassing the launcher, would see it.

---

## 🧾 Agent git credentials

Agent `git` doesn't use `gh`'s path: the launchers' `agent.gitconfig` hands every HTTPS request to
`devbox-git-credential`, which answers with the App token where the App is installed and the identity's PAT otherwise.
The mechanism is in [Git Identities](git.md#-agent-sessions); the secrets it reads are the ones above — `GH_TOKEN_<SLUG>`
from `secrets.env` and each identity's `app-id`/`app.pem` — on the laptop as well as the devbox.

---

## 📁 Per-project secrets

### Rendering `.env` on the laptop

A project's `.env` looks exactly as on the laptop — same variable names, nothing devbox-specific. Commit a template of
1Password references and render it locally:

```bash
# <project>/.env.tpl, committed
DATABASE_URL=op://Dev/project-db/url
STRIPE_SECRET_KEY=op://Dev/project-stripe/credential
```

```bash
op inject -i .env.tpl -o .env                       # on the laptop, with your approval
scp .env devbox:projects/<project>/.env             # into the box
ssh devbox 'chmod 600 projects/<project>/.env'
```

1Password stays the source of truth, the rendered file is never committed, and the container never authenticates to a
vault. Rotation is one re-render and one copy. Values that differ because the box is another machine (`localhost`
ports, callback URLs) belong in the project's own override convention.

### Projects that call `op` themselves

A script wrapped in `op run --` or `op inject` fails in the container: there is no `op`. Render the `.env` on the laptop
and run the command directly.

---

## ☁️ Google Cloud (ADC)

### Use a service account, never your login

For a project that needs Google APIs, use a **dedicated service account in that project's GCP project**.
`gcloud auth application-default login` would write a never-expiring refresh token for **your** Google account, with
`cloud-platform` scope over every project you reach — the largest credential you could put in a box built for
unattended agents.

### How ADC resolves

First hit wins:

| Order | Source                                                  | Note                                          |
| ----- | ------------------------------------------------------- | --------------------------------------------- |
| 1     | `GOOGLE_APPLICATION_CREDENTIALS`                        | path to a JSON key or external-account config |
| 2     | `~/.config/gcloud/application_default_credentials.json` | the well-known user file                      |
| 3     | the GCE/GKE/Cloud Run metadata server                   | absent in this container                      |

Pointing step 1 at a scoped key keeps your identity out of the box. No step reads `gcloud config`.

> [!CAUTION]
> Never write a service-account key to `application_default_credentials.json` — that's ADC step 2, becoming a silent
> box-wide default any project picks up when its variable is missing. Leaving step 2 empty makes a misconfigured project
> fail loudly, not quietly bill the wrong project.

### Provisioning a key

On the laptop (the image has no `gcloud`), once per project:

```bash
PROJECT=<gcp-project-id>
gcloud iam service-accounts create devbox-dev \
  --project "$PROJECT" --display-name 'devbox agent sandbox'

# one binding per API the app needs; never roles/editor. For LLM calls a custom
# role limited to aiplatform.endpoints.predict blocks training and deployment,
# which are the expensive operations.
gcloud projects add-iam-policy-binding "$PROJECT" \
  --member "serviceAccount:devbox-dev@${PROJECT}.iam.gserviceaccount.com" \
  --role <least-privilege-role>

gcloud iam service-accounts keys create devbox-dev.json \
  --iam-account "devbox-dev@${PROJECT}.iam.gserviceaccount.com"
```

Store the key in 1Password, copy it to `~/.config/gcloud/<gcp-project>-devbox.json` at mode 600, delete the local copy,
and reference it from **that project's** `.env`:

```dotenv
GOOGLE_APPLICATION_CREDENTIALS=/home/dev/.config/gcloud/<gcp-project>-devbox.json
GOOGLE_CLOUD_PROJECT=<gcp-project-id>
GOOGLE_CLOUD_LOCATION=<region>
```

`GOOGLE_CLOUD_PROJECT` is required: with a key file, nothing infers the project. Rotation is `keys create` then
`keys delete <old-key-id>`.

### Containing spend

An inference key's blast radius is **cost**. Contain it with a billing budget with alerts plus Vertex per-model quotas:
budgets notify, quotas cap — the one that matters for an unattended overnight run. Denying `gcloud` or `op` to an agent
contains nothing; any script can read the key and call the SDK. The boundary is what the service account may do.

---

## ❓ FAQ

### Why is `op` not installed?

A live `op` session is reachable by any agent in that shell, so a leak would cost every vault rather than one project.
Apps read secrets in plaintext from `.env` anyway, so removing `op` loses nothing at rest.

### Don't I need `op` for signing?

No. Manual signing (`ssh -A devbox`) uses the laptop's forwarded 1Password _SSH agent_, not the `op` CLI, and agent
sessions don't sign at all. See [Git Identities](git.md#-signing).

### Why does `.env` on the host hold no secrets?

It holds addressing and host-user mapping only (`BIND_ADDR`, `HOST_UID`/`HOST_GID`, `DEVBOX_GITHUB_USER`). Identities
live in `~/.config/devbox/identities.conf`; see [Git Identities](git.md#-the-identity-registry).

### What if `bootstrap` says my `secrets.env` still holds `op://` references?

It's a file from an older `op run` layout, now sourced directly and exporting `op://…` into every shell. Replace those
lines with plain values rendered on the laptop. A leftover per-account secrets file reports the same way and can be
deleted.

### I already had a single box-wide `GH_TOKEN`. What now?

It still works but overrides every per-identity variable, so nothing is chosen per tree; `bootstrap` warns about it.
Rename it to your default identity's `GH_TOKEN_<SLUG>` and add one per other identity.

### `echo $GH_TOKEN` is empty — is `gh` broken?

No. Nothing exports it; the shim resolves a token per call. Check with `devbox-gh-token --account` and `gh auth status`;
for a `curl` or script of your own, use `GH_TOKEN=$(devbox-gh-token)`.

### What does `devbox-gh-token: GH_TOKEN_WORK is unset` mean?

You're in the `work` identity's tree and only the default identity's token is set. There's deliberately no fallback —
the default token on a `work` repo is the wrong identity. Add the variable.

### How do I add another account?

Add a `[slug]` block to `identities.conf`, its `GH_TOKEN_<SLUG>` here, and its two public keys — no code change. See
[Git Identities](git.md#-the-identity-registry).

### Why does `gh run rerun` fail in an agent session but work in my shell?

In an agent session, `gh run` on a repository with the org's App uses the App's token, so the **App** needs
`Actions: write`; your shell sends the PAT. Grant it on the App, have an org owner accept the request, then wait for or
delete the cached token — see [Changing App permissions](#changing-app-permissions).

### Does OMP see my keys in plaintext?

`~/.omp/agent/config.yml` sets `secrets: { enabled: true }`, which obfuscates environment secrets before they reach a
provider. The Claude Code preset has no such setting.

### How do I rotate a leaked key?

Revoke it at the source — GitHub's token settings for a PAT, a new `app.pem` from the App's settings, `gcloud iam
service-accounts keys delete` for GCP, the provider's account page for an agent login — then update `secrets.env`, the
`app` directory or the project `.env`. There's no SSH keypair to rotate: identity is your laptop's key.

### Are secrets visible to the workstation's host user?

Yes. The bind mount is owned by `HOST_UID`. The container protects the host from the agent, not the agent's files from
the owner — workstation disk encryption is part of this model.

### What happens to secrets on `./bin/devbox rebuild`?

Nothing — they're in `/home/dev` on the host, not the image.
