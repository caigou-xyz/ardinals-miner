#!/usr/bin/env bash
set -euo pipefail

WALLET_DIR="${ARDINALS_WALLET_DIR:-/root/.openclaw-wallet}"
AGENT_DIR="${ARDINALS_AGENT_DIR:-/root/.ardi-agent}"
SPONSOR_URL="${AITONGDAO_URL:-https://aitongdao.com}"

print_banner() {
  if [ "${ARDINALS_NO_BANNER:-0}" = "1" ] || [ "${ARDINALS_BANNER_PRINTED:-0}" = "1" ]; then
    return
  fi
  cat <<EOF
Ardinals miner
OpenAI-compatible endpoint sponsor: ${SPONSOR_URL}
EOF
  export ARDINALS_BANNER_PRINTED=1
}

wallet_exists() {
  [ -s "$WALLET_DIR/wallets.json" ] || [ -s "$WALLET_DIR/wallets/default/wallet.json" ]
}

require_openai_env() {
  if [ -z "${OPENAI_API_KEY:-}" ]; then
    echo "FATAL: OPENAI_API_KEY is required. Pass it with --env-file or -e OPENAI_API_KEY=..." >&2
    exit 64
  fi
}

show_address() {
  echo "Agent wallet address:"
  awp-wallet --pretty receive
}

cmd_setup() {
  print_banner
  mkdir -p "$WALLET_DIR" "$AGENT_DIR"

  if wallet_exists; then
    echo "Wallet state already exists in $WALLET_DIR"
  else
    echo "Initializing a new agent wallet in $WALLET_DIR ..."
    awp-wallet --pretty setup
  fi

  echo ""
  show_address
  cat <<EOF

Next steps before mining can succeed:
1. Fund this address with Base mainnet ETH for gas.
2. Complete the project's KYA flow for your own account.
3. Start the miner with the same wallet volume.
EOF
}

cmd_preflight() {
  print_banner
  require_openai_env
  exec ardi-agent preflight
}

cmd_once() {
  print_banner
  require_openai_env
  mkdir -p "$WALLET_DIR" "$AGENT_DIR"

  if ! wallet_exists; then
    echo "No wallet state found. Run 'setup' first with the same wallet volume." >&2
    exit 64
  fi

  exec /opt/cycle.sh
}

cmd_mine() {
  print_banner
  require_openai_env
  mkdir -p "$WALLET_DIR" "$AGENT_DIR"

  if ! wallet_exists; then
    echo "No wallet state found. Running one-time setup first."
    cmd_setup
    echo ""
    echo "Wallet created. Fund and verify it, then rerun the same docker run command to start mining." >&2
    exit 64
  fi

  echo "Starting Ardinals mining loop ..."
  exec /opt/inner-loop.sh
}

cmd_help() {
  print_banner
  cat <<EOF
Usage:
  mine       Start the long-running mining loop (default)
  setup      Initialize or print the agent wallet address
  once       Run one mining cycle
  preflight  Run ardi-agent preflight checks
  help       Show this help

Sponsor:
  ${SPONSOR_URL}
EOF
}

case "${1:-mine}" in
  setup) shift; cmd_setup "$@" ;;
  mine) shift; cmd_mine "$@" ;;
  once|cycle) shift; cmd_once "$@" ;;
  preflight) shift; cmd_preflight "$@" ;;
  help|-h|--help) cmd_help ;;
  *) exec "$@" ;;
esac
