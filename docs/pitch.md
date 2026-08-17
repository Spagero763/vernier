# Pitch

## One-liner

Vernier is the liquidity venue for yield-bearing assets. It reads each token's own
published exchange rate and corrects the curve by exactly how stale that rate has made it,
so accrual reaches the people funding the market instead of the first bot to notice.

## The 90-second version

Liquid staking tokens, yield-bearing stablecoins and tokenized treasuries share one
property: their fair price moves on a schedule the token itself publishes on-chain.

An AMM quotes from reserves and knows nothing about that. The token accrues, the pool keeps
quoting yesterday's price, and someone buys the difference. For this asset class that is not
occasional slippage, it is a continuous and entirely predictable transfer out of LP
positions. It is why sophisticated holders will not LP their staked positions.

The obvious fix is a dynamic fee sized to the gap. It does not work, and we can show that
rather than argue it. An arbitrageur closing a gap earns roughly half of it, because the
gap shrinks as they trade into it, so a fee equal to the whole gap makes correcting the
pool loss-making. Nobody corrects it, the gap compounds, and the fee climbs until the pool
quotes several percent away from fair value for everyone. Measured against flow that only
trades when trading pays: over twelve accrual periods a plain pool attracted twelve
correcting trades and ended 494 pips from par, while the gap-fee pool attracted none and
ended 49,070 pips out. The design meant to protect LPs left the pool a hundred times more
mispriced than doing nothing.

Vernier does not charge for the correction. It performs it. The token publishes its rate,
so the factor by which the curve has gone stale is known exactly, and the hook applies that
factor to the curve's own price. Accrual stops opening a gap at all.

The word "own" is carrying weight there. Quoting par outright would make this a fixed-price
market maker, and the first time the token traded below par in a withdrawal queue,
arbitrageurs would sell into the pool at par until the LPs were empty. Correcting the curve
by a factor leaves genuine premium or discount exactly where it belongs, on the curve,
still discoverable and still arbitrageable. Vernier removes the part of the price that is
already public and touches nothing else.

Against an identical baseline pool: accrual arbitrage extracted 4564606161991614 from the
plain pool and nothing from Vernier, and on organic retail flow Vernier's LPs finished 51
basis points ahead over the same run.

The business is the venue: curated pools for vetted yield assets, one small rate adapter per
asset family, and a take on volume through markets that only work because of this
mechanism.

## Common questions

**How is this different from MEV protection or batch auctions?**
Those treat every price move as unknown and fight it after the fact, which needs off-chain
infrastructure. For yield-bearing assets a large share of the move is deterministic and
already published by the token. Vernier subtracts that share on-chain and leaves the rest
to the market. Specialised beats general on this asset class.

**What about a dynamic fee sized to the gap, which is simpler?**
That is the design in `src/VernierHook.sol`, kept in this repo as the measurement baseline.
It removes the incentive to correct the pool without putting anything in its place, and the
numbers above are what happens next.

**What if the token depegs?**
Then the curve, not the hook, prices it. The correction is a factor applied to the curve's
price rather than a target price, so a discount to par moves the curve normally and stays
arbitrageable. `test_marketDiscountStaysDiscoverable` asserts selling pressure still moves
the price.

**What if the rate is manipulated, for instance by donating into an ERC-4626 vault?**
The hook bounds how fast the reference may move, as an implied APR over elapsed time rather
than a per-swap step, since a step bound can be walked by repeated small moves. Readings
past the bound are clamped rather than rejected, because rejecting would let anyone able to
disturb the rate source freeze the pool. An optional operator set can additionally mark a
rate unsound, which suspends corrections.

**Then a real slashing is not fully absorbed straight away?**
Correct, and the tests assert that limit rather than hiding it. A sharp move is bounded to
what one reading can justify and tracked over subsequent swaps as the bound allows. In
testing a 5% slash against a 20% APR bound converges on the reported rate after eight
swaps. `test_slashedRate_boundsTheLossWithoutTrustingOneReading` fails if the loss is not
reduced and also fails if the hook pretends to absorb a move it cannot verify.

**What can the operator set do if it is captured?**
Withhold corrections. Nothing else. It cannot set a price, so the worst case is that
Vernier behaves like an ordinary AMM. An attestor that reverts or stops reporting is
treated as sound, so it cannot halt the venue either.

**Who pays the correction?**
Whoever is on the side the curve has wrong: the buyer while the token is underpriced, the
seller once a loss has left it overpriced. Flow the other way pays nothing, because it is
not capturing anything.

**Can exact-output swaps route around it?**
No. The correction lands on the leg the swapper did not specify, which is the yield token
on one swap type and the quote on the other. `test_parHook_exactOutputIsNotABypass` covers
it.

**Business model?**
Take rate on volume through Vernier pools, curated listings for yield-asset issuers who
want deep liquidity without bleeding their holders, and a managed LP vault layer later.

## Proof points

- Rational-flow harness that trades only when trading pays, sized to the gap rather than
  fixed, which is what exposes the failure of fee-based designs.
- Adversarial coverage: exact-output bypass, market discount, slashing, implausible rate,
  broken attestor, duplicate-signer quorum padding, cross-deployment attestation replay.
- Fork tests against the PoolManager deployed on Unichain Sepolia. A local PoolManager will
  accept settlement that deployed v4 rejects, so this is what establishes the mechanism
  clears real accounting.
- Stated limits in `docs/roadmap.md`, including the unbounded reference rate and range
  drift, both of which are real and neither of which is fixed yet.
