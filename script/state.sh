#!/usr/bin/env bash
# Reads the live pools and prints what the hook has actually kept for LPs.
set -uo pipefail

RPC="${RPC:-https://sepolia.unichain.org}"
STATE_VIEW=0xc199f1072a74d4e905aba1a84d9a45e2546b6222

source .env

if [[ "${VERNIER_USDC,,}" < "${VERNIER_SYIELD,,}" ]]; then
  C0=$VERNIER_USDC; C1=$VERNIER_SYIELD
else
  C0=$VERNIER_SYIELD; C1=$VERNIER_USDC
fi

poolid() {
  cast keccak "$(cast abi-encode "f(address,address,uint24,int24,address)" "$C0" "$C1" 500 60 "$1")"
}

# cast annotates large numbers with a scientific-notation suffix
num() { sed 's/ \[.*//' | tr -d ' \r'; }

VP=$(poolid "$VERNIER_HOOK")
BP=$(poolid 0x0000000000000000000000000000000000000000)

VG=$(cast call "$STATE_VIEW" "getFeeGrowthGlobals(bytes32)(uint256,uint256)" "$VP" --rpc-url "$RPC")
BG=$(cast call "$STATE_VIEW" "getFeeGrowthGlobals(bytes32)(uint256,uint256)" "$BP" --rpc-url "$RPC")

VG1=$(echo "$VG" | sed -n 2p | num)
BG1=$(echo "$BG" | sed -n 2p | num)
VL=$(cast call "$STATE_VIEW" "getLiquidity(bytes32)(uint128)" "$VP" --rpc-url "$RPC" | num)
BL=$(cast call "$STATE_VIEW" "getLiquidity(bytes32)(uint128)" "$BP" --rpc-url "$RPC" | num)
TICK=$(cast call "$STATE_VIEW" "getSlot0(bytes32)(uint160,int24,uint24,uint24)" "$VP" --rpc-url "$RPC" | sed -n 2p | num)

REPORTED=$(cast call "$VERNIER_VAULT" "rate()(uint256)" --rpc-url "$RPC" | num)
ACCEPTED=$(cast call "$VERNIER_HOOK" "lastRateOf(bytes32)(uint256)" "$VP" --rpc-url "$RPC" | num)

python3 - "$VG1" "$BG1" "$VL" "$BL" "$REPORTED" "$ACCEPTED" "$TICK" <<'PY'
import sys
vg1, bg1, vl, bl, rep, acc, tick = (int(x) for x in sys.argv[1:8])
Q128 = 1 << 128

vern = vg1 * vl // Q128
base = bg1 * bl // Q128

print(f"tick                  : {tick}   (0 is par)")
print(f"reported rate         : {rep / 1e18:.9f}")
print(f"accepted rate         : {acc / 1e18:.9f}   (clamped if lower)")
print(f"liquidity vern/base   : {vl / 1e18:.2f} / {bl / 1e18:.2f}")
print()
print(f"yield kept by vernier : {vern / 1e18:.12f}")
print(f"yield kept by baseline: {base / 1e18:.12f}")
print(f"difference            : {(vern - base) / 1e18:.12f}")
PY
