#!/usr/bin/env bash
# 单 epoch 完整流程 (并发版)
# - solver: 1 次 GPT 调用答全部 (已并发)
# - commit: 5 个 ardi-agent commit 并发, awp-wallet send-tx.lock 内部 serialize nonce
# - reveal: 同 epoch 的所有 commits 并发 reveal
# - inscribe: revealed winners 并发 inscribe
# - 容错: 永不在 commit 后 abort 而不 reveal
# - 过滤: 只处理本 epoch 的 commits, 不碰过期 epoch
set -uo pipefail
LOG_DIR="${LOG_DIR:-/root/.ardi-agent/cycle-logs}"
mkdir -p "$LOG_DIR"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
EPOCH_LOG="$LOG_DIR/$TS.log"
exec > >(tee -a "$EPOCH_LOG") 2>&1

DRY_COMMITS="${DRY_COMMITS:-5}"
SKIP_PREFLIGHT="${SKIP_PREFLIGHT:-1}"
VAULT_ADDRESS="${VAULT_ADDRESS:-}"

log() { echo "[$(date -u +%H:%M:%SZ)] $*"; }

log "=== cycle start (DRY_COMMITS=$DRY_COMMITS skip_preflight=$SKIP_PREFLIGHT vault=${VAULT_ADDRESS:-none}) ==="

# 一次性 resolve agent 地址(显式 --staker 防 AWP RPC 抖动)
AGENT_ADDR="${AGENT_ADDR:-$(ardi-agent gas 2>&1 | sed -n '/^{/,$p' | jq -r '.data.address // empty' 2>/dev/null)}"
log "agent_addr=$AGENT_ADDR"

# Step 1: 拿 context
log "context..."
if ! ardi-agent context > /tmp/context.json 2>/tmp/context.err; then
  log "FATAL: context failed"
  cat /tmp/context.err
  exit 1
fi
EPOCH_ID=$(jq -r '.data.epochId // .data.epoch_id // empty' /tmp/context.json)
RIDDLES_COUNT=$(jq -r '.data.riddles | length' /tmp/context.json 2>/dev/null || echo 0)
COMMIT_DEADLINE=$(jq -r '.data.commitDeadline // 0' /tmp/context.json 2>/dev/null || echo 0)
NOW=$(date +%s)
TIME_LEFT=$((COMMIT_DEADLINE - NOW))
log "epoch=$EPOCH_ID riddles=$RIDDLES_COUNT commit_deadline=$COMMIT_DEADLINE remaining=${TIME_LEFT}s"

if [ -z "$EPOCH_ID" ] || [ "$RIDDLES_COUNT" = "0" ]; then
  log "no epoch open right now — exiting"
  exit 2
fi

if [ "$TIME_LEFT" -lt 25 ]; then
  log "WARN: only ${TIME_LEFT}s until deadline, may not finish"
fi

# Step 2: solver (单次 API 已经内部并发)
log "solver (GPT-5.5)..."
jq '{ riddles: .data.riddles }' /tmp/context.json | node /opt/solver/solver.mjs > /tmp/top5.json 2> /tmp/solver.err
SOLVER_RC=$?
if [ $SOLVER_RC -ne 0 ] || [ ! -s /tmp/top5.json ]; then
  log "FATAL: solver failed (rc=$SOLVER_RC)"
  cat /tmp/solver.err
  exit 1
fi
log "solver: $(jq -c '{total_solved, total_riddles, top5_count: (.top5|length), total_s}' /tmp/top5.json)"

# Step 3: serial commit — each tx waits for the previous to land so
# the next one can read the incremented nonce. Cross-process awp-wallet
# locks don't exist, so parallel collides on nonce (~20% loss observed).
log "committing top-$DRY_COMMITS sequentially..."
declare -a COMMIT_WIDS
mkdir -p /tmp/commits
rm -f /tmp/commits/*.json /tmp/commits/*.rc
COMMIT_ENTRIES="$(jq -c ".top5[0:$DRY_COMMITS][]" /tmp/top5.json)"
i=0
while IFS= read -r entry; do
  [ -z "$entry" ] && continue
  WORD_ID=$(echo "$entry" | jq -r '.word_id')
  ANSWER=$(echo "$entry" | jq -r '.answer')
  CONF=$(echo "$entry" | jq -r '.confidence')
  log "  commit word_id=$WORD_ID answer='$ANSWER' conf=$CONF"
  COMMIT_WIDS[$i]="$WORD_ID"
  ardi-agent commit --word-id "$WORD_ID" --answer "$ANSWER" --staker "$AGENT_ADDR" \
    > /tmp/commits/$WORD_ID.raw 2>&1
  RC=$?
  echo $RC > /tmp/commits/$WORD_ID.rc
  sed -n '/^{/,$p' /tmp/commits/$WORD_ID.raw > /tmp/commits/$WORD_ID.json
  i=$((i+1))
done <<< "$COMMIT_ENTRIES"

COMMIT_COUNT=0
ALREADY_COUNT=0
for WID in "${COMMIT_WIDS[@]}"; do
  RC=$(cat /tmp/commits/$WID.rc 2>/dev/null || echo 1)
  if [ "$RC" = "0" ] && grep -q '"status": "ok"' /tmp/commits/$WID.json 2>/dev/null; then
    COMMIT_COUNT=$((COMMIT_COUNT+1))
    log "  ✓ commit $WID OK"
  elif grep -q "Already committed" /tmp/commits/$WID.json 2>/dev/null; then
    ALREADY_COUNT=$((ALREADY_COUNT+1))
    log "  ✓ commit $WID already on chain (recovered)"
  else
    ERR=$(jq -r '.message // .error.message // "unknown"' /tmp/commits/$WID.json 2>/dev/null | head -c 120)
    [ -z "$ERR" ] && ERR=$(head -c 200 /tmp/commits/$WID.raw 2>/dev/null | tr '\n' ' ')
    [ -z "$ERR" ] && ERR="(empty output)"
    log "  ✗ commit $WID FAILED: $ERR"
  fi
done
TOTAL_USABLE=$((COMMIT_COUNT + ALREADY_COUNT))
log "committed $COMMIT_COUNT new + $ALREADY_COUNT already-on-chain = $TOTAL_USABLE/$DRY_COMMITS usable"

if [ "$TOTAL_USABLE" -eq 0 ]; then
  log "no usable commits, skipping reveal/inscribe"
  exit 0
fi

# Step 4: 等到 commit_deadline + 35s grace
TARGET_REVEAL_TS=$((COMMIT_DEADLINE + 35))
NOW2=$(date +%s)
WAIT_SEC=$((TARGET_REVEAL_TS - NOW2))
if [ "$WAIT_SEC" -gt 0 ]; then
  log "sleeping ${WAIT_SEC}s until reveal eligible..."
  sleep "$WAIT_SEC"
fi

# Step 5: ⚡ 并发 reveal — 只 reveal 本 epoch 的 commits
log "revealing epoch=$EPOCH_ID commits in parallel..."
PENDING_NOW=$(ardi-agent commits 2>/dev/null)
TO_REVEAL_WIDS=$(echo "$PENDING_NOW" | jq -r ".data.pending[]? | select(.epoch_id==$EPOCH_ID and .status==\"committed\" and .reveal_tx==null) | .word_id")

mkdir -p /tmp/reveals
rm -f /tmp/reveals/*.json /tmp/reveals/*.rc
REVEAL_PIDS=()
declare -a REVEAL_WIDS
i=0
for WID in $TO_REVEAL_WIDS; do
  log "  spawn reveal word_id=$WID"
  REVEAL_WIDS[$i]="$WID"
  (
    # 重试 2 次 (publishAnswers 延迟 / 临时 RPC 错误)
    for try in 1 2 3; do
      ardi-agent reveal --epoch "$EPOCH_ID" --word-id "$WID" > /tmp/reveals/$WID.json 2>&1
      if grep -q '"status": "ok"' /tmp/reveals/$WID.json; then
        echo 0 > /tmp/reveals/$WID.rc
        exit 0
      fi
      [ $try -lt 3 ] && sleep 8
    done
    echo 1 > /tmp/reveals/$WID.rc
  ) &
  REVEAL_PIDS+=($!)
  i=$((i+1))
done

if [ ${#REVEAL_PIDS[@]} -gt 0 ]; then
  wait "${REVEAL_PIDS[@]}" 2>/dev/null
fi

REVEAL_COUNT=0
for WID in "${REVEAL_WIDS[@]}"; do
  if [ "$(cat /tmp/reveals/$WID.rc 2>/dev/null)" = "0" ]; then
    REVEAL_COUNT=$((REVEAL_COUNT+1))
    log "  ✓ reveal $WID OK"
  else
    log "  ✗ reveal $WID FAILED"
  fi
done
log "revealed $REVEAL_COUNT/${#REVEAL_WIDS[@]}"

# Step 6: 等 VRF (Chainlink 通常 1-3 min, 给充足时间)
log "waiting 60s for VRF..."
sleep 60

# Step 7: ⚡ 并发 inscribe — 只本 epoch + 已 revealed + 未 inscribed
log "checking inscribe candidates for epoch=$EPOCH_ID..."
INSCRIBE_WIDS=$(ardi-agent commits 2>/dev/null | jq -r ".data.pending[]? | select(.epoch_id==$EPOCH_ID and .reveal_tx != null and .inscribe_tx == null) | .word_id")

mkdir -p /tmp/inscribes
rm -f /tmp/inscribes/*.json /tmp/inscribes/*.rc
INSCRIBE_PIDS=()
declare -a INSCRIBE_WIDS_ARR
i=0
for WID in $INSCRIBE_WIDS; do
  log "  spawn inscribe word_id=$WID"
  INSCRIBE_WIDS_ARR[$i]="$WID"
  (
    # 重试 6 次 → 总等 ~6 min (Chainlink VRF 最坏 10 min, 折中)
    for try in 1 2 3 4 5 6; do
      ardi-agent inscribe --epoch "$EPOCH_ID" --word-id "$WID" > /tmp/inscribes/$WID.json 2>&1
      # 真赢: data.token_id 非空
      if grep -q '"token_id":' /tmp/inscribes/$WID.json && ! grep -q '"token_id": null' /tmp/inscribes/$WID.json; then
        echo 0 > /tmp/inscribes/$WID.rc
        exit 0
      fi
      # ⚠️ VRF pending 优先检查 (winner=0x0 占位会撞下面的 loss regex)
      if grep -q "VRF pending\|vrf_state.*pending\|wait_vrf" /tmp/inscribes/$WID.json; then
        [ $try -lt 6 ] && sleep 60
        continue
      fi
      # 真输: 显式 "Better luck" 或 winner 是完整 40-hex 地址但不等于我们
      # (用 jq 严格判断: data.winner 必须是 0x + 40 hex,且 != AGENT_ADDR)
      WIN_REAL=$(jq -r '.data.winner // empty' /tmp/inscribes/$WID.json 2>/dev/null)
      if [ -n "$WIN_REAL" ] && echo "$WIN_REAL" | grep -qE '^0x[0-9a-fA-F]{40}$'; then
        if [ "${WIN_REAL,,}" = "${AGENT_ADDR,,}" ]; then
          # 我赢了但还没 mint? 继续重试
          [ $try -lt 6 ] && sleep 30
          continue
        else
          echo 2 > /tmp/inscribes/$WID.rc
          exit 0
        fi
      fi
      if grep -qi "Better luck\|not us\|not the winner\|marked lost\|weren't picked\|nothing to inscribe" /tmp/inscribes/$WID.json; then
        echo 2 > /tmp/inscribes/$WID.rc
        exit 0
      fi
      # 其他错误,但仍可能 transient,再试一次
      [ $try -lt 6 ] && sleep 30
    done
    echo 1 > /tmp/inscribes/$WID.rc
  ) &
  INSCRIBE_PIDS+=($!)
  i=$((i+1))
done

if [ ${#INSCRIBE_PIDS[@]} -gt 0 ]; then
  wait "${INSCRIBE_PIDS[@]}" 2>/dev/null
fi

INSCRIBE_COUNT=0
for WID in "${INSCRIBE_WIDS_ARR[@]}"; do
  RC=$(cat /tmp/inscribes/$WID.rc 2>/dev/null || echo 1)
  case "$RC" in
    0)
      INSCRIBE_COUNT=$((INSCRIBE_COUNT+1))
      ATTRS=$(jq -c '.data | {token_id, power, element, language: .language_id, max_durability, current_durability}' /tmp/inscribes/$WID.json 2>/dev/null || echo "{}")
      log "  🪪 INSCRIBED $WID $ATTRS"
      ;;
    2)
      # 输了 VRF — 查 pool size 帮助分析
      WINNER=$(jq -r '.data.winner // "?"' /tmp/inscribes/$WID.json 2>/dev/null)
      POOL=$(curl -s -X POST https://mainnet.base.org -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","method":"eth_call","params":[{"to":"0xA57d8E6646E063FFd6eae579d4f327b689dA5DC3","data":"0xf23112dd'"$(printf '%064x' $EPOCH_ID)$(printf '%064x' $WID)"'"},"latest"],"id":1}' 2>/dev/null | jq -r '.result' 2>/dev/null)
      WIN_FMT="${WINNER:0:6}...${WINNER: -8}"
      if [ -n "$POOL" ] && [ "$POOL" != "null" ]; then
        POOL_DEC=$((16#${POOL:2}))
        log "  • not winner $WID (pool=$POOL_DEC, win rate $(awk "BEGIN{printf \"%.2f\", 100/$POOL_DEC}")%, winner=$WIN_FMT)"
      else
        log "  • not winner $WID (winner=$WIN_FMT)"
      fi
      ;;
    3) log "  ✗ inscribe $WID error";;
    *) log "  ? inscribe $WID timeout";;
  esac
done

# Step 8: ⭐⭐⭐ Transfer-mint loop (HANDOFF §6.1) + Forge HOLD 策略
# 不全转: power >= POWER_HOLD_THRESHOLD (默认 70, legendary+) 留 agent 攒 5 个 Forge
# Common / uncommon / rare 转 vault 等卖 OR Phase 2 fuse fodder
POWER_HOLD_THRESHOLD="${POWER_HOLD_THRESHOLD:-70}"
if [ -n "$VAULT_ADDRESS" ]; then
  log "transfer-mint loop: checking holdings (hold_threshold=power>=$POWER_HOLD_THRESHOLD)..."

  # 拉 agent 持有的 NFT + 各 token 的 power
  COMMITS_DATA=$(ardi-agent commits 2>/dev/null)
  HELD_INFO=$(echo "$COMMITS_DATA" | jq -c '[.data.pending[]? | select(.token_id != null and .inscribe_tx != null) | {token_id, power, element, lang: .language_id}]' 2>/dev/null || echo "[]")
  HELD_COUNT=$(echo "$HELD_INFO" | jq 'length' 2>/dev/null || echo 0)
  log "  agent holds $HELD_COUNT NFT: $(echo "$HELD_INFO" | jq -c '.')"

  if [ "$HELD_COUNT" -ge 4 ]; then
    # 分流: low-power → vault, high-power → 留下 (Forge)
    LOW_TOKENS=$(echo "$HELD_INFO" | jq -r ".[] | select((.power // 0) < $POWER_HOLD_THRESHOLD) | .token_id")
    HIGH_TOKENS=$(echo "$HELD_INFO" | jq -r ".[] | select((.power // 0) >= $POWER_HOLD_THRESHOLD) | .token_id")
    LOW_N=$(echo "$LOW_TOKENS" | grep -c . || echo 0)
    HIGH_N=$(echo "$HIGH_TOKENS" | grep -c . || echo 0)
    log "  → transfer $LOW_N low-power to vault; HOLD $HIGH_N high-power for Forge"

    if [ "$LOW_N" -gt 0 ]; then
      TRANSFER_PIDS=()
      for TOKEN_ID in $LOW_TOKENS; do
        [ -z "$TOKEN_ID" ] && continue
        ( ardi-agent transfer --token-id "$TOKEN_ID" --to "$VAULT_ADDRESS" > /tmp/transfer-$TOKEN_ID.json 2>&1 ) &
        TRANSFER_PIDS+=($!)
      done
      wait "${TRANSFER_PIDS[@]}" 2>/dev/null
      for TOKEN_ID in $LOW_TOKENS; do
        [ -z "$TOKEN_ID" ] && continue
        if grep -q '"status": "ok"' /tmp/transfer-$TOKEN_ID.json 2>/dev/null; then
          log "    ✓ transferred $TOKEN_ID (low-power → vault)"
        else
          log "    ✗ transfer $TOKEN_ID failed"
        fi
      done
    fi

    if [ "$HIGH_N" -ge 5 ]; then
      log "  ⚡ FORGE READY: have $HIGH_N high-power tokens (Phase 2 fuse candidate set)"
    fi
  fi
fi

log "=== cycle end: epoch=$EPOCH_ID committed=$COMMIT_COUNT revealed=$REVEAL_COUNT inscribed=$INSCRIBE_COUNT ==="
