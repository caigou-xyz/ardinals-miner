#!/usr/bin/env bash
# 容器内长跑 loop: 直接 ardi-agent context 轮询, 不经 docker startup
# 由 host scripts/08-run-daemon.sh 启动 (docker run -d)
set -uo pipefail

POLL_INTERVAL="${POLL_INTERVAL:-5}"     # 容器内轮询 5s
DRY_COMMITS="${DRY_COMMITS:-5}"
VAULT_ADDRESS="${VAULT_ADDRESS:-}"
SKIP_PREFLIGHT="${SKIP_PREFLIGHT:-1}"

LAST_EPOCH=""
CYCLE_COUNT=0

log() { echo "[$(date -u +%H:%M:%SZ)] $*"; }

log "=== inner-loop start (poll=${POLL_INTERVAL}s commits=$DRY_COMMITS vault=${VAULT_ADDRESS:-none}) ==="

while true; do
  # 直接调 ardi-agent context (容器内,无 docker startup)
  CTX=$(ardi-agent context 2>/dev/null || echo '{}')
  RIDDLES=$(echo "$CTX" | jq -r '.data.riddles | length // 0' 2>/dev/null)
  EPOCH=$(echo "$CTX" | jq -r '.data.epochId // .data.epoch_id // empty' 2>/dev/null)
  DEADLINE=$(echo "$CTX" | jq -r '.data.commitDeadline // 0' 2>/dev/null)
  NOW=$(date +%s)

  if [ "$RIDDLES" -gt 0 ] 2>/dev/null && [ -n "$EPOCH" ] && [ "$EPOCH" != "$LAST_EPOCH" ]; then
    LEFT=$((DEADLINE - NOW))
    log "EPOCH OPEN: $EPOCH ($RIDDLES riddles, ${LEFT}s remaining)"

    if [ "$LEFT" -lt 30 ]; then
      log "WARN: < 30s remaining, will try anyway (might miss deadline)"
    fi

    LAST_EPOCH="$EPOCH"
    CYCLE_COUNT=$((CYCLE_COUNT + 1))
    log "→ triggering cycle $CYCLE_COUNT"

    # 直接跑 cycle.sh, 不再 docker run
    DRY_COMMITS=$DRY_COMMITS \
    VAULT_ADDRESS=$VAULT_ADDRESS \
    SKIP_PREFLIGHT=$SKIP_PREFLIGHT \
    /opt/cycle.sh || log "cycle exit non-zero, continuing"

    log "cycle $CYCLE_COUNT done, resuming poll..."
  fi
  sleep "$POLL_INTERVAL"
done
