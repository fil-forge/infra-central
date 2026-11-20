#!/usr/bin/env bash
# Read the production wallets' balances on Filecoin Calibration.
# Requires Foundry's cast. Excludes USDFC deposited into FilecoinPay.
set -euo pipefail

RPC_URL=https://api.calibration.node.glif.io/rpc/v1
USDFC=0xb3042734b608a1B16e9e86B374A3f3e389B4cDf0

command -v cast >/dev/null || { echo "Foundry's cast is required." >&2; exit 1; }

for role in delegator payer; do
  case "$role" in
    delegator) wallet=0x4E51132eD7000B2241c519cF26909878a448f3a9 ;;
    payer) wallet=0x003D9Df37cCD7EB821975cB749D208743002C87D ;;
  esac

  printf '\n%s: %s\n' "$role" "$wallet"
  printf 'tFIL:  '
  cast balance "$wallet" --ether --rpc-url "$RPC_URL"

  printf 'USDFC: '
  raw_balance=$(cast call "$USDFC" \
    'balanceOf(address)(uint256)' "$wallet" --rpc-url "$RPC_URL")
  # cast may append a scientific-notation annotation. Both assets use 18 decimals.
  cast from-wei "${raw_balance%% *}" ether
done
