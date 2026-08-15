# Roadmap

Vernier is built in layers, so there is a working, demoable system at the end of every stage and no stage depends on the next one existing.

## Stage 0: Foundations
- Foundry project scaffolded on the Uniswap v4 template.
- Hook permissions wired (`beforeSwap`, `afterSwap`, `afterAddLiquidity`, `beforeRemoveLiquidity`).
- Hook address mined so the permission bits match the deployed address (v4 requirement).
- A pool deployed against the hook in tests, using a mock yield-bearing token.

## Stage 1: Yield-aware pricing (core)
- `RateReader` adapter for ERC-4626 (`convertToAssets`) with safety bounds.
- `ParPricing` computes fair price from the rate.
- `beforeSwap` reconciles the pool price toward par so accrued yield is not left to arbitrage.
- Full Foundry tests with a mock ERC-4626 vault whose rate we advance over time: prove the arbitrage gap that exists on a plain pool is removed on a Vernier pool.
- Deployed to Unichain Sepolia with a public address.

Deliverable: a pool where LPs keep the yield, demonstrated against a baseline.

## Stage 2: Liquidity-weighted retention accounting
- `afterAddLiquidity` / `beforeRemoveLiquidity` track per-LP in-range exposure.
- Reward-per-liquidity accumulator credits retained yield by real exposure.
- Tests: two LPs with different ranges receive correct proportional retention; claim on exit settles exactly.

## Stage 3: Multi-asset support
- Add an LST adapter (stETH / wstETH pooled-ETH-per-share) alongside ERC-4626.
- Per-asset bounds and fallback behavior on stale or reverting rates.
- Tests across both asset types.

## Stage 4: Proof and presentation
- Simulation harness: run a realistic accrual + trade sequence through a plain pool vs a Vernier pool over simulated time, report cumulative LP uplift.
- Dashboard: live view of yield retained for LPs vs leaked on a baseline pool.
- Written results: measured LP uplift, gas overhead, and the business case.

## Definition of done
- Near-complete test coverage.
- Live testnet deployment with a shown address.
- A simulation that quantifies LP uplift vs a baseline pool over time.
- Documentation complete (this repo).
