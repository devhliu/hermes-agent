FROM python:3.11-slim

ARG USE_CN_MIRROR=1
ARG DEBIAN_FRONTEND=noninteractive
ARG NODE_VERSION=22
ARG INSTALL_NODE_DEPS=1
ARG INSTALL_PLAYWRIGHT=1

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    TZ=Asia/Shanghai \
    HERMES_HOME=/root/.hermes \
    INSTALL_DIR=/app \
    UV_LINK_MODE=copy \
    PATH="/app/venv/bin:/root/.local/bin:/root/.cargo/bin:${PATH}"

WORKDIR /app

# System deps used by scripts/install.sh (git, build tools, ffmpeg, ripgrep, etc.).
RUN set -eux; \
    if [ "$USE_CN_MIRROR" = "1" ]; then \
      [ -f /etc/apt/sources.list.d/debian.sources ] && \
      sed -i 's|deb.debian.org|mirrors.tuna.tsinghua.edu.cn|g; s|security.debian.org|mirrors.tuna.tsinghua.edu.cn|g' /etc/apt/sources.list.d/debian.sources || true; \
      [ -f /etc/apt/sources.list ] && \
      sed -i 's|deb.debian.org|mirrors.tuna.tsinghua.edu.cn|g; s|security.debian.org|mirrors.tuna.tsinghua.edu.cn|g' /etc/apt/sources.list || true; \
    fi; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      ffmpeg \
      ripgrep \
      tzdata \
      xz-utils \
      build-essential \
      python3-dev \
      libffi-dev; \
    ln -snf /usr/share/zoneinfo/$TZ /etc/localtime; \
    echo "$TZ" > /etc/timezone; \
    rm -rf /var/lib/apt/lists/*

# Install uv first (scripts/install.sh behavior), with fallback if installer URL is blocked.
RUN set -eux; \
    if ! command -v uv >/dev/null 2>&1; then \
      if curl -fsSL https://astral.sh/uv/install.sh -o /tmp/uv-install.sh; then \
        sh /tmp/uv-install.sh || true; \
      fi; \
      rm -f /tmp/uv-install.sh; \
      if ! command -v uv >/dev/null 2>&1; then \
        if [ "$USE_CN_MIRROR" = "1" ]; then \
          python -m pip install --no-cache-dir -i https://pypi.tuna.tsinghua.edu.cn/simple uv; \
        else \
          python -m pip install --no-cache-dir uv; \
        fi; \
      fi; \
      if ! command -v uv >/dev/null 2>&1 && python -m uv --version >/dev/null 2>&1; then \
        printf '%s\n' '#!/bin/sh' 'exec python -m uv "$@"' > /usr/local/bin/uv; \
        chmod +x /usr/local/bin/uv; \
      fi; \
    fi; \
    uv --version; \
    uv python find 3.11 >/dev/null || uv python install 3.11

# Install Node.js v22 (scripts/install.sh behavior), mirror-aware for CN.
RUN set -eux; \
    arch="$(uname -m)"; \
    case "$arch" in \
      x86_64) node_arch="x64" ;; \
      aarch64|arm64) node_arch="arm64" ;; \
      armv7l) node_arch="armv7l" ;; \
      *) echo "Unsupported architecture: $arch" && exit 1 ;; \
    esac; \
    if [ "$USE_CN_MIRROR" = "1" ]; then \
      index_json="https://npmmirror.com/mirrors/node/index.json"; \
      node_base="https://npmmirror.com/mirrors/node"; \
    else \
      index_json="https://nodejs.org/dist/index.json"; \
      node_base="https://nodejs.org/dist"; \
    fi; \
    node_ver="$(NODE_INDEX_JSON="${index_json}" NODE_MAJOR="v${NODE_VERSION}." python -c "import json, os, urllib.request; rows=json.load(urllib.request.urlopen(os.environ['NODE_INDEX_JSON'])); major=os.environ['NODE_MAJOR']; print(next((r.get('version','') for r in rows if r.get('version','').startswith(major)), ''), end='')")"; \
    if [ -z "$node_ver" ] && [ "$USE_CN_MIRROR" = "1" ]; then \
      index_json="https://nodejs.org/dist/index.json"; \
      node_base="https://nodejs.org/dist"; \
      node_ver="$(NODE_INDEX_JSON="${index_json}" NODE_MAJOR="v${NODE_VERSION}." python -c "import json, os, urllib.request; rows=json.load(urllib.request.urlopen(os.environ['NODE_INDEX_JSON'])); major=os.environ['NODE_MAJOR']; print(next((r.get('version','') for r in rows if r.get('version','').startswith(major)), ''), end='')")"; \
    fi; \
    [ -n "$node_ver" ]; \
    tarball="node-${node_ver}-linux-${node_arch}.tar.xz"; \
    tarball_url="${node_base}/${node_ver}/${tarball}"; \
    if ! curl -fsSL "${tarball_url}" -o /tmp/node.tar; then \
      tarball="node-${node_ver}-linux-${node_arch}.tar.gz"; \
      tarball_url="${node_base}/${node_ver}/${tarball}"; \
      curl -fsSL "${tarball_url}" -o /tmp/node.tar; \
    fi; \
    mkdir -p /tmp/node; \
    tar -xf /tmp/node.tar -C /tmp/node --strip-components=1; \
    cp -a /tmp/node/. /usr/local/; \
    rm -rf /tmp/node /tmp/node.tar; \
    node --version; \
    npm --version

# Configure package mirrors before dependency installation.
RUN set -eux; \
    if [ "$USE_CN_MIRROR" = "1" ]; then \
      mkdir -p /etc/pip; \
      printf "[global]\nindex-url = https://pypi.tuna.tsinghua.edu.cn/simple\ntrusted-host = pypi.tuna.tsinghua.edu.cn\n" > /etc/pip.conf; \
      npm config set registry https://registry.npmmirror.com; \
    fi

COPY . .

# setup_venv + install_deps + copy_config_templates from scripts/install.sh.
RUN set -eux; \
    uv venv venv --python 3.11; \
    export VIRTUAL_ENV=/app/venv; \
    if [ "$USE_CN_MIRROR" = "1" ]; then \
      UV_PIP_INDEX="--index-url https://pypi.tuna.tsinghua.edu.cn/simple"; \
    else \
      UV_PIP_INDEX=""; \
    fi; \
    uv pip install ${UV_PIP_INDEX} -e ".[all]" || uv pip install ${UV_PIP_INDEX} -e "."; \
    mkdir -p "$HERMES_HOME"/{cron,sessions,logs,pairing,hooks,image_cache,audio_cache,memories,skills,whatsapp/session}; \
    if [ ! -f "$HERMES_HOME/.env" ]; then \
      [ -f /app/.env.example ] && cp /app/.env.example "$HERMES_HOME/.env" || touch "$HERMES_HOME/.env"; \
    fi; \
    if [ ! -f "$HERMES_HOME/config.yaml" ] && [ -f /app/cli-config.yaml.example ]; then \
      cp /app/cli-config.yaml.example "$HERMES_HOME/config.yaml"; \
    fi; \
    if [ ! -f "$HERMES_HOME/SOUL.md" ]; then \
      printf '%s\n' \
        '# Hermes Agent Persona' \
        '' \
        '<!--' \
        'This file defines the agent'\''s personality and tone.' \
        'Edit this file to customize how Hermes communicates.' \
        '-->' > "$HERMES_HOME/SOUL.md"; \
    fi; \
    mkdir -p /root/.local/bin; \
    ln -sf /app/venv/bin/hermes /root/.local/bin/hermes; \
    ln -sf /app/venv/bin/hermes /usr/local/bin/hermes; \
    /app/venv/bin/python /app/tools/skills_sync.py || { \
      [ -d /app/skills ] && cp -rn /app/skills/* "$HERMES_HOME/skills/" || true; \
    }

# install_node_deps from scripts/install.sh (+ lockfile-aware installs).
RUN set -eux; \
    if [ "$INSTALL_NODE_DEPS" = "1" ] && [ -f /app/package.json ]; then \
      if [ -f /app/package-lock.json ]; then npm ci --silent; else npm install --silent; fi; \
      if [ "$INSTALL_PLAYWRIGHT" = "1" ]; then \
        if [ "$USE_CN_MIRROR" = "1" ]; then \
          PLAYWRIGHT_DOWNLOAD_HOST=https://npmmirror.com/mirrors/playwright npx playwright install --with-deps chromium || npx playwright install --with-deps chromium; \
        else \
          npx playwright install --with-deps chromium; \
        fi; \
      fi; \
    fi; \
    if [ "$INSTALL_NODE_DEPS" = "1" ] && [ -f /app/scripts/whatsapp-bridge/package.json ]; then \
      cd /app/scripts/whatsapp-bridge; \
      if [ -f package-lock.json ]; then npm ci --silent; else npm install --silent; fi; \
    fi

CMD ["hermes"]
