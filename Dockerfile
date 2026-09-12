# syntax=docker/dockerfile:1

# Matches the workstation host OS.
FROM ubuntu:26.04

# Kept in sync with the host user so the bind-mounted home needs no chown.
ARG HOST_UID=1000
ARG HOST_GID=1000

# Pinned toolchain. Every version is a real upstream release asset; bump one arg
# at a time and rebuild with `./bin/devbox rebuild`.
ARG HERDR_VERSION=0.9.0
ARG NVM_VERSION=0.40.7
ARG NODE_VERSION=24.21.0
ARG PNPM_VERSION=12.4.1
ARG GH_VERSION=2.100.0
ARG LAZYGIT_VERSION=0.65.0
ARG WORKTRUNK_VERSION=0.77.0
ARG TERRAFORM_VERSION=1.16.2
ARG OP_VERSION=2.39.0

ENV DEBIAN_FRONTEND=noninteractive

# `apt-get` only, never `apt`: `apt` has no stable CLI interface and warns on
# every scripted call. `starship` comes from the Ubuntu archive, exactly as
# workstation's `setup shell` step does.
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    fd-find \
    file \
    git \
    git-lfs \
    gnupg \
    iproute2 \
    iputils-ping \
    jq \
    less \
    locales \
    nano \
    openssh-client \
    openssh-server \
    procps \
    python3 \
    python3-venv \
    ripgrep \
    rsync \
    starship \
    tzdata \
    unzip \
    xz-utils \
    zip \
  && rm -rf /var/lib/apt/lists/* \
  && ln -s "$(command -v fdfind)" /usr/local/bin/fd

# TZ is applied at runtime from the compose environment; the locale must exist in
# the image because a login shell cannot generate it unprivileged.
RUN sed -i 's/^# *\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

# The base image ships an `ubuntu` user on UID 1000; reclaim the id first so
# `dev` can own it and match the host user of the bind mount.
RUN if getent passwd "${HOST_UID}" >/dev/null; then userdel -r "$(getent passwd "${HOST_UID}" | cut -d: -f1)" 2>/dev/null || true; fi \
  && if getent group "${HOST_GID}" >/dev/null; then groupdel "$(getent group "${HOST_GID}" | cut -d: -f1)" 2>/dev/null || true; fi \
  && groupadd -g "${HOST_GID}" dev \
  && useradd -m -u "${HOST_UID}" -g "${HOST_GID}" -s /bin/bash dev

# Pinned binaries land in /usr/local/bin, which is on the default *non-interactive*
# sshd PATH. That is load-bearing for herdr: it prefers a compatible binary already
# on the remote PATH and non-interactive runs fail rather than installing one, which
# is exactly how saved-machine background connections run.
#
# Checksums are verified wherever upstream publishes a checksum file; `herdr` and
# `op` publish none, so those rely on the pinned version plus TLS.
RUN set -eux; \
  tmp="$(mktemp -d)"; cd "$tmp"; \
  \
  curl -fsSL -o herdr "https://github.com/herdrdev/herdr/releases/download/v${HERDR_VERSION}/herdr-linux-x86_64"; \
  install -m 0755 herdr /usr/local/bin/herdr; \
  \
  curl -fsSL -o gh.deb "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.deb"; \
  curl -fsSL -o gh.sums "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_checksums.txt"; \
  awk -v f="gh_${GH_VERSION}_linux_amd64.deb" '$2 == f { print $1 "  gh.deb" }' gh.sums | sha256sum -c -; \
  dpkg -i gh.deb; \
  \
  curl -fsSL -o lazygit.tar.gz "https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}/lazygit_${LAZYGIT_VERSION}_linux_x86_64.tar.gz"; \
  curl -fsSL -o lazygit.sums "https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}/checksums.txt"; \
  awk -v f="lazygit_${LAZYGIT_VERSION}_linux_x86_64.tar.gz" '$2 == f { print $1 "  lazygit.tar.gz" }' lazygit.sums | sha256sum -c -; \
  tar -xzf lazygit.tar.gz lazygit; \
  install -m 0755 lazygit /usr/local/bin/lazygit; \
  \
  curl -fsSL -o wt.tar.xz "https://github.com/max-sixty/worktrunk/releases/download/v${WORKTRUNK_VERSION}/worktrunk-x86_64-unknown-linux-musl.tar.xz"; \
  curl -fsSL -o wt.sha256 "https://github.com/max-sixty/worktrunk/releases/download/v${WORKTRUNK_VERSION}/worktrunk-x86_64-unknown-linux-musl.tar.xz.sha256"; \
  awk '{ print $1 "  wt.tar.xz" }' wt.sha256 | sha256sum -c -; \
  tar -xJf wt.tar.xz; \
  install -m 0755 "worktrunk-x86_64-unknown-linux-musl/wt" /usr/local/bin/wt; \
  install -m 0755 "worktrunk-x86_64-unknown-linux-musl/git-wt" /usr/local/bin/git-wt; \
  \
  curl -fsSL -o terraform.zip "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip"; \
  curl -fsSL -o terraform.sums "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_SHA256SUMS"; \
  awk -v f="terraform_${TERRAFORM_VERSION}_linux_amd64.zip" '$2 == f { print $1 "  terraform.zip" }' terraform.sums | sha256sum -c -; \
  unzip -q terraform.zip terraform; \
  install -m 0755 terraform /usr/local/bin/terraform; \
  \
  curl -fsSL -o op.zip "https://cache.agilebits.com/dist/1P/op2/pkg/v${OP_VERSION}/op_linux_amd64_v${OP_VERSION}.zip"; \
  unzip -q op.zip op; \
  install -m 0755 op /usr/local/bin/op; \
  \
  cd /; rm -rf "$tmp"

# Node lives outside /home/dev: the home directory is bind-mounted at runtime and
# would shadow anything installed under it.
ENV NVM_DIR=/opt/nvm \
    COREPACK_HOME=/opt/corepack
RUN mkdir -p "$NVM_DIR" "$COREPACK_HOME" && chown dev:dev "$NVM_DIR" "$COREPACK_HOME"

USER dev
RUN set -eux; \
  PROFILE=/dev/null bash -c "curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v${NVM_VERSION}/install.sh | bash"; \
  . "$NVM_DIR/nvm.sh"; \
  nvm install "${NODE_VERSION}"; \
  nvm alias default "${NODE_VERSION}"; \
  corepack enable yarn; \
  npm install -g "pnpm@${PNPM_VERSION}"
# pnpm is installed with npm rather than `corepack prepare`: pnpm 12 ships a
# native binary as an optional dependency, and the corepack cache holds only the
# JS wrapper - so every corepack-shimmed `pnpm` call re-downloads that binary.
# corepack is enabled for yarn alone; its pnpm shim would shadow the real one.

# Same reason as the pinned binaries above: non-interactive SSH sessions get the
# default PATH and never source ~/.bashrc, so the toolchain needs a stable home.
USER root
RUN set -eux; \
  for b in node npm npx corepack pnpm pnpx; do \
    if [ -x "/opt/nvm/versions/node/v${NODE_VERSION}/bin/$b" ]; then \
      ln -sf "/opt/nvm/versions/node/v${NODE_VERSION}/bin/$b" "/usr/local/bin/$b"; \
    fi; \
  done

# Baked in as a fallback; compose bind-mounts the same paths read-only so host
# edits take effect without a rebuild.
COPY container/ /opt/devbox/container/
COPY home/ /opt/devbox/home/

# The container has no root process at runtime: sshd runs as `dev` and only ever
# authenticates the user it already runs as (UsePAM no, pubkey-only), so it needs
# neither /etc/shadow nor setuid. User namespaces are not configured on the host,
# so container root would be host UID 0 in a runtime escape.
USER dev
WORKDIR /home/dev
ENTRYPOINT ["/opt/devbox/container/entrypoint.sh"]
