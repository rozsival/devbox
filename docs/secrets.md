# 🔐 Secrets

Nothing secret is baked into the image, fetched by `bootstrap`, or committed to this repo. The container
holds **no 1Password or Google account** - `op` isn't installed. Secrets are rendered on the laptop, where
approving access is yours, and copied in.

A deliberate reduction of authority, not an oversight - the container isolates the host filesystem and
contains credentials; it's **not** a confidentiality boundary. Assume anything inside can leave; put nothing
in not worth its blast radius. See [Security](security.md).

## Three layers

| Layer                  | Holds                                             | Scope of a leak                                          |
|------------------------|-----------------------------------------------------|--------------------------------------------------------------|
| Identity (public keys) | `~/.ssh/id_<slug>.pub`, one per identity            | none alone - selects the forwarded key GitHub sees |
| Box-wide tools         | `~/.config/devbox/secrets.env`                    | the tools' credentials                                   |
| Per project            | that project's `.env`                             | one project                                              |

Everything lives on the `/home/dev` bind mount, so it survives container/image rebuilds, established once
per host.

| Secret                                        | Lives in                                                             | Established by                                                                                                           |
|-------------------------------------------------|------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------|
| SSH identity public keys (one pair per identity) | `~/.ssh/id_*.pub` (authentication), `~/.ssh/signing_*.pub` (signing) | `bootstrap`, from `pubkey`/`signing_pubkey` in `~/.config/devbox/identities.conf` - no private key present       |
| `gh` tokens, one per identity                    | `~/.config/devbox/secrets.env`                                       | you, one fine-grained GitHub PAT per identity                                                                            |
| Model API keys for OMP                           | `~/.config/devbox/secrets.env`                                       | you, plain values                                                                                                        |
| GitHub App credentials (per identity, optional)  | the directory that identity's `app` field names                      | you, `app-id` + `app.pem` at mode 600 ([Git identities](git.md#devbox-git-credential))                                  |
| Per-project secrets                              | `<project>/.env`                                                     | you, rendered on the laptop                                                                                              |
| GCP service-account key                          | `~/.config/gcloud/<gcp-project>-*.json`                              | you, one per project, mode 600                                                                                           |

## Manual checklist

`bootstrap` prints exactly what's left; nothing below is automated, since it all needs a browser or a secret.

1. Set each identity's `pubkey` (authentication) and `signing_pubkey` (signing) in
   `~/.config/devbox/identities.conf` to the laptop's public keys, already on GitHub - the devbox registers
   nothing. See [Git identities](git.md#signing).
2. Fill `~/.config/devbox/secrets.env` with a `GH_TOKEN_<SLUG>` per identity, and model API keys -
   fine-grained, scoped as below (see [`gh`](#gh)). `gh` picks tokens up immediately; reconnect so model
   keys reach open shells.
3. Place any identity's GitHub App credentials in the directory its `app` field names (`app-id`, `app.pem`
   at mode 600) if configured - see [Agent git credentials](#agent-git-credentials).

## Box-wide tool credentials

`~/.config/devbox/secrets.env` is plain `KEY=value` pairs at mode 600, installed from
`home/.config/devbox/secrets.env.example` if absent, never overwritten. `~/.bashrc.d/devbox.sh` sources it
inside `set -a`/`set +a`, **outside** the interactive guard, because agents arrive as `ssh devbox <cmd>`
(non-interactive); `container/bootstrap.sh` prepends the `~/.bashrc.d` loader ahead of Ubuntu's `~/.bashrc`
so that path reads it too.

```dotenv
GH_TOKEN_PERSONAL=github_pat_...
GH_TOKEN_WORK=github_pat_...
ANTHROPIC_API_KEY=sk-ant-...
```

Only credentials **every** project shares belong here - a per-project secret here reaches every agent on
every other project, defeating the layering.

The same file exists on the laptop once `./bin/install-agent` runs - same template, mode 600, never
overwritten - read there only by agent sessions: `devbox-gh-token` for the `gh` shim,
`devbox-git-credential`'s PAT fallback. Your shell never sources it; your `gh` keeps its OAuth login. Fill
it with every identity's `GH_TOKEN_<SLUG>` (`laptop-doctor` validates them); model keys stay the devbox's
concern.

### `gh`

**One fine-grained token per identity in `identities.conf`, chosen by the working directory** - the same
rule that picks a git identity, one mental model for both. With the example registry from
`identities.conf.example`:

| Working directory     | Variable            | Identity          |
|-------------------------|----------------------|--------------------|
| everywhere else         | `GH_TOKEN_PERSONAL` | personal (default) |
| `~/projects/work/**`   | `GH_TOKEN_WORK`      | work               |

Every identity gets its own `GH_TOKEN_<SLUG>` - `<SLUG>` is its slug upper-cased
(`devbox-identities get <slug> token_var`).

Minimum useful permissions: `contents: write` on repos agents push to without the GitHub App installed
(agent git falls back to this PAT - see [Git identities](git.md#agent-sessions)), plus `actions`/`checks`
**read**; add issues/pull-requests **write** only if agents should post.

```bash
cd ~/projects/work/<repo>
devbox-gh-token --account     # work
gh repo view --json nameWithOwner
```

#### Why a shim rather than an exported `GH_TOKEN`

`~/.local/libexec/devbox-agent/gh` is a shim ahead of the real `gh` on PATH: it calls `devbox-gh-token`,
exporting the result once. `~/.bashrc.d/devbox.sh` exports **no** `GH_TOKEN`. One set in the environment -
even empty - passes through untouched: the caller chose its principal, and empty means "no token", which is
how a launcher that starts an unattended shell keeps it from ever acting with your PAT.

An agent's directory comes late: the session opens in `$HOME`, then works a project as cwd. A token
resolved once at startup would pin the default identity for the whole session, including a second
identity's tree; resolving per invocation makes the account follow the tree.

Resolution order inside `devbox-gh-token`, first hit wins:

1. an explicit `GH_TOKEN` in the environment - a deliberate one-off, and what a pre-split `secrets.env` holds
2. the identity's variable in the environment, from a shell that sourced `secrets.env`
3. the same variable read **directly out of `secrets.env`**

Step 3 is why `gh` needs no reconnect after adding a token, and why the resolver's error is honest: the
file is the only place it looks.

Three consequences:

- `echo $GH_TOKEN` prints nothing - correct. Anything that reads the token itself (a `curl` against the API,
  a project script) should ask the resolver: `GH_TOKEN=$(devbox-gh-token)`.
- A permanent `GH_TOKEN=` line in `secrets.env` (unlike a one-off `GH_TOKEN=$OTHER gh ...`) disables
  per-directory choice; `bootstrap` warns about it.
- A missing token errors rather than falls back: `devbox-gh-token` exits non-zero naming the unset
  variable, while `gh` runs unauthenticated (`--version`/`config set` keep working) - falling back would
  pick the wrong identity.

#### Why not `gh auth login`

Its web/device flow can't ask less than `repo`, `read:org`, `gist` (`minimumScopes`, `internal/authflow`;
`--scopes` only *adds*). A classic `repo` token reads **and writes** every repo any identity can reach,
with no expiry or allowlist; a fine-grained PAT names its repos, expires, and revokes itself - broader
than what's configured here.

`gh`'s multi-account primitive - `gh auth login --with-token` plus `gh auth switch` - goes unused for two
reasons: `auth switch` mutates one global "active account" in `~/.config/gh` (racy for two agents in two
orgs), and any `GH_TOKEN` in the environment makes every account inert (`gh auth switch` refuses: *"the
value of the GH_TOKEN environment variable is being used for authentication"*). Per-directory resolution
keeps `gh` stateless instead.

The container has **no keyring**: `gh` would store a login in plaintext in `~/.config/gh/hosts.yml`, same
posture as `secrets.env`. Plaintext isn't the deciding factor - scope breadth and the active account are.

`gh auth status` succeeds on a resolved token alone, so `bootstrap` stops asking once every identity's is
set.

## Agent git credentials

`git` itself in an agent session uses a different credential path from `gh` above: the `omp` launcher's
`agent.gitconfig` and `devbox-git-credential`. See
[Git identities](git.md#agent-sessions) for the mechanism; this page covers only where those secrets live -
`~/.config/devbox/secrets.env` and each identity's `app` directory (`{app-id,app.pem}`) on the laptop too,
read there by its copy of the helper (`./bin/install-agent`).

## Per-project secrets

A cloned project's `.env` looks exactly as on the laptop - same variable names, no devbox-specific
additions; no injection mechanism to accommodate, so nothing needs extending "for the devbox".

The laptop keeps 1Password in the loop. Commit a template of references and render it locally:

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

1Password stays the source of truth; the rendered file is never committed; the container never
authenticates to a vault. Rotation is one re-render, one copy.

Values differing because the box is a different machine - `localhost` ports, container-local database
hosts, callback URLs - are ordinary environment differences, kept in the project's override convention,
not a devbox mechanism.

### Projects that call `op` themselves

A `package.json` script or `Makefile` wrapped in `op run --` or `op inject` fails in the container: no `op`
binary, no account. Render the `.env` on the laptop and run the command directly - the one place op's
absence shows.

## Google Cloud (ADC)

For a project needing Google APIs, use a **dedicated service account in that project's GCP project**,
never `gcloud auth application-default login`.

That command writes a refresh token for **your** Google account with `cloud-platform` scope to
`~/.config/gcloud/application_default_credentials.json`. It never expires and impersonates you across every
reachable project - in a box built for unattended agents, the largest, least contained credential
available.

ADC resolves in three steps, first hit wins:

1. `GOOGLE_APPLICATION_CREDENTIALS` - path to a JSON key or external-account config
2. `~/.config/gcloud/application_default_credentials.json` - the well-known user file
3. the GCE/GKE/Cloud Run metadata server - absent in this container

Step 1 beating step 2 is the whole mechanism: point the variable at a scoped key so your identity never
enters the box. No tier consults `gcloud config`, so `gcloud config set project` has no effect.

Provision on the laptop, once per project:

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

Store the key in 1Password, copy it to `~/.config/gcloud/<gcp-project>-devbox.json` at mode 600, delete the
local copy, and reference it from **that project's** `.env`:

```dotenv
GOOGLE_APPLICATION_CREDENTIALS=/home/dev/.config/gcloud/<gcp-project>-devbox.json
GOOGLE_CLOUD_PROJECT=<gcp-project-id>
GOOGLE_CLOUD_LOCATION=<region>
```

`GOOGLE_CLOUD_PROJECT` matters: with a service-account key, no metadata server infers the project. Rotation
is `keys create` then `keys delete <old-key-id>`, no devbox change.

Never write a service-account key to `application_default_credentials.json` - that's ADC step 2, becoming a
silent box-wide default any project picks up when its variable is missing. Leaving step 2 empty makes a
misconfigured project fail loudly, not quietly bill the wrong project.

There's no `gcloud` CLI in the image: nothing shells out to it, and ADC needs only the key file. Run
`gcloud` on the laptop, where your identity lives.

### Containing spend

An inference credential's blast radius is **cost**, not data - an autonomous loop can bill real money, so
containment is a billing budget with alerts plus Vertex per-model quota limits there. Budgets notify;
quotas cap, the one that matters for an unattended overnight run.

Note what does *not* contain it: forbidding `gcloud` or `op` in an agent's allowlist changes nothing - any
script can read the key and call the API through the SDK. The boundary is what the service account is
permitted to do.

## ❓ FAQ

**Why is `op` not installed?**
Its only use was injecting secrets, and a live `op` session is reachable by any agent in that shell - a leak
would then cost every vault, not one project's. Secrets end up in plaintext in `.env` regardless, since
apps must read them; removing `op` shrinks blast radius without weakening anything at rest.

**Don't I need `op` for signing?**
No - unrelated to `op`. Manual signing (`ssh -A devbox`) borrows the laptop's forwarded 1Password *SSH
agent*, signing with `ssh-keygen -Y sign` - different from the uninstalled `op` CLI. Agent sessions don't
sign at all: `agent.gitconfig` sets `commit.gpgsign = false`, with no key or forwarded agent in reach. See
[Git identities](git.md#signing).

**Why does `.env` on the host hold no secrets?**
It holds addressing, host-user mapping and SSH-authorization configuration only (`BIND_ADDR`,
`HOST_UID`/`HOST_GID`, `DEVBOX_GITHUB_USER`) - gitignored and excluded from `bin/push`, but not a secret
store. Git identities - names, emails, public keys, bot authors, GitHub Apps - live in
`~/.config/devbox/identities.conf` instead, on the bind mount and not tracked by this repo at all; see
[Git identities](git.md#the-identity-registry).

**Can I put a raw API key in `secrets.env`?**
That's exactly what it's for - plain values, mode 600. Keep it to credentials shared across projects.

**`bootstrap` says my `secrets.env` still holds `op://` references.**
`/home/dev` survives every rebuild, so an old `op run` file is still there, now sourced directly, exporting
`op://…` into every shell. Replace those lines with plain values, rendered on the laptop. A leftover
per-account secrets file from an older layout reports the same way and can be deleted - one `secrets.env`
now serves every project.

**I already had a single box-wide `GH_TOKEN`. What now?**
It keeps working - the resolver returns it for every directory - but overrides every per-identity variable,
so nothing's chosen per tree. `bootstrap` prints exactly that: rename it to the `GH_TOKEN_<SLUG>` of your
default identity, issue further fine-grained tokens as `GH_TOKEN_<SLUG>` for each other identity, reconnect.

**`echo $GH_TOKEN` is empty - is `gh` broken?**
No. Nothing exports `GH_TOKEN`; the `gh` shim resolves it per invocation from the working directory. Check
with `devbox-gh-token --account` and `gh auth status`; for your own calls use
`GH_TOKEN=$(devbox-gh-token)`.

**`devbox-gh-token: GH_TOKEN_WORK is unset`**
You're inside the `work` identity's tree and only the default identity's token is configured - deliberate:
no fallback, since the default token on a `work` repo is the wrong identity, not a degraded one. Add the
variable, or work outside the tree.

**Can I add a third account?**
Yes - `identities.conf` takes any number of `[slug]` blocks. Add one, its `GH_TOKEN_<SLUG>` here, and its
two public keys; nothing here or in `bootstrap` needs a new branch. See
[Git identities](git.md#the-identity-registry).

**Why not just `gh auth switch` between accounts?**
Because `GH_TOKEN` - however set - makes every account stored in `~/.config/gh` inert, and the "active
account" is one global value concurrent agents would race. See [Why not `gh auth login`](#why-not-gh-auth-login).

**Does OMP see my keys in plaintext?**
`~/.omp/agent/config.yml` sets `secrets: { enabled: true }`, obfuscating environment secrets before they
reach a provider.

**How do I rotate a leaked key?**
Revoke at source - GitHub's token settings page for a PAT, `gcloud iam service-accounts keys delete`
for GCP, or regenerate `app.pem` from the App's settings and replace it at the directory that identity's
`app` field names in `identities.conf`, then update `secrets.env` or the project `.env`. No SSH keypair
to rotate: identity is your laptop's key, unaffected by the container.

**Are secrets visible to the workstation's host user?**
Yes. The bind mount is owned by `HOST_UID`, readable by the host user. The container protects the host from
the agent, not the agent's files from the owner - workstation disk encryption is part of this model.

**What happens to secrets on `./bin/devbox rebuild`?**
Nothing - they're in `/home/dev` on the host, not the image.
