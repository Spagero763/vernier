# Vernier

A Uniswap v4 venue for yield-bearing assets. It reads the rate a yield token publishes
about itself and corrects the curve by exactly how stale that rate has made it, so accrual
reaches liquidity providers instead of the first bot to notice.

## The problem

Liquid staking tokens, yield-bearing stablecoins and tokenized treasuries share a property:
their fair price moves on a schedule the token itself publishes on-chain. `convertToAssets`
for an ERC-4626 share, pooled ETH per share for stETH.

An AMM quotes from reserves and knows nothing about that. The token accrues, the pool keeps
quoting yesterday's price, and someone buys the difference. For this asset class it is not
occasional slippage. It is a continuous and entirely predictable transfer out of LP
positions, and it is why holders are reluctant to LP staked assets.

## Charging for the correction makes it worse

The obvious response is a dynamic fee sized to the gap. It fails, and the repository
measures the failure rather than asserting it.

An arbitrageur closing a gap earns roughly half of it, because the gap shrinks as they trade
into it. A fee equal to the whole gap is therefore about twice their profit, and correcting
the pool becomes strictly loss-making. Nobody corrects it, the gap compounds, and the fee
climbs until the pool quotes several percent away from fair value for everyone.

`test/RationalFlow.t.sol` runs flow that only trades when trading pays, sized to the gap
rather than fixed. Over twelve accrual periods:

| | plain pool | gap-fee pool |
|---|---|---|
| correcting trades | 12 | 0 |
| final distance from par | 494 pips | 49,070 pips |

The design meant to protect LPs left the pool a hundred times more mispriced than doing
nothing at all.

## What Vernier does instead

The token publishes its rate, so the factor by which the curve has gone stale is known
exactly. With `R0` the rate at configuration and `R` the rate now, the curve is stale by
`m = R / R0` and by nothing else. The hook applies `m` to the curve's own price.

Applying it to the curve's price rather than quoting par outright is the whole design.
Quoting par would make this a fixed-price market maker, and the first time the token traded
below par in a withdrawal queue, arbitrageurs would sell into the pool at par until the LPs
were empty. Correcting by a factor leaves genuine premium or discount on the curve, still
discoverable and still arbitrageable. Vernier removes the part of the price that is already
public and touches nothing else.

The correction lands on the leg the swapper did not specify, which is the yield token on one
swap type and the quote on the other, so neither exact input nor exact output routes around
it. It is settled with `poolManager.donate`, letting v4 split it across in-range liquidity.

Rate movement is bounded by implied APR over elapsed time rather than per-swap step, since a
step bound can be walked by repeated small moves. A reading past the bound is clamped rather
than rejected: rejecting would let anyone able to disturb the rate source freeze the pool.

Full derivation, including the four correction formulas and the reasoning behind each
decision, is in [`docs/mechanism.md`](docs/mechanism.md).

## Partner integrations

### EigenLayer

An operator set answers the one question the hook cannot answer alone: did a share price rise
because yield accrued, or because someone donated into the vault to inflate it.

| Where | What |
|---|---|
| [`src/avs/RateAttestationService.sol`](src/avs/RateAttestationService.sol) | Weighted ECDSA operator set. Operators sign whether a pool's rate source can be believed; a quorum records the result. Follows the attestation shape of the Hello World sample. |
| [`src/interfaces/IRateAttestor.sol`](src/interfaces/IRateAttestor.sol) | The whole surface an operator set is given: `isSound(poolId)`. |
| [`src/VernierParHook.sol`](src/VernierParHook.sol), `_attestedSound` and `setAttestor` | Where the hook consults it and what it does with the answer. |
| [`test/RateAttestationService.t.sol`](test/RateAttestationService.t.sol), [`test/Attestor.t.sol`](test/Attestor.t.sol) | Quorum, duplicate-signer padding, non-operator signatures, nonce replay, cross-deployment replay, and the hook's behaviour when the service is captured or down. |

Two properties are deliberate. The service can only withhold a correction, never set a
price, so a captured operator set degrades Vernier to an ordinary AMM and can do nothing
worse. And an attestor that reverts or has stopped reporting is treated as sound, so it
cannot halt the venue either. Silence is not an accusation.

Operator weights are set directly rather than read from a stake registry. In production they
come from delegated stake, and the source of `operatorWeight` is the only thing that
changes.

### Unichain

Deployed and exercised on Unichain Sepolia. [`test/Fork.t.sol`](test/Fork.t.sol) runs
against the PoolManager deployed there rather than a fresh local one, which matters: a local
PoolManager accepts settlement that deployed v4 rejects, so returning a hook delta without
settling it passes locally and reverts on chain. Addresses in
[`docs/deployments.md`](docs/deployments.md).

No other partner integrations are present.

## Routing and quoting

The Uniswap interface will not route these pools natively. The hook returns an
`afterSwap` delta, so execution differs from what the curve alone implies, and the
interface does not route pools whose output it cannot derive from the curve.

That is a property of the mechanism rather than a gap in it, and it does not make the
pool opaque. The v4 Quoter simulates hooks, so an integrator prices a swap correctly
before sending it. [`test/Quoter.t.sol`](test/Quoter.t.sol) asserts the quote equals
execution to the wei on both swap types:

| | |
|---|---|
| quoted output | 985666194671114797 |
| actually received | 985666194671114797 |
| quoted input, exact output | 1014648738510669477 |
| actually paid | 1014648738510669477 |
| correction visible in the quote | 3942664778684459 |

The correction is priced into the quote rather than hidden from it, so an integrator
sees what a swap costs before committing to it.

## Live deployment

Unichain Sepolia, chain id 1301.

| | |
|---|---|
| VernierParHook | [`0x80e4a79F2297E3CcE4F68ae535b2508187C6c644`](https://unichain-sepolia.blockscout.com/address/0x80e4a79F2297E3CcE4F68ae535b2508187C6c644) |
| RateAttestationService | [`0x415302aDd60A138c872E07019Dc9E0a77b284292`](https://unichain-sepolia.blockscout.com/address/0x415302aDd60A138c872E07019Dc9E0a77b284292) |

Both verified, so the live configuration is readable from the explorer directly.

Two pools hold the same pair at the same fee, spacing and starting price. The only
difference is whether the hook is attached, so the comparison can be read off-chain instead
of taken on trust.

| | Pool id |
|---|---|
| Vernier | `0xf06ea22d2843e36aab79cad40eac4a36953fc1a1a4ae7160ffa3cda24e9e99ed` |
| Baseline, no hook | `0x38ca13d084484b6057c433c1e6497b85fbf2f1da670c87bf269e38f925566e03` |

The hook address ends in `c644` because v4 reads a hook's permissions from its address.
`0x644` is `AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA | AFTER_ADD_LIQUIDITY |
BEFORE_REMOVE_LIQUIDITY`, which is why deployment mines a salt.

## Build and test

```shell
forge build
forge test
```

`test/Fork.t.sol` forks Unichain Sepolia from a hardcoded endpoint and runs as part of the
suite, so `forge test` needs network access. Run it alone with:

```shell
forge test --match-path test/Fork.t.sol -vv
```

Deployment and seeding, including why seed accrual is scaled to elapsed time, are in
[`docs/deployments.md`](docs/deployments.md).

## Dashboard

`web/` is a Next.js app reading both pools live. It needs no environment variables;
`NEXT_PUBLIC_RPC_URL` is optional and falls back to the public endpoint.

```shell
cd web && npm install && npm run dev
```

## Repository layout

```
vernier/
├── docs/
│   ├── architecture.md      Contracts, callbacks, settlement, trust surface
│   ├── mechanism.md         Derivation, correction formulas, measured results
│   ├── pitch.md             The argument and the common objections
│   ├── deployments.md       Live addresses and how to reproduce them
│   └── roadmap.md           Built, and what is not
├── src/
│   ├── VernierParHook.sol   The hook
│   ├── VernierHook.sol      Earlier gap-fee design, kept as the baseline
│   ├── avs/                 Rate attestation service
│   ├── adapters/            Rate sources (ERC-4626, stETH)
│   ├── interfaces/          IRateSource, IRateAttestor
│   ├── lib/                 Retention accounting for the fallback path
│   ├── base/                Minimal v4 hook base
│   └── periphery/           Minimal swap router
├── test/                    Unit, adversarial, simulation and fork tests
├── script/                  Deploy, seed, and a clamp demonstration
└── web/                     Dashboard
```

## Limits

Stated plainly because they are real.

- `m` grows without bound: `R0` is never rebased, so over a long enough life the correction
  becomes a large fraction of every trade. Rebasing it correctly means moving liquidity at
  the same time, which is not implemented.
- Concentrated positions are chosen in curve-price terms while execution happens at
  `curve * m`, so a range gradually stops covering the prices its owner picked.
- Corrections leave the pool rather than re-centering it, so anything reading `slot0` sees a
  deliberately stale price.
- A sharp genuine move in the rate is not absorbed on the reading that reports it. It is
  bounded to what elapsed time justifies and tracked over subsequent swaps.
- Coverage is scenario-based. There are no fuzz or invariant tests yet.

## Prior work in this repository

`src/VernierHook.sol` and its tests predate the current design. They implement the gap-fee
mechanism and are retained because they are the baseline the measurements above are taken
against, not because they are recommended. Their access control and rate guard have known
weaknesses that `VernierParHook` fixes.
