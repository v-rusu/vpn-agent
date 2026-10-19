# syntax=docker/dockerfile:1
#
# Agentic dev environment image.
# Targets: linux/arm64 (Apple Silicon) and linux/amd64 — whatever the building
# host is (BuildKit's TARGETARCH).
#
# Build:
#   docker build -t agent-box .
#
# All secrets/configs are bind-mounted at runtime (see docker-compose.yml),
# never baked into the image.
#
# Prerequisite: bin/solomonar-linux-<arch> must exist in the build context —
# run scripts/fetch-solomonar.sh first (it is gitignored, not checked in).

ARG TMUX_VERSION=3.7b

# ----------------------------------------------------------------------------
# Builder: tmux from the upstream release tarball. Ubuntu 24.04 ships 3.4;
# solomonar needs >= 3.2 and the fleet relies on 3.7 features. Installed into
# /out/usr/local and copied into the final image (runtime deps: libevent-core,
# libtinfo — both pulled in below).
# ----------------------------------------------------------------------------
FROM ubuntu:24.04 AS tmux-build
ARG TMUX_VERSION
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl build-essential pkg-config bison \
        libevent-dev libncurses-dev \
    && rm -rf /var/lib/apt/lists/*
RUN set -eux; \
    curl -fsSL "https://github.com/tmux/tmux/releases/download/${TMUX_VERSION}/tmux-${TMUX_VERSION}.tar.gz" \
        | tar -xz -C /tmp; \
    cd "/tmp/tmux-${TMUX_VERSION}"; \
    ./configure --prefix=/usr/local; \
    make -j"$(nproc)"; \
    make install DESTDIR=/out; \
    /out/usr/local/bin/tmux -V

FROM ubuntu:24.04

ARG NODE_MAJOR=22
ARG PYTHON_VERSION=3.14
ARG GO_VERSION=1.26.5
ARG KUBECTL_VERSION=v1.36.3
ARG CLAUDE_CODE_VERSION=2.1.284
ARG TAILSCALE_VERSION=1.104.1
ARG AGENT_UID=1000
ARG AGENT_GID=1000

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC
ENV HOME=/home/agent
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

# Detect host arch once. dpkg prints: amd64 | arm64
RUN echo "BUILD ARCH: $(dpkg --print-architecture)"

# ----------------------------------------------------------------------------
# 1. Base system packages + networking + WireGuard support
# ----------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl wget gnupg lsb-release \
        software-properties-common apt-transport-https \
        git openssh-client build-essential gcc g++ make pkg-config \
        ripgrep fd-find jq zip unzip tar gzip xz-utils \
        less file vim sudo gosu procps iproute2 \
        libevent-core-2.1-7t64 libtinfo6 \
        htop tree man-db \
        wireguard-tools iptables \
    && ln -sf "$(command -v fdfind)" /usr/local/bin/fd \
    && rm -rf /var/lib/apt/lists/*

# ----------------------------------------------------------------------------
# 2. Python (deadsnakes PPA) + pip + uv
# ----------------------------------------------------------------------------
RUN add-apt-repository -y ppa:deadsnakes/ppa \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        python${PYTHON_VERSION} \
        python${PYTHON_VERSION}-venv \
        python${PYTHON_VERSION}-dev \
    && rm -rf /var/lib/apt/lists/* \
    && update-alternatives --install /usr/local/bin/python  python  /usr/bin/python${PYTHON_VERSION} 1 \
    && update-alternatives --install /usr/local/bin/python3 python3 /usr/bin/python${PYTHON_VERSION} 1 \
    && python${PYTHON_VERSION} -m ensurepip

# uv (Astral) — downloaded as a static binary.
RUN set -eux; \
    ARCH=$(dpkg --print-architecture); \
    case "$ARCH" in \
        amd64) UV_ARCH=x86_64 ;; \
        arm64) UV_ARCH=aarch64 ;; \
        *) echo "unsupported arch: $ARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/astral-sh/uv/releases/latest/download/uv-${UV_ARCH}-unknown-linux-gnu.tar.gz" \
        | tar -xz -C /tmp; \
    mv "/tmp/uv-${UV_ARCH}-unknown-linux-gnu/uv"  /usr/local/bin/uv; \
    mv "/tmp/uv-${UV_ARCH}-unknown-linux-gnu/uvx" /usr/local/bin/uvx

# ----------------------------------------------------------------------------
# 3. Node.js (NodeSource) + Bun
# ----------------------------------------------------------------------------
RUN set -eux; \
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -; \
    apt-get update; \
    apt-get install -y --no-install-recommends nodejs; \
    rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://bun.sh/install | BUN_INSTALL=/opt/bun bash

# ----------------------------------------------------------------------------
# 4. Go toolchain
# ----------------------------------------------------------------------------
RUN set -eux; \
    ARCH=$(dpkg --print-architecture); \
    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${ARCH}.tar.gz" \
        | tar -C /usr/local -xzf -

# ----------------------------------------------------------------------------
# 5. gcloud SDK (Google Cloud CLI) via apt — supports arm64 and amd64.
#    Adds the gke-gcloud-auth-plugin so `kubectl` can auth to GKE clusters.
# ----------------------------------------------------------------------------
RUN set -eux; \
    ARCH=$(dpkg --print-architecture); \
    install -m 0755 -d /etc/apt/keyrings; \
    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
        | gpg --dearmor -o /etc/apt/keyrings/cloud.google.gpg; \
    chmod a+r /etc/apt/keyrings/cloud.google.gpg; \
    echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
        > /etc/apt/sources.list.d/google-cloud-sdk.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        google-cloud-cli \
        google-cloud-cli-gke-gcloud-auth-plugin; \
    rm -rf /var/lib/apt/lists/*

# ----------------------------------------------------------------------------
# 6. kubectl
# ----------------------------------------------------------------------------
RUN set -eux; \
    ARCH=$(dpkg --print-architecture); \
    curl -fsSL -o /usr/local/bin/kubectl \
        "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl"; \
    chmod +x /usr/local/bin/kubectl

# ----------------------------------------------------------------------------
# 7. GitHub CLI (gh) + Docker CLI (talks to host daemon via socket)
# ----------------------------------------------------------------------------
RUN set -eux; \
    ARCH=$(dpkg --print-architecture); \
    install -m 0755 -d /etc/apt/keyrings; \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null; \
    chmod a+r /etc/apt/keyrings/githubcli-archive-keyring.gpg; \
    echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list; \
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg; \
    chmod a+r /etc/apt/keyrings/docker.gpg; \
    . /etc/os-release; \
    echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME} stable" \
        > /etc/apt/sources.list.d/docker.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends gh docker-ce-cli docker-buildx-plugin docker-compose-plugin; \
    rm -rf /var/lib/apt/lists/*

# ----------------------------------------------------------------------------
# 7b. Tailscale (official apt repo, pinned). tailscaled is started by the
#     entrypoint only when TAILSCALE_ENABLE=1 or saved state exists.
# ----------------------------------------------------------------------------
RUN set -eux; \
    . /etc/os-release; \
    curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${UBUNTU_CODENAME}.noarmor.gpg" \
        -o /usr/share/keyrings/tailscale-archive-keyring.gpg; \
    curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${UBUNTU_CODENAME}.tailscale-keyring.list" \
        -o /etc/apt/sources.list.d/tailscale.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends "tailscale=${TAILSCALE_VERSION}"; \
    rm -rf /var/lib/apt/lists/*

# ----------------------------------------------------------------------------
# 8. yq (mikefarah/yq)
# ----------------------------------------------------------------------------
RUN set -eux; \
    ARCH=$(dpkg --print-architecture); \
    mkdir -p /tmp/yq-install; \
    curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${ARCH}.tar.gz" \
        | tar -xz -C /tmp/yq-install; \
    install -m 0755 "/tmp/yq-install/yq_linux_${ARCH}" /usr/local/bin/yq; \
    rm -rf /tmp/yq-install

# ----------------------------------------------------------------------------
# 9. Agent tooling: opencode + beads (bd) + Claude Code (pinned)
# ----------------------------------------------------------------------------
RUN npm install -g opencode-ai @beads/bd "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"

# tmux built from source in the tmux-build stage (see top of file).
COPY --from=tmux-build /out/usr/local/ /usr/local/

# ----------------------------------------------------------------------------
# 10. Non-root user + environment
# ----------------------------------------------------------------------------
# The ubuntu:24.04 base ships a user/group "ubuntu" at UID/GID 1000; remove it
# so the `agent` user can claim 1000 (the conventional host UID for bind mounts).
RUN set -eux; \
    if id -u ubuntu >/dev/null 2>&1; then userdel -r ubuntu; fi; \
    if getent group ubuntu >/dev/null 2>&1; then groupdel ubuntu; fi; \
    groupadd -g ${AGENT_GID} agent \
    # Supplementary membership in group 'root' (gid 0) is what grants the
    # unprivileged agent access to /var/run/docker.sock on Docker Desktop,
    # where the socket is root:root mode 0660. On a Linux host with a
    # 'docker' group, pass its gid via --group-add instead (see README).
    && useradd -m -u ${AGENT_UID} -g ${AGENT_GID} -G root -s /bin/bash agent \
    && install -d -o agent -g agent /home/agent/.config /home/agent/.local/bin /home/agent/.claude \
    # Reclaim ownership of /home/agent: earlier RUN steps (e.g. npm postinstall
    # hooks that respect HOME) may have created files here as root before the
    # agent user existed, which would block the agent from writing to its home.
    && chown -R agent:agent /home/agent

# ----------------------------------------------------------------------------
# 10b. Cursor terminal agent — headless CLI installed as the `agent` user.
#      The installer is $HOME-relative: it drops the binary under
#      ~/.local/share/cursor-agent and symlinks `agent` + `cursor-agent`
#      into ~/.local/bin (already on PATH).
# ----------------------------------------------------------------------------
USER agent
RUN curl -fsSL https://cursor.com/install | bash
USER root

# ----------------------------------------------------------------------------
# 10c. tmux persistence — TPM + resurrect + continuum, so session layout is
#      auto-saved into the mounted workspace and restored on next start.
# ----------------------------------------------------------------------------
USER agent
RUN git clone --depth 1 https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm \
 && git clone --depth 1 https://github.com/tmux-plugins/tmux-resurrect ~/.tmux/plugins/tmux-resurrect \
 && git clone --depth 1 https://github.com/tmux-plugins/tmux-continuum ~/.tmux/plugins/tmux-continuum
COPY --chown=agent:agent tmux.conf /home/agent/.tmux.conf
COPY --chown=agent:agent tmux-restore-once.sh /home/agent/.tmux-restore-once.sh
RUN chmod +x /home/agent/.tmux-restore-once.sh
USER root

ENV BUN_INSTALL=/opt/bun
ENV PATH="/usr/local/go/bin:/usr/lib/google-cloud-sdk/bin:${BUN_INSTALL}/bin:/home/agent/.local/bin:${PATH}"
ENV GOPATH=/home/agent/go
ENV GOROOT=/usr/local/go
ENV EDITOR=vim

# gcloud + kubectl shell completion for bash, plus sourcing of persistent
# shell helpers: image-level from ~/.bashrc.d/*.sh, then per-workspace
# /workspace/.bashrc (one file per workspace) and any /workspace/.bashrc.d/*.sh
# fragments. Workspace files need no rebuild — just edit and open a new shell.
RUN echo 'source /usr/local/google-cloud-sdk/completion.bash.inc 2>/dev/null' \
        >> /home/agent/.bashrc \
    && echo 'source <(kubectl completion bash) 2>/dev/null' \
        >> /home/agent/.bashrc \
    && printf '\n# persistent shell helpers (image) + per-workspace overrides\n' \
        >> /home/agent/.bashrc \
    && printf 'for f in /home/agent/.bashrc.d/*.sh; do [ -r "$f" ] && . "$f"; done\n' \
        >> /home/agent/.bashrc \
    && printf '[ -r /workspace/.bashrc ] && . /workspace/.bashrc\n' \
        >> /home/agent/.bashrc \
    && printf 'for f in /workspace/.bashrc.d/*.sh; do [ -r "$f" ] && . "$f"; done\n' \
        >> /home/agent/.bashrc \
    && chown -R agent:agent /home/agent

# Persistent shell helpers (tmux session + agent resume shortcuts).
COPY --chown=agent:agent agent-bashrc.sh /home/agent/.bashrc.d/10-sessions.sh

# Login shells (tmux panes run `-bash`, `bash -lc`) must read ~/.bashrc too,
# otherwise PATH (~/.local/bin, go, gcloud) and the helpers above are missing.
RUN printf '%s\n' \
        '# login shells: read the interactive config too (PATH, helpers)' \
        'if [ -n "$BASH_VERSION" ] && [ -f "$HOME/.bashrc" ]; then . "$HOME/.bashrc"; fi' \
        > /home/agent/.profile \
    && chown agent:agent /home/agent/.profile

# Claude Code keeps ALL of its state under one dir when CLAUDE_CONFIG_DIR is
# set — including the global .claude.json that otherwise lives at
# ~/.claude.json. docker-compose.yml bind-mounts configs/claude/<PROFILE> here,
# so credentials, settings and session transcripts survive container recreate.
ENV CLAUDE_CONFIG_DIR=/home/agent/.claude

# Persist opencode session data across container recreation/rebuilds by
# pointing its data dir into the ALREADY-MOUNTED ~/.config/opencode volume
# (lands in configs/opencode/data on the host). Without this, opencode
# conversations die with the container and `opencode --continue` has nothing
# to resume. Cursor chats already persist via the ~/.cursor mount.
USER agent
RUN mkdir -p "$HOME/.local/share" \
 && rm -rf "$HOME/.local/share/opencode" \
 && ln -sfn "$HOME/.config/opencode/data" "$HOME/.local/share/opencode" \
 && test "$(readlink "$HOME/.local/share/opencode")" = "$HOME/.config/opencode/data"
USER root

# ----------------------------------------------------------------------------
# 11. Entrypoint + resolvconf shim (kept last so edits don't invalidate the
#     expensive toolchain layers above).
# ----------------------------------------------------------------------------
COPY resolvconf-shim.sh /usr/local/sbin/resolvconf
RUN chmod +x /usr/local/sbin/resolvconf
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# solomonar (`sol`): prebuilt binary for the target arch from the build
# context. Build it with scripts/fetch-solomonar.sh. Last, because it changes
# often.
ARG TARGETARCH
COPY bin/solomonar-linux-${TARGETARCH} /usr/local/bin/solomonar
RUN chmod 0755 /usr/local/bin/solomonar \
    && ln -sf solomonar /usr/local/bin/sol

WORKDIR /workspace
VOLUME /workspace

# Entrypoint runs as root (for WireGuard), then drops to the agent user.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]
