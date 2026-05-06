#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

require_file() {
  [ -f "$1" ] || fail "missing $1"
}

require_grep() {
  local pattern="$1"
  local file="$2"
  grep -Eq "$pattern" "$file" || fail "$file does not match: $pattern"
}

reject_grep() {
  local pattern="$1"
  local file="$2"
  if grep -Eq "$pattern" "$file"; then
    fail "$file contains forbidden pattern: $pattern"
  fi
}

require_file docker/.dockerignore
require_grep '(^|/)(config|data)/?$' docker/.dockerignore
require_grep '(^|/)(\*\.env|\.env)$' docker/.dockerignore
require_grep '(^|/)\*\.log$' docker/.dockerignore
require_grep 'data-backup-\*\.tgz' docker/.dockerignore

require_file docker/mine.sh
bash -n docker/mine.sh
require_grep 'cmd_setup\(\)' docker/mine.sh
require_grep 'cmd_mine\(\)' docker/mine.sh
require_grep 'aitongdao\.com' docker/mine.sh
require_grep '/opt/inner-loop\.sh' docker/mine.sh
require_grep 'wallets/default/wallet\.json' docker/mine.sh
reject_grep '\[ -d "\$WALLET_DIR/wallets" \]' docker/mine.sh

bash -n docker/entrypoint.sh
require_grep 'ARDINALS_NO_BANNER' docker/entrypoint.sh
require_grep 'aitongdao\.com' docker/entrypoint.sh
require_grep 'exec /opt/mine\.sh' docker/entrypoint.sh

require_grep 'org\.opencontainers\.image\.url="https://aitongdao\.com"' docker/Dockerfile
require_grep 'SOLVER_WEB_SEARCH=1' docker/Dockerfile
require_grep 'REASONING_EFFORT=low' docker/Dockerfile
require_grep 'COPY mine\.sh /opt/mine\.sh' docker/Dockerfile
require_grep 'CMD \["mine"\]' docker/Dockerfile
require_grep 'rm -rf /root/\.openclaw-wallet /root/\.ardi-agent' docker/Dockerfile

require_grep 'IMAGE_NAME="\$\{IMAGE_NAME:-ardinals-mvp:latest\}"' scripts/01-build.sh

require_grep 'OPENAI_API_KEY=sk-REPLACE_ME' config/docker.env.example
require_grep 'OPENAI_BASE_URL=https://ai\.aitongdao\.com/v1' config/docker.env.example
require_grep 'SOLVER_WEB_SEARCH=1' config/docker.env.example
require_grep 'REASONING_EFFORT=low' config/docker.env.example
reject_grep '^OPENAI_API_KEY=sk-[A-Za-z0-9_-]{20,}$' config/docker.env.example

require_grep 'docker run -d --name ardinals-miner' README.md
require_grep '一键启动挖矿' README.md
require_grep 'SOLVER_WEB_SEARCH=1' README.md
require_grep 'REASONING_EFFORT=low' README.md
require_grep 'relay-onboard\.py' README.md
require_grep 'gasless relay' README.md
require_grep '不等于购买或质押 AWP' README.md
require_grep 'buy-and-stake' README.md
require_grep 'AITONGDAO\.com' README.md
require_grep 'AI 助手' README.md
require_grep 'AITONGDAO\.com 提供相关服务' README.md
reject_grep '@[A-Za-z0-9_]+_eth' README.md

require_grep "process\.env\.REASONING_EFFORT \|\| 'low'" docker/solver.mjs
reject_grep "minimal" docker/solver.mjs

if grep -RIE 'sk-[A-Za-z0-9_-]{20,}|@[A-Za-z0-9_]+_eth|KYA_HANDLE|PERSONAL_AGENT_ADDRESS' docker scripts/01-build.sh config/docker.env.example README.md SECURITY.md .gitignore; then
  fail "public release files contain private-looking material"
fi

echo "public image release checks passed"
