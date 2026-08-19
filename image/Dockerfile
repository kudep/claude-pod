# claude-pod image — Ubuntu/CUDA base + Node (Claude Code) + uv + build toolchain.
# Built per host so the in-container user matches the host uid/gid/home, which keeps
# bind-mount ownership correct and the project path identical to the host path.
ARG BASE_IMAGE=docker.io/nvidia/cuda:12.6.2-runtime-ubuntu24.04
FROM ${BASE_IMAGE}

ARG HOST_USER=dev
ARG HOST_UID=1000
ARG HOST_GID=1000
ARG HOST_HOME=/home/dev

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    NODE_MAJOR=22 \
    DISABLE_AUTOUPDATER=1

# --- base OS packages + toolchain --------------------------------------------
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl wget gnupg \
        git openssh-client \
        build-essential pkg-config \
        ripgrep jq less vim-tiny \
        locales tini sudo \
        docker.io; \
    rm -rf /var/lib/apt/lists/*

# --- Node.js (Claude Code runtime) -------------------------------------------
# Node 22+: newer Claude Code releases declare engines.node >= 22, and npm silently
# falls back to the newest engine-compatible version — on Node 20 that pinned the pod
# to an old claude even after a --no-cache rebuild.
RUN set -eux; \
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -; \
    apt-get install -y --no-install-recommends nodejs; \
    rm -rf /var/lib/apt/lists/*; \
    npm install -g @anthropic-ai/claude-code

# --- uv (Python manager; pulls project Python on demand) ---------------------
RUN set -eux; \
    curl -LsSf https://astral.sh/uv/install.sh | \
        env UV_INSTALL_DIR=/usr/local/bin INSTALLER_NO_MODIFY_PATH=1 sh; \
    uv --version

# --- non-root user matching the host -----------------------------------------
RUN set -eux; \
    if getent group "${HOST_GID}" >/dev/null; then \
        g="$(getent group "${HOST_GID}" | cut -d: -f1)"; \
        [ "$g" = "${HOST_USER}" ] || groupmod -n "${HOST_USER}" "$g"; \
    else groupadd -g "${HOST_GID}" "${HOST_USER}"; fi; \
    if getent passwd "${HOST_UID}" >/dev/null; then \
        u="$(getent passwd "${HOST_UID}" | cut -d: -f1)"; \
        [ "$u" = "${HOST_USER}" ] || usermod -l "${HOST_USER}" "$u"; \
        usermod -d "${HOST_HOME}" -s /bin/bash -g "${HOST_GID}" "${HOST_USER}"; \
    else useradd -u "${HOST_UID}" -g "${HOST_GID}" -s /bin/bash "${HOST_USER}"; fi; \
    mkdir -p "${HOST_HOME}/.ssh"; \
    chown -R "${HOST_UID}:${HOST_GID}" "${HOST_HOME}"; \
    chmod 700 "${HOST_HOME}/.ssh"; \
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "${HOST_USER}" > /etc/sudoers.d/cpod; \
    chmod 440 /etc/sudoers.d/cpod

COPY entrypoint.sh /usr/local/bin/cpod-entrypoint
RUN chmod +x /usr/local/bin/cpod-entrypoint

USER ${HOST_UID}:${HOST_GID}
ENV HOME=${HOST_HOME}
WORKDIR ${HOST_HOME}

# tini reaps zombies; entrypoint does one-time setup then `sleep infinity`
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/cpod-entrypoint"]
