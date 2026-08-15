# Pitch

## One-liner

Carry is the liquidity venue for yield-bearing assets: it reads each token's own on-chain yield rate and makes arbitrageurs pay the gap to LPs, so the yield stays with the people who fund the market.

## The 90-second version

Yield-bearing tokens are one of the largest asset classes in DeFi: liquid staking tokens, yield-bearing stablecoins, tokenized treasuries. Tens of billions of dollars, all with one property in common: their fair price drifts upward on a schedule the token itself publishes on-chain.

Ordinary AMMs ignore this. The pool keeps quoting a stale price while the token quietly accrues, and arbitrage bots collect the difference every single block. For these assets, LP losses are not occasional slippage. They are a continuous, predictable transfer of the yield from liquidity providers to bots. This is why sophisticated holders refuse to LP their staked positions.

Carry fixes it at the source. Our hook reads the token's own exchange rate, computes the pool's live gap from fair value, and charges exactly that gap as a fee, only on trades that harvest it. No external oracle: the token's own accounting is the truth. No auction network, no keeper. A dust swap cannot clear the fee, ordinary flow pays nothing extra, and once the pool reaches fair value the fee is zero.

The result: either nobody trades against the stale price and nothing leaks, or somebody does and the LPs are paid the exact value that used to leak. LPs are made whole in both branches.

It is live: deployed, tested against adversarial cases, with per-LP attribution accounting and a real-time dashboard. In simulation, LPs keep between 0.8% and roughly 10% more per year depending on how toxic the flow is.

The business is the venue: curated pools for vetted yield assets, a rate adapter per asset family, and a take on the volume that flows through markets that only work because of this mechanism.

## Common questions

**How is this different from general MEV protection (auction protocols, batch AMMs)?**
Those treat every price move as unknown and fight it after the fact with auctions or batching, which needs off-chain infrastructure. For yield-bearing assets the fair price move is deterministic and published by the token itself. Carry reads it directly and neutralizes the arbitrage at the source, fully on-chain. Specialized beats general on this asset class.

**Why would Uniswap not just ship this natively?**
The core protocol ships general infrastructure. This is venue work: a vetted rate adapter per asset, per-asset safety bounds, curated onboarding, and the LP relationships that follow. That is a product with an owner, not a protocol default.

**What if the rate feed lies or breaks?**
The rate is the token's own accounting, not a market quote, so it cannot be moved by trading. Against a compromised or exotic token, the hook enforces a per-swap jump bound and falls back to zero surcharge if the rate call reverts or returns zero. Assets are onboarded deliberately, not permissionlessly.

**Can an attacker reset the fee with a tiny swap?**
No. The fee is a function of the pool's live distance from par. Only volume that actually moves the pool to par reduces it. This is covered by a dedicated adversarial test.

**Does the fee scare arbitrageurs away and leave the pool stale?**
Either outcome protects LPs. If the gap goes uncorrected, the LPs are simply holding a token that is accruing value; nothing has leaked. If someone closes it, they pay the gap to LPs. The fee makes LPs indifferent between the two branches, which is exactly the point.

**What about ordinary traders?**
The mispricing is directional, so only trades harvesting it pay the surcharge. Retail flow going the other way pays the pool's base rate. A trader who happens to trade in the arb direction is also the one capturing the gap's value, so the charge nets out fair.

**Business model?**
Take rate on volume through Carry pools, curated listings for yield-asset issuers who want deep liquidity without bleeding their holders, and later a managed LP vault layer on top.

## Proof points

- Full test suite including adversarial cases (dust reset, wrong-direction flow, slashing direction flip, broken rate feed).
- Economic simulation vs an identical baseline pool showing measurable LP uplift.
- Live testnet deployment with seeded liquidity, real swaps, and on-chain per-LP retention attribution.
- Real-time dashboard reading pool state and retained yield directly from the chain.
