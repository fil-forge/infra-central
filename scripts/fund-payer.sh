#!/usr/bin/env bash
# Move USDFC into the payer's FilecoinPay account so proof set creation can lock
# up against it.
#
# The signing happens inside the provision Lambda, in AWS. This script only
# invokes it. That is the difference from smelt's scripts/staging-fund-payer.sh,
# which reads the payer key out of 1Password and signs with `cast` on the
# operator's machine — here the key never leaves AWS and never reaches a disk.
#
# Two invocations, always in this order:
#   1. without confirmation, which reads the chain and prints what would happen
#   2. after you approve it, with confirmation, which signs and broadcasts
#
# Usage:
#   scripts/fund-payer.sh [--stage dev] [--deposit 3] [--yes]
#
# Options:
#   --stage             stage to fund                     (default: dev)
#   --deposit           USDFC to deposit                  (default: 3)
#   --lockup-allowance  operator lockup cap, USDFC        (default: 3)
#   --rate-allowance    operator rate cap, USDFC/epoch    (default: 0.1)
#   --max-lockup-period operator period cap, epochs       (default: 86400)
#   --force-deposit     deposit even if the account already holds enough
#   --yes               skip the interactive prompt (for a reviewed pipeline)
#
# Prerequisites:
#   - AWS credentials for the account holding the stage
#   - the payer wallet already holds >= the deposit amount in USDFC; faucet it at
#     https://forest-explorer.chainsafe.dev/faucet/calibnet_usdfc (10/day cap)
set -euo pipefail

STAGE="${STAGE:-dev}"
DEPOSIT="${DEPOSIT:-3}"
LOCKUP_ALLOWANCE="${LOCKUP_ALLOWANCE:-3}"
RATE_ALLOWANCE="${RATE_ALLOWANCE:-0.1}"
MAX_LOCKUP_PERIOD="${MAX_LOCKUP_PERIOD:-86400}"
FORCE_DEPOSIT=false
ASSUME_YES=false

while [ $# -gt 0 ]; do
  case "$1" in
    --stage)             STAGE="$2"; shift 2 ;;
    --deposit)           DEPOSIT="$2"; shift 2 ;;
    --lockup-allowance)  LOCKUP_ALLOWANCE="$2"; shift 2 ;;
    --rate-allowance)    RATE_ALLOWANCE="$2"; shift 2 ;;
    --max-lockup-period) MAX_LOCKUP_PERIOD="$2"; shift 2 ;;
    --force-deposit)     FORCE_DEPOSIT=true; shift ;;
    --yes|-y)            ASSUME_YES=true; shift ;;
    -h|--help)           sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)                   echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

command -v aws >/dev/null || { echo "ERROR: aws CLI not found in PATH" >&2; exit 1; }
command -v jq  >/dev/null || { echo "ERROR: jq not found in PATH" >&2; exit 1; }

FUNCTION="forge-${STAGE}-provision"

# invoke <confirm> — call the fund phase and print its JSON response. A Lambda
# error is reported as a successful invocation with FunctionError set, so that
# is checked separately.
invoke() {
  local confirm="$1" payload response out
  payload="$(jq -nc \
    --argjson confirm "$confirm" \
    --arg deposit "$DEPOSIT" \
    --arg lockup "$LOCKUP_ALLOWANCE" \
    --arg rate "$RATE_ALLOWANCE" \
    --argjson period "$MAX_LOCKUP_PERIOD" \
    --argjson force "$FORCE_DEPOSIT" \
    '{phase:"fund", confirm:$confirm, deposit:$deposit, lockup_allowance:$lockup,
      rate_allowance:$rate, max_lockup_period:$period, force_deposit:$force}')"

  out="$(mktemp)"
  trap 'rm -f "$out"' RETURN

  response="$(aws lambda invoke \
    --function-name "$FUNCTION" \
    --cli-binary-format raw-in-base64-out \
    --payload "$payload" \
    --cli-read-timeout 900 \
    "$out")"

  if [ "$(jq -r '.FunctionError // empty' <<<"$response")" != "" ]; then
    echo "ERROR: the fund phase failed:" >&2
    jq -r '.errorMessage // .' "$out" >&2
    return 1
  fi

  cat "$out"
}

echo "=== Fund the ${STAGE} payer ==="
echo "  Lambda:   $FUNCTION"
echo "  Deposit:  $DEPOSIT USDFC"
echo "  Lockup:   $LOCKUP_ALLOWANCE USDFC cap at $RATE_ALLOWANCE USDFC/epoch, $MAX_LOCKUP_PERIOD epochs"
echo

echo "Reading the chain (nothing is signed yet)…"
plan="$(invoke false)"

jq -r '
  "  Payer:          \(.fund_plan.payer)",
  "  Chain:          \(.fund_plan.chain_id)",
  "  Wallet balance: \(.fund_plan.wallet_balance_usdfc) USDFC",
  "  Account funds:  \(.fund_plan.account_funds_usdfc) USDFC",
  "",
  "Transactions to broadcast:",
  (.fund_plan.actions[] | "  - \(.)")
' <<<"$plan"
echo

if [ "$ASSUME_YES" != true ]; then
  echo "These transactions move real funds and cannot be undone."
  read -r -p "Type 'fund' to proceed: " reply
  [ "$reply" = "fund" ] || { echo "Aborted; nothing was signed."; exit 1; }
  echo
fi

echo "Broadcasting (Filecoin blocks are ~30s; this waits for each receipt)…"
result="$(invoke true)"

jq -r '
  (.fund_result.transactions[] | "  ✓ \(.action)  \(.hash)  block \(.block)"),
  "",
  "FilecoinPay account funds now: \(.fund_result.account_funds_after_usdfc) USDFC"
' <<<"$result"
