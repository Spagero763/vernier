# Roadmap

## Built

**Correction mechanism.** Reads the yield token's published rate, derives how stale the
curve has become, and corrects the leg the swapper did not specify. Applies to exact input
and exact output, and to both sides depending on which way the rate has moved.

**Settlement to LPs.** Corrections go through `poolManager.donate`, so v4 distributes them
across in-range liquidity. When a swap leaves the price outside every position and there is
nothing in range to pay, the hook holds the value and LPs claim it.

**Rate bounds.** Movement is bounded by implied APR over elapsed time rather than per-swap
step, so repeated small moves cannot ratchet the reference. Readings past the bound are
clamped rather than rejected, so a disturbed rate source cannot freeze the pool.

**Attestation.** A weighted ECDSA operator set can mark a pool's rate source as unsound,
which suspends corrections. It cannot set a price, and an operator set that goes quiet is
treated as sound.

**Measurement.** A rational-flow harness that only trades when trading pays, used to show
that charging for the correction stops the correction happening. Depeg and slashing
scenarios. Fork tests against the PoolManager deployed on Unichain Sepolia.

## Next

**Rebase the reference rate.** `m = R / R0` grows without bound because `R0` is fixed at
configuration. Over a long enough life the correction becomes a large share of every trade
and the curve's own price drifts arbitrarily far from the effective one. Rebasing `R0`
correctly means moving liquidity at the same time, which is why it is not done yet.

**Range semantics.** LPs choose a range in curve-price terms while execution happens at
`curve * m`, so a position gradually stops covering the prices its owner picked. Either the
range needs interpreting through `m` at quote time, or the interface has to present ranges
in effective-price terms.

**Re-centering.** Corrections leave the pool, so `slot0` stays deliberately stale and any
router or aggregator reading it sees the wrong price. Using part of the correction to move
the curve back toward par would fix that at the cost of a more complex settlement path.

**Property tests.** Coverage is scenario-based. The correction formulas, the clamp, and the
accumulator are all worth fuzzing, particularly around rounding at small trade sizes and
extreme multipliers.

**Stake-backed operators.** Operator weights are set directly. In production they should
come from delegated stake, which changes where `operatorWeight` is read from and nothing
else about the design.
