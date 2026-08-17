# Deployments

## Unichain Sepolia (chain id 1301)

| Contract | Address |
|---|---|
| VernierParHook | `0x62e4C0D7E1c366a219006f6034acFaa65b6A0644` |
| RateAttestationService | `0x3E663DE490271A1D8c2F2857d82c789c931F9B24` |
| sYIELD (demo yield token, currency0) | `0xCc18892E1ae1ECD127815916F90ce239d36e3D23` |
| USDC (demo quote token, currency1) | `0xff445090472ebDA1d5b4c9e9C6C56c82831E9697` |
| Vault (backs the rate) | `0xA029fE0c6dd9CCFA6ea9C6E1d6B5D6Fc3496EA14` |
| RateSource (ERC-4626 adapter) | `0x7d06Bf495917062Fde1bB3Ace1F39C65a1aC923d` |
| PoolManager (Uniswap v4) | `0x00B036B58a818B1BC34d502D3fE730Db729e62AC` |
| StateView (Uniswap v4 lens) | `0xc199f1072a74d4e905aba1a84d9a45e2546b6222` |

Helper routers:

| Contract | Address |
|---|---|
| PoolModifyLiquidityTest | `0x7301548d7e76001255A089FD704b47F0D07d63ee` |
| VernierSwapRouter | `0xf428f53Ab7e133C3d79d0f3dA6Cf6a9dc3D0277F` |

The hook address ends in `0644`. That is not cosmetic: v4 reads a hook's permissions
from its address, and `0x644` is `AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA |
AFTER_ADD_LIQUIDITY | BEFORE_REMOVE_LIQUIDITY`, which is why deployment mines a salt.

### The two pools

Both hold the same pair at the same fee, spacing and starting price. The only difference
is whether the hook is attached, so the comparison can be read off-chain instead of taken
on trust.

| | Pool id |
|---|---|
| Vernier | `0xf1c353d3744b932bba5bc1aec3093a77f3c50ff0df11fc8995d1b25f7bb0534c` |
| Baseline, no hook | `0xbb5701c384855eb79ff6ced1c7921235f0c3b607886c86a9c96fba24fe0f4ec1` |

currency0 sYIELD, currency1 USDC, static fee 500, tick spacing 60,
`yieldIsCurrency1 = false`.

Pool configuration: rate source as above, reference rate `1e18`, `maxRateAprPips`
200000 (20% APR), attestor attached, `PoolModifyLiquidityTest` trusted so it can name
the real position owner in `hookData`.

RPC: `https://sepolia.unichain.org`
Explorer: `https://sepolia.uniscan.xyz`

## Running it

Addresses come from `.env`, so only the account flags are needed. Run `forge clean` first
if the tree was last built from a different filesystem, since shared `out/` and `cache/`
between environments produces a misleading "could not find target contract".

Deploy:

```
forge script script/Deploy.s.sol:Deploy \
  --rpc-url https://sepolia.unichain.org \
  --account <keystore> --sender <deployer> --broadcast
```

Seed both pools, accrue, and trade the arb direction on each:

```
forge script script/Seed.s.sol:Seed \
  --rpc-url https://sepolia.unichain.org \
  --account <keystore> --sender <deployer> --broadcast
```

Seed scales accrual to the time elapsed since the last rate move, at half the configured
bound. Minting a flat percentage on demand implies an APR in the thousands, which the
plausibility bound correctly refuses, and the run then measures the guard rather than the
mechanism. Run it repeatedly over days to build the position the way a live one would.

Show the bound rejecting a reading no real rate produces:

```
forge script script/ClampDemo.s.sol:ClampDemo \
  --rpc-url https://sepolia.unichain.org \
  --account <keystore> --sender <deployer> --broadcast
```

This reports a 40% jump in a single reading and leaves a `RateClamped` event recording
what was reported against what was accepted.

## Superseded

Earlier deployments are on-chain but should not be used or pointed at. The v1 and v2
hooks implement the gap-fee mechanism that `src/VernierHook.sol` keeps as a measurement
baseline, and both were deployed from a key that is no longer trusted, so their owner
settings cannot be relied on.

| | Address |
|---|---|
| Gap-fee hook, v2 | `0x56399d47B53cdd89b0840A477602a4cC74AeC680` |
| Gap-fee hook, v1 | `0x42Fc745Bff704DbCC2C6e135404bdE5d0d004680` |
| Par hook, first deployment | `0xe16CC27ecAE859c1C7c07184A769a424D167C644` |

The first par-hook deployment is superseded only because `setRateBound` was added
afterwards, which changes the bytecode and therefore the mined address.
