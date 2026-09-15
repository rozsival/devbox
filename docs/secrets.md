# 🔐 Secrets

Nothing secret is baked into the image, fetched by `bootstrap`, or committed to this repo. The container holds **no
1Password account and no Google account** - `op` is not even installed. Secrets are rendered on the
laptop, where approving access is yours to do, and copied in.

That is a deliberate reduction of authority, not an oversight. The container is an isolation boundary for the
host filesystem and a containment boundary for credentials; it is **not** a confidentiality boundary. Assume
anything inside can leave, and put nothing inside that is not worth its own blast radius. See
[Security](security.md).

## Three layers

| Layer                  | Holds                                             | Scope of a leak                                          |
|------------------------|---------------------------------------------------|----------------------------------------------------------|
| Identity (public keys) | `~/.ssh/id_personal.pub`, `~/.ssh/id_work.pub` | none by itself - selects which forwarded key GitHub sees |
| Box-wide tools         | `~/.config/devbox/secrets.env`                    | the tools' own credentials                               |
| Per project            | that project's `.env`                             | one project                                              |

Everything lives on the `/home/dev` bind mount, so all of it survives container and image rebuilds and is
established once per host.

| Secret                                   | Lives in                                                             | Established by                                                                                                           |
|------------------------------------------|----------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------|
| SSH identity public keys (both accounts) | `~/.ssh/id_*.pub` (authentication), `~/.ssh/signing_*.pub` (signing) | `bootstrap`, from `GIT_*_PUBKEY` / `GIT_*_SIGNINGKEY` in `.env` - no private key ever present                            |
| `gh` tokens, one per account             | `~/.config/devbox/secrets.env`                                       | you, two fine-grained GitHub PATs                                                                                        |
| Model API keys for OMP                   | `~/.config/devbox/secrets.env`                                       | you, plain values                                                                                                        |
| GitHub App (work-app)              | `~/.config/work/work-app/`                                  | you, `app-id` + `app.pem` at mode 600 - consumed per git operation by `devbox-git-credential` ([Git identities](git.md)) |
| Per-project secrets                      | `<project>/.env`                                                     | you, rendered on the laptop                                                                                              |
| GCP service-account key                  | `~/.config/gcloud/<gcp-project>-*.json`                              | you, one per project, mode 600                                                                                           |

## Manual checklist

`bootstrap` prints exactly what is left; nothing below is ever automated, because all of it needs a browser
or a secret.

1. Set `GIT_PERSONAL_PUBKEY` / `GIT_WORK_PUBKEY` (authentication) and `GIT_PERSONAL_SIGNINGKEY` /
   `GIT_WORK_SIGNINGKEY` (signing) in `.env` to the laptop's public keys - they are already registered on
   GitHub; the devbox does not register anything itself. See [Git identities](git.md#signing).
2. Fill `~/.config/devbox/secrets.env` with `GH_TOKEN_PERSONAL`, `GH_TOKEN_WORK` and any model API keys.
   Fine-grained, with `contents: write` on repositories agents push to without the App installed, plus
   `actions`/`checks` read; add `issues`/`pull-requests` write only if agents should post. `gh` picks the
   tokens up immediately - `devbox-gh-token` reads the file itself - but reconnect anyway so the model keys
   reach already-open shells.
3. Place the work-app GitHub App credentials in `~/.config/work/work-app/`
   (`app-id`, `app.pem` at mode 600) if you need them - `devbox-git-credential` mints a repository-scoped
   token from them on every agent git operation.

## Box-wide tool credentials

`~/.config/devbox/secrets.env` is plain `KEY=value` pairs at mode 600, installed from
`home/.config/devbox/secrets.env.example` if absent and never overwritten. `~/.bashrc.d/devbox.sh` sources it
inside `set -a` / `set +a`, **outside** the interactive guard - agents and tooling arrive as
`ssh devbox <cmd>`, which is non-interactive, and `container/bootstrap.sh` prepends the `~/.bashrc.d` loader
ahead of Ubuntu's skeleton `~/.bashrc` precisely so that path still reads it.

```dotenv
GH_TOKEN_PERSONAL=github_pat_...
GH_TOKEN_WORK=github_pat_...
ANTHROPIC_API_KEY=sk-ant-...
```

Only credentials **every** project shares belong here. A per-project secret in this file is reachable by every
agent working on every other project, which defeats the layering.

### `gh`

**One fine-grained token per GitHub account, chosen by the working directory** - the same rule that selects a
git identity, so one mental model covers both:

| Working directory       | Variable            | Account  |
|-------------------------|---------------------|----------|
| everywhere else         | `GH_TOKEN_PERSONAL` | personal |
| `~/projects/work/**` | `GH_TOKEN_WORK`  | work  |

Minimum useful permissions per token: `contents: write` on repositories agents push to without the GitHub
App installed (agent git falls back to this PAT - see [Git identities](git.md#agent-sessions)), plus
`actions` and `checks` **read** for dashboards and pipeline monitoring. Add issues or pull-requests **write**
only if agents should post.

```bash
cd ~/projects/work/<repo>
devbox-gh-token --account     # work
gh repo view --json nameWithOwner
```

#### Why a shim rather than an exported `GH_TOKEN`

`~/.local/libexec/devbox-agent/gh` is a shim ahead of the real `gh` on the PATH; it calls `devbox-gh-token`
and exports the result for that one invocation. `~/.bashrc.d/devbox.sh` deliberately exports **no**
`GH_TOKEN` at all.

The reason is where an agent's directory comes from: the session is opened in `$HOME` and the agent then works
with a project as its cwd. A token resolved once at shell startup would therefore pin the personal account for
the whole session, including inside `~/projects/work/`. Resolving per invocation is what makes the account
follow the tree.

Resolution order inside `devbox-gh-token`, first hit wins:

1. an explicit `GH_TOKEN` in the environment - a deliberate one-off, and what a pre-split `secrets.env` holds
2. the account's variable in the environment, from a shell that sourced `secrets.env`
3. the same variable read **directly out of `secrets.env`**

Step 3 is why `gh` needs no reconnect after you add a token, and why the resolver's error message is honest:
the file is the only place it looks.

Three consequences worth knowing:

- `echo $GH_TOKEN` prints nothing. That is correct. Anything that reads the token itself - a `curl` against
  the API, a project script - should ask the resolver: `GH_TOKEN=$(devbox-gh-token)`.
- An explicit `GH_TOKEN` wins over both variables, for `gh` and for the resolver. Use it for a deliberate
  one-off (`GH_TOKEN=$OTHER gh ...`); a permanent `GH_TOKEN=` line in `secrets.env` disables the
  per-directory choice entirely, and `bootstrap` warns about exactly that line.
- A missing token for the tree you are in is an error, not a fallback: `devbox-gh-token` exits non-zero and
  explains which variable is unset, while `gh` still runs (unauthenticated) so `gh --version` and
  `gh config set` keep working on a box with no tokens yet. Falling back to the other account would act as
  the wrong identity.

#### Why not `gh auth login`

Its web/device flow cannot ask for less than `repo`, `read:org` and `gist` - the floor is hard-coded in `gh`
(`minimumScopes` in `internal/authflow`), and `--scopes` only *adds* to it. `repo` on a classic token is
read **and write** on every repository either account can reach, including org repos, with no expiry and no
repository allowlist; a fine-grained PAT names its repositories, expires, and is revocable on its own. So the
web flow is strictly *broader* than what is configured here, not narrower.

`gh`'s own multi-account primitive - `gh auth login --with-token` per account plus `gh auth switch` - is a
genuine alternative, and with fine-grained PATs it keeps the scoping. It is not used here for two reasons:
`auth switch` mutates one global "active account" in `~/.config/gh`, which two agents working in two orgs at
once would race, and any `GH_TOKEN` in the environment makes every stored account inert (`gh auth switch`
then refuses outright: *"the value of the GH_TOKEN environment variable is being used for authentication"*).
Per-directory resolution keeps `gh` stateless instead.

Note the container has **no keyring**, so `gh` would store a login in plaintext in `~/.config/gh/hosts.yml` -
the same posture as `secrets.env` on the same bind mount. Plaintext is therefore not what decides this; scope
breadth and the global active account are.

`gh auth status` succeeds on a resolved token alone, so `bootstrap` stops asking once both are set.

## Agent git credentials

`git` itself (clone, pull, push, commit) inside an agent session uses a completely different, unrelated
credential path from `gh` above: the `omp` launcher's `agent.gitconfig` and `devbox-git-credential`, which
mint a per-repository GitHub App installation token or fall back to the same PATs `gh` uses. See
[Git identities](git.md#agent-sessions) for the mechanism; this page covers only where the underlying
secrets (PATs, App credentials) live.

## Per-project secrets

A cloned project's `.env` looks exactly as it does on the laptop - same variable names, no devbox-specific
additions. There is no injection mechanism to accommodate, so nothing has to be extended "for the devbox".

The laptop is where 1Password stays in the loop. Commit a template of references and render it locally:

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

1Password remains the source of truth; the rendered file is never committed; the container never authenticates
to a vault. Rotation is one re-render and one copy.

Values that differ because the box is a different machine - `localhost` ports, container-local database hosts,
callback URLs - are ordinary environment differences. Keep them in the project's own override convention, not
in a devbox mechanism.

### Projects that call `op` themselves

A `package.json` script or `Makefile` wrapped in `op run --` or `op inject` fails in the container: there is
no `op` binary and no account. Render the `.env` on the laptop and run the underlying command directly. This
is the one place removing `op` is visible.

## Google Cloud (ADC)

For a project that needs Google APIs - Agent Platform/Vertex inference, for instance - use a **dedicated
service account in that project's own GCP project**, never `gcloud auth application-default login`.

That command writes a refresh token for **your** Google account with `cloud-platform` scope to
`~/.config/gcloud/application_default_credentials.json`. It does not expire and it impersonates you across
every project your account can reach. Inside a box built for unattended agents, that is the largest credential
available and the least contained.

ADC resolves in three steps, first hit wins:

1. `GOOGLE_APPLICATION_CREDENTIALS` - path to a JSON key or external-account config
2. `~/.config/gcloud/application_default_credentials.json` - the well-known user file
3. the GCE/GKE/Cloud Run metadata server - absent in this container

Step 1 beating step 2 is the whole mechanism: point the variable at a scoped key and your identity never
enters the box. There is no tier that consults `gcloud config`, so `gcloud config set project` has no effect
on what a client library resolves.

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

Store the key in 1Password as the source of truth, copy it to
`~/.config/gcloud/<gcp-project>-devbox.json` at mode 600, delete the local copy, and reference it from **that
project's** `.env`:

```dotenv
GOOGLE_APPLICATION_CREDENTIALS=/home/dev/.config/gcloud/<gcp-project>-devbox.json
GOOGLE_CLOUD_PROJECT=<gcp-project-id>
GOOGLE_CLOUD_LOCATION=<region>
```

`GOOGLE_CLOUD_PROJECT` matters: with a service-account key there is no metadata server to infer the project
from. Rotation is `keys create` then `keys delete <old-key-id>`, with no devbox change.

Never write a service-account key to `application_default_credentials.json`. That is ADC step 2, so it would
become a silent box-wide default that any project picks up when its own variable is missing. Leaving step 2
empty makes a misconfigured project fail loudly instead of quietly billing the wrong GCP project.

There is no `gcloud` CLI in the image: nothing in the projects shells out to it during agent work, and ADC
needs only the key file. Run `gcloud` on the laptop, where your own identity already lives.

### Containing spend

An inference credential's blast radius is **cost**, not data. An autonomous loop can bill real money, so the
containment is a billing budget with alerts plus Vertex per-model quota limits on that GCP project. Budgets
notify; quotas actually cap, which is the one that matters for an unattended overnight run.

Also note what does *not* contain it: forbidding `gcloud` or `op` in an agent's allowlist changes nothing,
because any script can read the key file and call the API through the SDK. The boundary is what the service
account is permitted to do.

## ❓ FAQ

**Why is `op` not installed?**
Its only remaining use here was injecting project secrets, and a live `op` session is reachable by any agent
in that shell - so a leak that should cost one project's secrets costs every vault the account can read. The
project's secrets end up in plaintext in a `.env` either way, because the app has to read them. Removing `op`
therefore shrinks the blast radius without weakening anything at rest.

**Don't I need `op` for signing?**
No - and this is unrelated to `op` either way. Manual signing (`ssh -A devbox`) borrows the laptop's
forwarded 1Password *SSH agent* and signs with `ssh-keygen -Y sign`; that is a different piece of 1Password
from the `op` CLI, which stays uninstalled. Agent sessions don't sign at all - `agent.gitconfig` sets
`commit.gpgsign = false`, because there is no key or forwarded agent within an agent session's reach. See
[Git identities](git.md#signing).

**Why does `.env` on the host hold no secrets?**
It holds addressing and identity configuration only (`BIND_ADDR`, UID/GID, emails, public keys). It is
gitignored and excluded from `bin/push`, but it is not a secret store.

**Can I put a raw API key in `secrets.env`?**
That is exactly what it is for now - plain values, mode 600. Keep it to credentials shared across projects.

**`bootstrap` says my `secrets.env` still holds `op://` references.**
`/home/dev` survives every rebuild, so a file written for the old `op run` layout is still there - and it is
now sourced directly, which exports the literal `op://…` string into every shell. Replace those lines with
plain values (render them on the laptop). A leftover `secrets.work.env` is reported the same way and can
simply be deleted; one `secrets.env` now serves every project.

**I already had a single box-wide `GH_TOKEN`. What now?**
It keeps working - the resolver returns it for every directory - but it overrides both per-account variables,
so nothing is ever chosen per tree. `bootstrap` prints exactly that. Rename it to `GH_TOKEN_PERSONAL`, issue a
second fine-grained token for the other account as `GH_TOKEN_WORK`, and reconnect.

**`echo $GH_TOKEN` is empty - is `gh` broken?**
No. Nothing exports `GH_TOKEN`; the `gh` shim resolves it per invocation from the working directory. Check
with `devbox-gh-token --account` and `gh auth status`. For your own API calls use
`GH_TOKEN=$(devbox-gh-token)`.

**`devbox-gh-token: GH_TOKEN_WORK is unset`**
You are inside `~/projects/work/**` and only the personal token is configured. This is deliberate: there is
no fallback, because the personal token acting on an work repo is the wrong identity, not a degraded one.
Add the variable, or work outside that tree.

**Can I add a third account?**
Three places in this repo, all named on purpose: a branch in `home/.local/bin/devbox-gh-token` for the new
directory prefix and its variable, a `<name>:<directory>` entry in `container/bootstrap.sh` §11's account loop (so the
checklist covers it), and - if it also needs its own git identity - an `includeIf` for the same prefix
alongside the work one. Keep the directory rule identical in all three.

**Why not just `gh auth switch` between accounts?**
Because `GH_TOKEN` - however it is set - makes every account stored in `~/.config/gh` inert, and the "active
account" is one global value that concurrent agents would race. See [Why not `gh auth login`](#why-not-gh-auth-login).

**Does OMP see my keys in plaintext?**
`~/.omp/agent/config.yml` sets `secrets: { enabled: true }`, which obfuscates environment secrets before they
can reach a provider.

**How do I rotate a leaked key?**
Revoke at the source - the GitHub token settings page for a PAT, `gcloud iam service-accounts keys delete`
for GCP, or regenerate `app.pem` from the App's settings and replace
`~/.config/work/work-app/app.pem`. Then replace the value in `secrets.env` or the project `.env`.
There is no SSH keypair to rotate on the devbox: identity is your laptop's own key, unaffected by anything
that happens inside the container.

**Are secrets visible to the workstation's host user?**
Yes. The bind mount is owned by `HOST_UID` and the host user can read it. The container protects the host from
the agent, not the agent's files from the host owner. Workstation disk encryption is part of this model.

**What happens to secrets on `./bin/devbox rebuild`?**
Nothing - they are in `/home/dev` on the host, not in the image.
