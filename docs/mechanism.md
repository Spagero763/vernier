# Mechanism

This document describes how Carry prices yield-bearing assets so that accrued yield is retained by liquidity providers rather than extracted by arbitrageurs.

## 1. Background: why yield-bearing tokens bleed LPs

A yield-bearing token represents a claim on an underlying that grows over time:

- **sUSDe, sDAI, and most yield stables** are ERC-4626 vault shares. One share is worth `convertToAssets(1e18)` of the underlying, and that number only rises as yield accrues.
- **stETH / wstETH** represent staked ETH. The pooled-ETH-per-share rate rises as staking rewards accrue.

The token's fair value against its underlying therefore follows a smooth, upward, largely predictable path. Call this the **par price**: the value implied by the token's own on-chain exchange rate at a given moment.

An ordinary AMM does not know about par. It quotes a price derived only from its reserves. As the token accrues, the pool's quoted price falls behind par. The token is now underpriced in the pool, and any arbitrageur can buy it cheap and redeem or sell it at par, pocketing the accrued yield. This repeats block after block. The cumulative transfer from LPs to arbitrageurs is **loss-versus-rebalancing (LVR)**, and for yield-bearing assets it is unusually large because the mispricing regenerates continuously and predictably.

## 2. The core observation

For a generic asset, the fair price is unknown to the contract, so protocols fight LVR with oracles or auctions. For a yield-bearing token, the fair price against its underlying is **already on-chain**, published by the token itself:

```
parPrice = tokenExchangeRate()   // convertToAssets(1e18) for ERC-4626, pooled-ETH-per-share for stETH
```

This is the canonical source of truth. It is not an external price feed that can be manipulated by a flash loan; it is the token's own accounting, which for real yield assets moves only as fast as yield actually accrues.

Carry uses this to remove the arbitrage at its source.

## 3. Yield-aware pricing in beforeSwap

On each swap, before it executes, the hook:

1. Reads the token's current par rate and derives the pool's fair price from it.
2. Reads the pool's actual current price from pool state.
3. Computes the **gap**: how far the pool is from par, and in which direction.
4. Charges a dynamic fee equal to that gap, **only on swaps in the direction that captures the gap**. Swaps in the other direction pay no surcharge.

The fee is a pure function of pool state versus par. Three properties fall out of that design:

- **No dust bypass.** The fee is not based on "rate change since the last swap," so a tiny swap cannot reset anything. The fee persists until the pool price actually converges to par, because only real trading volume can move the pool there.
- **Ordinary flow is untouched.** The mispricing is directional (the accruing token is always the underpriced side), so only trades harvesting it pay. A retail swapper going the other way pays zero surcharge. A swapper who happens to trade in the arb direction pays the gap, but they are also the one capturing the gap's value, so the charge is exactly fair.
- **The fee self-extinguishes.** Once an arbitrage swap moves the pool to par, the gap is zero and the fee is zero. The fee equals the arb profit, no more.

One conservative simplification: the fee is set from the pre-swap gap and applies to the whole swap amount. A large swap that crosses par pays the gap fee on its full size, which favors LPs; scaling the fee by only the gap-closing portion of the swap is a planned refinement.

## 4. Why no external oracle is needed

The only external value Carry reads is the yield token's own `exchangeRate`-style function. This matters:

- It is the definition of the token's value against its underlying, not a market quote, so it cannot be moved by trading pressure or a sandwich.
- For reputable yield tokens it updates smoothly and monotonically, so it is safe to price against directly.
- It removes the trust and attack surface that oracle-based MEV solutions carry.

Carry does apply standard guardrails on the rate (see Security), but it never depends on a third-party price feed.

## 5. Redistribution to LPs

Value that Carry retains for LPs (whether by preventing the arb or by capturing it as a fee) is credited using a reward-per-liquidity accumulator over in-range liquidity, the same pattern well-audited staking systems use:

```
On retaining value V with in-range liquidity L:
    rewardPerLiquidity += V / L

LP owed:
    owed = LP.liquidity * (rewardPerLiquidity - LP.paidCheckpoint)
```

This is exact, O(1) per swap, and weights payouts by the liquidity actually exposed.

## 6. Worked example

Take an sUSDe / USDC pool. Suppose sUSDe yields at a rate that accrues 0.02 percent per hour, and the pool has not traded for an hour.

- **On a normal AMM:** the pool still prices sUSDe at last hour's par. It is now 0.02 percent underpriced. An arbitrageur buys sUSDe from the pool and redeems it at the higher par, extracting that 0.02 percent from the LPs. Every hour, forever.
- **On Carry:** the hook reads sUSDe's current `convertToAssets` before the swap, sees that par has risen 0.02 percent, and prices the trade at par. The arbitrage gap is zero. The 0.02 percent accrual stays reflected in the LPs' position value.

Multiply 0.02 percent per hour across a year of continuous accrual on a large pool and the difference to LPs is substantial. That gap is the entire product.

## 7. Security considerations

- **Rate manipulation:** Carry reads the token's own exchange rate. For legitimate yield tokens this is not market-manipulable, but the hook still bounds the maximum upward rate jump it will act on, rejecting implausible moves from a compromised or exotic token.
- **Dust-reset attacks:** an earlier design charged the fee based on the rate change since the last swap, which a 1 wei swap could reset, clearing the fee while the pool stayed mispriced. The shipped design prices the fee from the pool's live gap to par, so no swap can clear the fee without actually moving the pool to par. This is covered by a dedicated test.
- **Direction handling under slashing:** if an LST is slashed, the pool flips from underpricing to overpricing the token, and the arb direction flips with it. The gap computation is symmetric, so the fee follows the true arb direction automatically.
- **Stale or reverting rate:** if the rate call reverts or returns zero, the swap proceeds with no surcharge and the pool degrades to ordinary behavior rather than halting.
- **Reentrancy and accounting:** all value movement happens inside the PoolManager unlock context using the accumulator pattern, with no external calls in the reward path.
- **Asset onboarding:** each yield token is integrated deliberately with the correct rate function and bounds. Carry is a curated venue, not a permissionless listing of arbitrary tokens, which is both safer and part of the moat.

## 8. Open questions to resolve during build

- Scale the fee by the gap-closing portion of a swap that crosses par, instead of the full amount.
- Exact rate-jump bounds per asset class (LSTs vs vault stables differ).
- Whether to expose captured value as auto-compounding into the LP position or as a separately claimable reward.
