# Deployments

## Unichain Sepolia (chain id 1301) - current (mechanism v2)

| Contract | Address |
|---|---|
| CarryHook | `0x56399d47B53cdd89b0840A477602a4cC74AeC680` |
| PoolManager (Uniswap v4) | `0x00B036B58a818B1BC34d502D3fE730Db729e62AC` |
| StateView (Uniswap v4 lens) | `0xc199f1072a74d4e905aba1a84d9a45e2546b6222` |
| sYIELD (demo yield token, currency0) | `0x7a7C98591E98E1F80ac4D9d5E86dDfD59da4079F` |
| USDC (demo token, currency1) | `0x8494B7d150c1a32Af256dDe48aF4b676b4E56894` |
| Vault (rate backing) | `0xeaafc02bd710989fb3fD20C4eAa29e64796ea3f3` |
| RateSource (ERC-4626 adapter) | `0x30747A302528ad95986a00E43309C3Efed2Af207` |

Pool id: `0xfe9bc2ce73e72c31ddf85953ec09b757d202050bdde25fed7949997fc9c13e84`
Pool: currency0 sYIELD, currency1 USDC, dynamic fee, tick spacing 60, `yieldIsCurrency1 = false`.

Helper routers (stateless, shared across deployments):

| Contract | Address |
|---|---|
| PoolModifyLiquidityTest | `0xfEC4087C2a9e87C3205c137bf4fFcd50bbA25c39` |
| CarrySwapRouter | `0xC43A265B6AA1627264a07206eBc61B833477d7bd` |

RPC: `https://sepolia.unichain.org`
Explorer: `https://sepolia.uniscan.xyz`

### Reproduce

```
forge script script/Deploy.s.sol:Deploy --rpc-url https://sepolia.unichain.org --account <keystore> --sender <deployer> --broadcast --slow
```

Seed liquidity and a first arb-direction swap (env vars select the target deployment):

```
CARRY_HOOK=0x56399d47B53cdd89b0840A477602a4cC74AeC680 \
CARRY_USDC=0x8494B7d150c1a32Af256dDe48aF4b676b4E56894 \
CARRY_SYIELD=0x7a7C98591E98E1F80ac4D9d5E86dDfD59da4079F \
CARRY_VAULT=0xeaafc02bd710989fb3fD20C4eAa29e64796ea3f3 \
forge script script/Seed.s.sol:Seed --rpc-url https://sepolia.unichain.org --account <keystore> --sender <deployer> --broadcast --slow
```

## Prior deployment (mechanism v1, superseded)

| Contract | Address |
|---|---|
| CarryHook v1 | `0x42Fc745Bff704DbCC2C6e135404bdE5d0d004680` |
| USDC | `0x2Ac1c021461eAA17A4cfef7C8E1d7910D9618C80` |
| sYIELD | `0x6bc261d74528D41ac76C9d192BD6E11e707C0733` |
| Vault | `0x3611D872EC05DFae793530973EF4e68bac947ad0` |
| RateSource | `0x68f5458cd99C08aE9DDe1a047a71D8b1C517d9b0` |

v1 pool id: `0xd0ebf09b79282fc1091bed02f942a752ea3e8dfd5fb291298aaafe40cb521dba`. Kept for history; v1 charged the fee from the rate delta since the last swap, which v2 replaces with the live pool-vs-par gap.
