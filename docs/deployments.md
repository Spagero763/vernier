# Deployments

## Unichain Sepolia (chain id 1301)

| Contract | Address |
|---|---|
| VernierParHook | `0x80e4a79F2297E3CcE4F68ae535b2508187C6c644` |
| RateAttestationService | `0x415302aDd60A138c872E07019Dc9E0a77b284292` |
| sYIELD (demo yield token, currency1) | `0x5E393971a6C79D49F7F27C4e35bD7a18165cC0fb` |
| USDC (demo quote token, currency0) | `0x1b161c7dAA60bFd42c12eAAe2210bC055AC96D67` |
| Vault (backs the rate) | `0xf8Cf91F9d820374e72caBEA49E0e7bD64d5a9345` |
| RateSource (ERC-4626 adapter) | `0x341c510298D21C2D0464087C3160e10B37ef88c2` |
| PoolManager (Uniswap v4) | `0x00B036B58a818B1BC34d502D3fE730Db729e62AC` |
| StateView (Uniswap v4 lens) | `0xc199f1072a74d4e905aba1a84d9a45e2546b6222` |

Helper routers:

| Contract | Address |
|---|---|
| PoolModifyLiquidityTest | `0x19246A056E51D66BD04055E9824fb0910959E1B2` |
| VernierSwapRouter | `0xE5C05645Ffcda29616A5981aDc4E3e260Ad442b2` |

The hook address ends in `c644`. That is not cosmetic: v4 reads a hook's permissions
from its address, and `0x644` is `AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA |
AFTER_ADD_LIQUIDITY | BEFORE_REMOVE_LIQUIDITY`, which is why deployment mines a salt.

### The two pools

Both hold the same pair at the same fee, spacing and starting price. The only difference
is whether the hook is attached, so the comparison can be read off-chain instead of taken
on trust.

| | Pool id |
|---|---|
| Vernier | `0xf06ea22d2843e36aab79cad40eac4a36953fc1a1a4ae7160ffa3cda24e9e99ed` |
| Baseline, no hook | `0x38ca13d084484b6057c433c1e6497b85fbf2f1da670c87bf269e38f925566e03` |

currency0 USDC, currency1 sYIELD, static fee 500, tick spacing 60,
`yieldIsCurrency1 = true`.

Pool configuration: rate source as above, reference rate `1e18`, `maxRateAprPips`
200000 (20% APR), attestor attached, `PoolModifyLiquidityTest` trusted so it can name
the real position owner in `hookData`.

Deployment funds both pools. A pool with nothing in range has nothing to trade against,
so the first swap walks the price to the tick limit and pins it there with no liquidity
left to trade back through. Bringing a pool up empty is not a recoverable state.

RPC: `https://sepolia.unichain.org`
Explorer: `https://unichain-sepolia.blockscout.com`

### Verified source

Every contract is verified, so the live configuration can be read from the explorer
without an RPC or the dashboard. `configOf` gives the reference rate and the APR bound,
`lastRateOf` gives the rate actually accepted after clamping.

| Contract | |
|---|---|
| VernierParHook | https://unichain-sepolia.blockscout.com/address/0x80e4a79F2297E3CcE4F68ae535b2508187C6c644 |
| RateAttestationService | https://unichain-sepolia.blockscout.com/address/0x415302aDd60A138c872E07019Dc9E0a77b284292 |
| ERC4626RateSource | https://unichain-sepolia.blockscout.com/address/0x341c510298D21C2D0464087C3160e10B37ef88c2 |
| VernierSwapRouter | https://unichain-sepolia.blockscout.com/address/0xE5C05645Ffcda29616A5981aDc4E3e260Ad442b2 |
| MockYieldVault | https://unichain-sepolia.blockscout.com/address/0xf8Cf91F9d820374e72caBEA49E0e7bD64d5a9345 |

Re-verify after a redeploy with:

```
forge verify-contract <address> <path>:<Contract>   --verifier blockscout   --verifier-url https://unichain-sepolia.blockscout.com/api   --constructor-args $(cast abi-encode "constructor(...)" ...)   --compiler-version 0.8.26 --watch
```

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
