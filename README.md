# Vernier

**The Uniswap v4 liquidity venue for yield-bearing assets.**

Vernier is a set of Uniswap v4 pools and a hook purpose-built for yield-bearing tokens (liquid staking tokens, yield-bearing stablecoins, tokenized treasuries). It reads each token's on-chain yield rate and prices it in real time, so the yield those tokens accrue is captured by liquidity providers instead of leaking to arbitrage bots.

---

## The problem

Yield-bearing tokens have a price that drifts upward on a known, mechanical schedule as they accrue yield. Their fair value at any moment is written on-chain, in the token's own exchange rate.

A normal AMM ignores this. It keeps quoting the pool's old price while the token quietly accrues, leaving it underpriced. Arbitrageurs correct that gap every block and keep the difference. For yield-bearing assets this is not occasional slippage, it is a **continuous, predictable drain of the yield straight out of the LPs' pockets**. It is one of the largest and most quantifiable losses in DeFi, and it is the reason sophisticated holders are reluctant to LP their staked and yield-bearing positions.

## The idea

The fair price of a yield-bearing token is not a mystery. It is derivable from the token's own on-chain exchange rate:

- ERC-4626 vaults (sUSDe, sDAI, and most yield stables): `convertToAssets(1e18)`
- Liquid staking tokens (stETH / wstETH): the pooled-ETH-per-share rate

Vernier's hook reads that rate inside `beforeSwap` and adjusts the pool's effective price to track the accrual, so there is no stale price left to arbitrage. The yield stays with the LPs who own the liquidity. No external price oracle is required: the yield-bearing token itself is the canonical, manipulation-resistant source of truth for its own value.

```
Yield token accrues on-chain  ──►  hook reads token's own exchange rate  ──►  pool price tracks fair value
                                                                                        │
                                                                          no stale price to arbitrage
                                                                                        │
                                                                          accrued yield stays with LPs
```

## Why it is different

| Approach | How it handles a yield token's drift |
|---|---|
| Generic AMM | Ignores it; LPs bleed the yield to bots every block |
| General MEV / auction protocols | Treat the drift as an unknown price move; fight it with auctions after the fact |
| **Vernier** | **Knows the drift in advance from the token's own rate; prices it in so there is nothing to arbitrage** |

For yield-bearing assets the fair price move is deterministic. A specialized venue that reads the token's rate can neutralize the arbitrage that generalized solutions can only tax after it happens.

## Why it is a venue, not just a hook

- **A real, large market**: liquid staking tokens and yield-bearing stablecoins hold tens of billions in value. These are the assets institutions and treasuries actually hold.
- **A clear business**: Vernier runs the pools for these assets and earns a share of the volume; LPs earn their yield plus fees instead of donating the yield to arbitrage.
- **A durable wedge**: per-asset pricing logic, integrations with each yield token, and the LP relationships that follow.

## Status

Early development. See [`docs/architecture.md`](docs/architecture.md) for the system design, [`docs/mechanism.md`](docs/mechanism.md) for the pricing mechanism and math, and [`docs/roadmap.md`](docs/roadmap.md) for milestones.

## Build

```shell
forge build
forge test
```

## Repository layout

```
vernier/
├── README.md
├── docs/
│   ├── architecture.md      System design, components, data flow
│   ├── mechanism.md         Gap-priced fees, par math, redistribution
│   ├── pitch.md             One-liner, 90-second pitch, common questions
│   ├── deployments.md       Live addresses and reproduction steps
│   └── roadmap.md           Build milestones
├── src/
│   ├── VernierHook.sol        The hook: gap-priced, direction-aware fees
│   ├── base/                Minimal v4 hook base
│   ├── adapters/            Rate sources (ERC-4626, stETH)
│   ├── lib/                 Retention accounting
│   └── periphery/           Minimal swap router
├── test/                    Foundry tests incl. adversarial cases + simulation
├── script/                  Deploy and seed scripts
└── web/                     Live dashboard (Next.js)
```
