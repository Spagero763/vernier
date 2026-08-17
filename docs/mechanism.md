# Mechanism

Vernier is a Uniswap v4 venue for yield-bearing assets. This document describes how it
prices the accrual those assets publish, and why that is different from charging for the
arbitrage the accrual creates.

## 1. Where the value goes today

A yield-bearing token is a claim on an underlying that grows over time.

- ERC-4626 shares such as sUSDe or sDAI are worth `convertToAssets(1e18)` of the
  underlying, and that number only rises as yield accrues.
- stETH and wstETH represent staked ETH, and the pooled-ETH-per-share rate rises with
  staking rewards.

An AMM quotes from its reserves and knows nothing about this. Between swaps the token
accrues, the pool keeps quoting the old price, and the token is left underpriced. Someone
buys it cheap and the difference comes out of the LPs. This repeats every block, and
unlike ordinary loss-versus-rebalancing it is entirely predictable, because the size of
the mispricing is published on-chain by the token itself.

## 2. Charging for the correction does not work

The obvious response is a dynamic fee sized to the gap, which is what
`src/VernierHook.sol` does and what the dynamic-fee designs in this space generally do.
It fails, and the failure is measurable.

An arbitrageur closing a gap `g` does not earn `g` on their whole trade. They earn
roughly half of it, because the gap shrinks as they trade into it. A fee equal to the full
gap applied to the full trade is therefore around twice their profit, and correcting the
pool becomes strictly loss-making.

If nobody can profit from correcting the price, nobody corrects it. The pool stays wrong,
the gap widens with every accrual, and the fee climbs until it hits its cap. At that point
the pool quotes several percent away from par in one direction for everyone, retail
included, and routers stop sending flow to it.

`test/RationalFlow.t.sol` measures this with flow that only trades when trading pays. Over
twelve accrual periods:

| | plain pool | gap-fee pool |
|---|---|---|
| correcting trades | 12 | 0 |
| final distance from par | 494 pips | 49,070 pips |

The pool built to protect LPs ends a hundred times further from par than the one that does
nothing, because it removed the incentive to fix the price without putting anything in its
place.

## 3. Pricing the staleness instead

The token publishes its own rate, so the amount the curve is wrong by is known exactly.
Let `R0` be the rate when the pool was configured and `R` the rate now. The curve's quoted
price is stale by

```
m = R / R0
```

and by nothing else. Vernier applies `m` as a multiplicative correction to the curve's own
price rather than replacing that price.

This distinction is the whole design. Quoting par directly would make Vernier a
fixed-price market maker, and the first time the token traded below par in a withdrawal
queue or a depeg, arbitrageurs would sell into the pool at par until the LPs were empty.
Correcting the curve by `m` leaves any genuine premium or discount to par exactly where it
belongs, on the curve, where it can still be discovered and arbitraged.

Accrual therefore stops opening a gap, while market disagreement continues to.

## 4. Which side pays

Staleness only helps the trader taking the side the curve has wrong.

- While `m > 1` the curve underprices the token, so the buyer gains.
- While `m < 1`, after a slashing or a loss, the curve overprices it, so the seller gains.

The hook corrects only that side. Flow in the other direction pays nothing, because it is
not capturing anything.

## 5. Where the correction is applied

The correction always lands on the leg the swapper did not specify. That leg is the yield
token on one swap type and the quote on the other, so neither exact input nor exact output
can route around it.

With `m > 1`:

```
exact input   correction = yieldOut * (m - 1) / m      leaving the buyer yieldOut / m
exact output  correction = quoteIn  * (m - 1)          leaving the buyer paying quoteIn * m
```

With `m < 1`:

```
exact input   correction = quoteOut * (1 - m)          leaving the seller quoteOut * m
exact output  correction = yieldIn  * (1 - m) / m      leaving the seller paying yieldIn / m
```

This happens in `afterSwap` rather than `beforeSwap` because both legs are known exactly
there. In `beforeSwap` the output amount does not exist yet, so a correction placed there
can only approximate the exact-input case and cannot address exact output at all.

## 6. Where the value goes

The correction is settled with `poolManager.donate`, which credits fee growth and lets v4
distribute across in-range liquidity on its own terms. A ledger maintained by the hook
would have to answer which positions were in range at the time, and getting that wrong
pays LPs parked far from the active tick for flow they never absorbed.

`donate` reverts when a swap leaves the price outside every position, since there is then
no in-range liquidity to receive anything. Letting that bubble up would revert the swap
itself, so the hook instead takes custody of the correction, records it against the
positions, and LPs withdraw it with `claim`. Covered by
`test_heldCorrection_isClaimableWhenDonateCannotPay`.

## 7. Bounding what one reading can do

The rate is read from the token, not from a price feed, so it cannot be moved by trading
pressure. It can still be wrong: an ERC-4626 share price can be inflated by donating into
the vault, and an exotic or compromised token can report anything.

The hook bounds how fast the reference may move, expressed as an implied APR over elapsed
time rather than as a per-swap step. A step bound is not enough, because a sequence of
moves each just under it walks the reference anywhere.

A reading past the bound is clamped rather than rejected, and this is deliberate on both
counts.

- Reverting would let anyone able to disturb the rate source freeze every swap in the
  pool, which is a worse failure than the one being guarded against.
- Ignoring the reading entirely would switch the correction off exactly when the token is
  repricing hardest.

Clamping keeps pricing moving in the right direction while capping what any single reading
can achieve. A genuine move is tracked over subsequent swaps as the bound allows. In
`test_slashedRate_correctionCatchesUpOverTime` a 5% slash against a 20% APR bound is
accepted as `1.0`, then `0.967`, and reaches the reported `0.95` after eight swaps.

The consequence is honest and worth stating plainly: a sharp genuine move is not fully
absorbed on the reading that reports it.
`test_slashedRate_boundsTheLossWithoutTrustingOneReading` asserts both halves of that,
failing if the loss is not reduced and also failing if the hook pretends to absorb a move
it cannot verify.

## 8. The attestation layer

One question the hook cannot answer alone is whether a share price rose because yield
accrued or because someone inflated the vault. `src/avs/RateAttestationService.sol` is an
operator set that answers it: operators sign whether a pool's rate source can still be
believed, and a weighted quorum records the result.

Its authority is deliberately narrow. It can only withhold the correction, never set a
price. A captured operator set therefore degrades Vernier to an ordinary AMM and can do
nothing worse than that.

It also cannot halt the venue. An attestor that reverts, or one that has stopped
reporting, is treated as sound and the hook falls back to its own bounds. Silence is not
an accusation.

Signers must be strictly ascending, which rejects duplicates and keeps the weight tally
honest in one pass. The chain id and the service address are in the signed digest, so an
attestation cannot be replayed onto another deployment or another chain, and nonces must
advance.

## 9. Measured results

From `test/ParHook.t.sol`, over twelve periods at 4.9% annual accrual against 100e18 of
liquidity:

| | plain pool | Vernier |
|---|---|---|
| value taken by accrual arbitrage | 4564606161991614 | 0 |
| LP position on organic flow | baseline | +51 bps |

From `test/Depeg.t.sol`, selling a 5% slashed token: a plain pool gives up
`4850199725374488` while Vernier gives up `3208826579203949`, the difference being what
the plausibility bound will justify on a single reading.

From `test/Fork.t.sol`, run against the PoolManager deployed on Unichain Sepolia rather
than a fresh one, a corrected swap raises fee growth on the corrected leg and an
exact-output swap settles a correction of `401002104258542`. A local PoolManager will
accept settlement that deployed v4 rejects, so these are the runs that establish the
mechanism clears real accounting.

## 10. Known limits

- `m` grows without bound because `R0` is never rebased. Over a long enough life the
  correction becomes a large fraction of every trade and the curve's own price drifts
  arbitrarily far from the effective one. Rebasing `R0` needs to move liquidity to be
  correct, which is not yet implemented.
- Concentrated positions are chosen in curve-price terms while execution happens at
  `curve * m`, so an LP's range gradually stops corresponding to the prices they picked.
- The correction is taken out of the pool rather than used to re-center it, so anything
  reading `slot0` sees a price that is deliberately stale.
- Coverage is scenario-based. There are no fuzz or invariant tests yet.

## 11. Relationship to the earlier design

`src/VernierHook.sol` is the earlier gap-fee mechanism. It predates the current design and
is kept because it is the benchmark the measurements in section 2 are taken against, not
because it is recommended. Its access control and rate guard have known weaknesses that
the current hook fixes.
