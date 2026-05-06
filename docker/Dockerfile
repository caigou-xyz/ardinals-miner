FROM node:20-bookworm-slim

LABEL org.opencontainers.image.title="Ardinals Miner" \
    org.opencontainers.image.description="Share-safe Ardinals mining container with one-command startup" \
    org.opencontainers.image.url="https://aitongdao.com"

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=UTC \
    AITONGDAO_URL=https://aitongdao.com

# 系统依赖 (含 python3 给 awp-skill 用, stdlib only)
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl jq git tini coreutils python3 \
    && rm -rf /var/lib/apt/lists/*

# 1) 安装 ardi-agent (按 arch 选)
#    - aarch64 → ardi-agent-linux-aarch64 (glibc, 需要 bookworm 的 glibc 2.36+)
#    - x86_64  → ardi-agent-linux-x86_64-musl (静态)
ARG ARDI_VERSION=latest
RUN set -eux; \
    ARCH=$(uname -m); \
    case "$ARCH" in \
        aarch64) BIN_NAME="ardi-agent-linux-aarch64" ;; \
        x86_64)  BIN_NAME="ardi-agent-linux-x86_64-musl" ;; \
        *) echo "Unsupported arch: $ARCH" >&2; exit 1 ;; \
    esac; \
    URL="https://github.com/awp-worknet/ardi-skill/releases/${ARDI_VERSION}/download/${BIN_NAME}"; \
    echo "Downloading ardi-agent from $URL"; \
    curl -fsSL "$URL" -o /usr/local/bin/ardi-agent; \
    chmod +x /usr/local/bin/ardi-agent; \
    ardi-agent --version || ardi-agent --help | head -1

# 1c) 安装 awp-skill (Python stdlib only, gasless onboard via relayer)
RUN set -eux; \
    git clone --depth 1 https://github.com/awp-core/awp-skill.git /opt/awp-skill; \
    ls /opt/awp-skill/scripts/relay-onboard.py >/dev/null

# 1b) 安装 kya-agent (Rust musl 静态二进制, 仅 EIP-712 签名, 不发 tx)
#     kya-skill 有 aarch64-musl 和 x86_64-musl 两个 Linux 版本
ARG KYA_VERSION=latest
RUN set -eux; \
    ARCH=$(uname -m); \
    case "$ARCH" in \
        aarch64) BIN_NAME="kya-agent-linux-aarch64-musl" ;; \
        x86_64)  BIN_NAME="kya-agent-linux-x86_64-musl" ;; \
        *) echo "Unsupported arch: $ARCH" >&2; exit 1 ;; \
    esac; \
    URL="https://github.com/awp-worknet/kya-skill/releases/${KYA_VERSION}/download/${BIN_NAME}"; \
    echo "Downloading kya-agent from $URL"; \
    curl -fsSL "$URL" -o /usr/local/bin/kya-agent; \
    chmod +x /usr/local/bin/kya-agent; \
    kya-agent --version 2>&1 | head -3 || kya-agent --help 2>&1 | head -3

# 2) 安装 awp-wallet (Node.js, 通过 install.sh + npm link 注册到 /usr/local/bin/awp-wallet)
#    install.sh 会把 profile 写到 /root/.openclaw-wallet/wallets/<profile>/
RUN set -eux; \
    git clone --depth 1 https://github.com/awp-core/awp-wallet.git /opt/awp-wallet; \
    cd /opt/awp-wallet; \
    bash install.sh --no-init --dir /opt/awp-wallet; \
    command -v awp-wallet >/dev/null || { echo "awp-wallet not in PATH after install.sh" >&2; ls -la /usr/local/bin/ | grep -i awp || true; exit 1; }; \
    awp-wallet --version 2>&1 | head -3 || awp-wallet --help 2>&1 | head -3; \
    rm -rf /root/.openclaw-wallet /root/.ardi-agent

# 3) 安装 solver 依赖
COPY package.json /opt/solver/package.json
RUN cd /opt/solver && npm install --omit=dev --no-audit --no-fund

# 4) 应用层脚本 (最后 copy, 利用缓存)
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY mine.sh /opt/mine.sh
COPY cycle.sh /opt/cycle.sh
COPY inner-loop.sh /opt/inner-loop.sh
COPY solver.mjs /opt/solver/solver.mjs
RUN chmod +x /usr/local/bin/entrypoint.sh /opt/mine.sh /opt/cycle.sh /opt/inner-loop.sh

WORKDIR /workspace
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["mine"]
