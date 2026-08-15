# Architecture

Vernier is a Uniswap v4 hook plus a small set of internal accounting libraries, deployed alongside curated pools for yield-bearing assets. Its core path has no off-chain components. Everything needed to price a swap against fair value and retain the yield for LPs happens synchronously inside the swap lifecycle.

## 1. System context

```mermaid
flowchart LR
    Trader["Trader / arbitrageur"] -->|swap| PM["Uniswap v4\nPoolManager"]
    LP["Liquidity providers"] -->|add / remove liquidity| PM
    PM <-->|hook callbacks| Vernier["Vernier Hook"]
    Vernier -->|reads exchange rate| Token["Yield-bearing token\n(ERC-4626 vault / LST)"]
    Vernier -->|yield retained| LP
```

The only external contract Vernier reads is the yield-bearing token itself, for its on-chain exchange rate. There is no price oracle, relayer, or keeper in the path.

## 2. Component view

```mermaid
flowchart TB
    subgraph Hook["Vernier Hook contract"]
        BS["beforeSwap()\nread par price, reconcile pool price, price the swap fairly"]
        AS["afterSwap()\nmeasure retained value, update accounting"]
        AL["afterAddLiquidity()\ntrack LP in-range exposure"]
        RL["beforeRemoveLiquidity()\nsettle LP share + retained yield"]
    end

    subgraph Libs["Internal libraries"]
        RATE["RateReader\nper-asset exchange-rate adapter + bounds"]
        PRICE["ParPricing\nfair-value / par-price computation"]
        DIST["Redistribution\nliquidity-weighted accounting"]
    end

    BS --> RATE
    BS --> PRICE
    BS --> DIST
    AS --> DIST
    AL --> DIST
    RL --> DIST
```

| Component | Responsibility |
|---|---|
| `beforeSwap` | Read the token's par price, reconcile it against the pool price, and ensure the swap executes at fair value so no accrued yield is left to arbitrage. |
| `afterSwap` | Record value retained for LPs and update accounting. |
| `afterAddLiquidity` | Track each LP's in-range liquidity for exposure-weighted payouts. |
| `beforeRemoveLiquidity` | Settle an LP's accrued share on exit. |
| `RateReader` | Per-asset adapter that returns the correct exchange rate (`convertToAssets` for ERC-4626, pooled-ETH-per-share for stETH) with per-asset safety bounds. |
| `ParPricing` | Turns an exchange rate into the pool's fair price and the reconciliation needed. |
| `Redistribution` | Reward-per-liquidity accumulator. |

The `RateReader` adapter pattern is deliberate: onboarding a new yield asset means writing one small adapter, which keeps the core hook asset-agnostic and is part of the venue's moat.

## 3. Swap-time data flow

```mermaid
sequenceDiagram
    participant T as Trader
    participant PM as PoolManager
    participant H as Vernier Hook
    participant Y as Yield token

    T->>PM: swap
    PM->>H: beforeSwap(...)
    H->>Y: exchangeRate()  (convertToAssets / pooled-ETH-per-share)
    Y-->>H: current rate
    H->>H: parPrice = ParPricing.fromRate(rate)
    H->>H: reconcile pool price toward par (bounded)
    H-->>PM: return (fair price / fee override)
    PM->>PM: execute swap at fair value
    PM->>H: afterSwap(...)
    H->>H: credit retained yield to in-range LPs
    H-->>PM: return
```

## 4. Reward accounting

Vernier uses a reward-per-liquidity accumulator so payouts are O(1) per swap and per LP:

```
On retaining value V with total in-range liquidity L:
    rewardPerLiquidity += V / L

Each LP tracks:
    owed = liquidity x (rewardPerLiquidity - rewardPerLiquidityPaid[LP])

On remove / claim:
    pay owed, then set rewardPerLiquidityPaid[LP] = rewardPerLiquidity
```

## 5. Trust and dependencies

| Dependency | Vernier uses it? |
|---|---|
| External price oracle | No |
| Off-chain auction / relayer | No |
| Trusted keeper / bot | No |
| Governance for live prices | No |
| Yield token's own on-chain rate | Yes (canonical source of truth) |
| Curated asset onboarding | Yes (adapter + bounds per asset) |

## 6. Non-goals

- Vernier is not a permissionless listing venue for arbitrary tokens. It is a curated venue for vetted yield-bearing assets, which is safer and is part of the moat.
- Vernier does not try to predict market prices. It only reads the deterministic accrual a yield token publishes about itself.
- Vernier does not depend on any single chain feature beyond running as a v4 hook; it targets Unichain first for its liquidity and low fees.
