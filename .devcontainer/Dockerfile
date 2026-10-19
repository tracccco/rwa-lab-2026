# Toolchain image for Codespaces / Dev Container.
#
# Toolchain only, **no source COPY**: the devcontainer convention is that the source is
# mounted in (Codespaces mounts it at /workspaces/<repo>), and the image only has to
# provide forge/cast/anvil/make.
# Version numbers live in scripts/install-foundry-cn.sh; to change a version, change it there.
#
# Students do not need to read this file. Its only purpose is to let Windows students
# without WSL2 run make test in the browser (GitHub Codespaces -> "Create codespace on main").

FROM debian:bookworm-slim

# From mainland China, switching APT_MIRROR to mirrors.tuna.tsinghua.edu.cn is much faster.
# Codespaces machines sit outside China, so the default deb.debian.org is fine.
ARG APT_MIRROR=deb.debian.org
ARG FOUNDRY_VERSION=v1.8.3
ARG MIRROR_PREFIX=https://gh-proxy.com/

ENV DEBIAN_FRONTEND=noninteractive

RUN if [ "$APT_MIRROR" != "deb.debian.org" ]; then \
      for f in /etc/apt/sources.list /etc/apt/sources.list.d/debian.sources; do \
        [ -f "$f" ] && sed -i "s|deb.debian.org|${APT_MIRROR}|g" "$f"; \
      done; \
    fi \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl tar git make \
 && rm -rf /var/lib/apt/lists/*

COPY scripts/install-foundry-cn.sh /tmp/install-foundry-cn.sh
RUN FOUNDRY_VERSION="${FOUNDRY_VERSION}" \
    MIRROR_PREFIX="${MIRROR_PREFIX}" \
    FOUNDRY_BIN_DIR=/usr/local/bin \
    bash /tmp/install-foundry-cn.sh \
 && rm -f /tmp/install-foundry-cn.sh

# Prove at build time that all four binaries are present, rather than letting a student
# open Codespaces and discover anvil is missing
RUN forge --version && cast --version && anvil --version
