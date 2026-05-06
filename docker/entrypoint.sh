#!/usr/bin/env bash
# entrypoint: 容器 PID 1 (under tini)
# - exec 任意命令
# - 默认进入 mine 长跑流程
set -euo pipefail

# 健康检查: 关键二进制是否在
command -v ardi-agent >/dev/null || { echo "FATAL: ardi-agent not in PATH"; exit 127; }
command -v awp-wallet >/dev/null || { echo "FATAL: awp-wallet not in PATH"; exit 127; }

# 把 awp-wallet 路径明示告诉 ardi-agent
export AWP_WALLET_BIN="$(command -v awp-wallet)"

# 默认 RPC fallback (如果用户没设)
export ARDI_BASE_RPC="${ARDI_BASE_RPC:-https://mainnet.base.org}"

if [ "${ARDINALS_NO_BANNER:-0}" != "1" ]; then
  echo "Ardinals miner | OpenAI-compatible endpoint sponsor: ${AITONGDAO_URL:-https://aitongdao.com}"
  export ARDINALS_BANNER_PRINTED=1
fi

# 持久化目录权限自检 (bind mount 时所有权可能不对)
for d in /root/.openclaw-wallet /root/.ardi-agent; do
  if [ -d "$d" ] && [ ! -w "$d" ]; then
    echo "WARN: $d not writable" >&2
  fi
done

case "${1:-mine}" in
  mine|setup|once|cycle|preflight|help|-h|--help)
    exec /opt/mine.sh "$@"
    ;;
esac

# exec 用户传入的命令 (or 默认)
exec "$@"
