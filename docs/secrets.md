# 🔐 Secrets

Nothing secret is baked into the image, fetched by `bootstrap`, or committed to this repo. The container holds
**no 1Password account and no Google account** - `op` is not even installed. Secrets are rendered on the
laptop, where approving access is yours to do, and copied in.

That is a deliberate reduction of authority, not an oversight. The container is an isolation boundary for the
host filesystem and a containment boundary for credentials; it is **not** a confidentiality boundary. Assume
anything inside can leave, and put nothing inside that is not worth its own blast radius. See
[Security](security.md).

## Three layers

| Layer            | Holds                                     | Scope of a leak                  |
|------------------|-------------------------------------------|----------------------------------|
| Identity         | `~/.ssh/id_personal`, `~/.ssh/id_work` | your GitHub accounts' push reach |
| Box-wide tools   | `~/.config/devbox/secrets.env`            | the tools' own credentials       |
| Per project      | that project's `.env`                     | one project                      |

Everything lives on the `/home/dev` bind mount, so all of it survives container and image rebuilds and is
established once per host.

| Secret                      | Lives in                                  | Established by                        |
|-----------------------------|-------------------------------------------|---------------------------------------|
| SSH keys (both identities)  | `~/.ssh/id_personal`, `~/.ssh/id_work` | `bootstrap`, passphrase-less          |
| `GH_TOKEN` for `gh`         | `~/.config/devbox/secrets.env`            | you, a fine-grained GitHub PAT        |
| Model API keys for OMP      | `~/.config/devbox/secrets.env`            | you, plain values                     |
| GitHub App (work-app) | `~/.config/work/work-app/`       | you, `app-id` + `app.pem` at mode 600 |
| Per-project secrets         | `<project>/.env`                          | you, rendered on the laptop           |
| GCP service-account key     | `~/.config/gcloud/<gcp-project>-*.json`   | you, one per project, mode 600        |

## Manual checklist

`bootstrap` prints exactly what is left; nothing below is ever automated, because all of it needs a browser
or a secret.

1. Add both keys from `./bin/devbox keys` to GitHub **twice each** - once as an Authentication key, once as a
   Signing key. See [Git identities](git.md#github-registration).
2. Fill `~/.config/devbox/secrets.env` with `GH_TOKEN` and any model API keys, then reconnect so the new
   shell sources it.
3. Place the work-app GitHub App credentials in `~/.config/work/work-app/`
   (`app-id`, `app.pem` at mode 600) if you need them.

## Box-wide tool credentials

`~/.config/devbox/secrets.env` is plain `KEY=value` pairs at mode 600, installed from
`home/.config/devbox/secrets.env.example` if absent and never overwritten. `~/.bashrc.d/devbox.sh` sources it
inside `set -a` / `set +a`, **outside** the interactive guard - agents and tooling arrive as
`ssh devbox <cmd>`, which is non-interactive, and `container/bootstrap.sh` prepends the `~/.bashrc.d` loader
ahead of Ubuntu's skeleton `~/.bashrc` precisely so that path still reads it.

```dotenv
GH_TOKEN=github_pat_...
ANTHROPIC_API_KEY=sk-ant-...
```

Only credentials **every** project shares belong here. A per-project secret in this file is reachable by every
agent working on every other project, which defeats the layering.

### `gh`

Use a **fine-grained personal access token** in `GH_TOKEN`, not `gh auth login --web`. The web flow stores an
OAuth token carrying `repo`, `workflow`, `gist` and `read:org` - write access to every repository both
accounts can reach - in plaintext in `~/.config/gh/hosts.yml`, because the container has no keyring. A
fine-grained token expires, names its repositories, and is revocable without touching the laptop.

Minimum useful scopes: contents, actions and checks **read** for dashboards and pipeline monitoring. Add
issues or pull-requests **write** only if agents should post. `git push` needs none of them - that goes over
SSH with the container's own keys.

`gh auth status` succeeds on `GH_TOKEN` alone, so `bootstrap` stops asking once it is set.

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
No. `bootstrap` generates dedicated passphrase-less keys in the container and git signs with `ssh-keygen`. The
1Password SSH agent's per-use approval, the reason it is pleasant on the laptop, is exactly what a
non-interactive herdr connection cannot answer.

**Why does `.env` on the host hold no secrets?**
It holds addressing and identity configuration only (`BIND_ADDR`, UID/GID, emails). It is gitignored and
excluded from `bin/push`, but it is not a secret store.

**Can I put a raw API key in `secrets.env`?**
That is exactly what it is for now - plain values, mode 600. Keep it to credentials shared across projects.

**`bootstrap` says my `secrets.env` still holds `op://` references.**
`/home/dev` survives every rebuild, so a file written for the old `op run` layout is still there - and it is
now sourced directly, which exports the literal `op://…` string into every shell. Replace those lines with
plain values (render them on the laptop). A leftover `secrets.work.env` is reported the same way and can
simply be deleted; one `secrets.env` now serves every project.

**Does OMP see my keys in plaintext?**
`~/.omp/agent/config.yml` sets `secrets: { enabled: true }`, which obfuscates environment secrets before they
can reach a provider.

**How do I rotate a leaked key?**
Revoke at the source - `gh ssh-key delete`, the GitHub token settings page, `gcloud iam service-accounts keys
delete` - then replace the value in `secrets.env` or the project `.env`. `./bin/devbox bootstrap` regenerates
only what is missing; delete an old SSH key file first if you want a fresh pair, and re-register it.

**Are secrets visible to the workstation's host user?**
Yes. The bind mount is owned by `HOST_UID` and the host user can read it. The container protects the host from
the agent, not the agent's files from the host owner. Workstation disk encryption is part of this model.

**What happens to secrets on `./bin/devbox rebuild`?**
Nothing - they are in `/home/dev` on the host, not in the image.
