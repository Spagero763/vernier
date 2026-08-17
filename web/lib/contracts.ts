export const ADDR = {
  poolManager: "0x00B036B58a818B1BC34d502D3fE730Db729e62AC",
  stateView: "0xc199f1072a74d4e905aba1a84d9a45e2546b6222",
  hook: "0x62e4C0D7E1c366a219006f6034acFaa65b6A0644",
  attestor: "0x3E663DE490271A1D8c2F2857d82c789c931F9B24",
  usdc: "0xff445090472ebDA1d5b4c9e9C6C56c82831E9697",
  syield: "0xCc18892E1ae1ECD127815916F90ce239d36e3D23",
  vault: "0xA029fE0c6dd9CCFA6ea9C6E1d6B5D6Fc3496EA14",
  rateSource: "0x7d06Bf495917062Fde1bB3Ace1F39C65a1aC923d",
  lpRouter: "0x7301548d7e76001255A089FD704b47F0D07d63ee",
  swapRouter: "0xf428f53Ab7e133C3d79d0f3dA6Cf6a9dc3D0277F",
} as const;

// same tokens, same fee, same spacing, same starting price: the only difference
// between these two pools is whether the hook is attached
export const POOL_ID =
  "0xf1c353d3744b932bba5bc1aec3093a77f3c50ff0df11fc8995d1b25f7bb0534c" as const;
export const BASELINE_POOL_ID =
  "0xbb5701c384855eb79ff6ced1c7921235f0c3b607886c86a9c96fba24fe0f4ec1" as const;

export const POOL_FEE = 500;
export const TICK_SPACING = 60;

// currency0 = sYIELD (lower address), currency1 = USDC
export const POOL_KEY = {
  currency0: ADDR.syield,
  currency1: ADDR.usdc,
  fee: POOL_FEE,
  tickSpacing: TICK_SPACING,
  hooks: ADDR.hook,
} as const;

export const BASELINE_POOL_KEY = {
  ...POOL_KEY,
  hooks: "0x0000000000000000000000000000000000000000",
} as const;

// the yield token sits on the currency0 side of this pool
export const YIELD_IS_CURRENCY1 = false;

export const MIN_SQRT_PRICE_PLUS_ONE = 4295128740n;
export const MAX_SQRT_PRICE_MINUS_ONE = 1461446703485210103287273052203988822378723970341n;

export const hookAbi = [
  {
    type: "function",
    name: "poolRetention",
    stateMutability: "view",
    inputs: [{ name: "id", type: "bytes32" }],
    outputs: [
      { name: "retained0", type: "uint256" },
      { name: "retained1", type: "uint256" },
    ],
  },
  {
    type: "function",
    name: "lastRateOf",
    stateMutability: "view",
    inputs: [{ name: "id", type: "bytes32" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "configOf",
    stateMutability: "view",
    inputs: [{ name: "id", type: "bytes32" }],
    outputs: [
      { name: "source", type: "address" },
      { name: "referenceRate", type: "uint256" },
      { name: "lastRateAt", type: "uint64" },
      { name: "maxRateAprPips", type: "uint24" },
      { name: "yieldIsCurrency1", type: "bool" },
      { name: "configured", type: "bool" },
    ],
  },
  {
    type: "function",
    name: "pendingRetention",
    stateMutability: "view",
    inputs: [
      { name: "id", type: "bytes32" },
      { name: "owner", type: "address" },
      { name: "tickLower", type: "int24" },
      { name: "tickUpper", type: "int24" },
      { name: "salt", type: "bytes32" },
    ],
    outputs: [
      { name: "amount0", type: "uint256" },
      { name: "amount1", type: "uint256" },
    ],
  },
] as const;

export const stateViewAbi = [
  {
    type: "function",
    name: "getSlot0",
    stateMutability: "view",
    inputs: [{ name: "poolId", type: "bytes32" }],
    outputs: [
      { name: "sqrtPriceX96", type: "uint160" },
      { name: "tick", type: "int24" },
      { name: "protocolFee", type: "uint24" },
      { name: "lpFee", type: "uint24" },
    ],
  },
  {
    type: "function",
    name: "getLiquidity",
    stateMutability: "view",
    inputs: [{ name: "poolId", type: "bytes32" }],
    outputs: [{ name: "liquidity", type: "uint128" }],
  },
  {
    type: "function",
    name: "getFeeGrowthGlobals",
    stateMutability: "view",
    inputs: [{ name: "poolId", type: "bytes32" }],
    outputs: [
      { name: "feeGrowthGlobal0", type: "uint256" },
      { name: "feeGrowthGlobal1", type: "uint256" },
    ],
  },
] as const;

export const attestorAbi = [
  {
    type: "function",
    name: "isSound",
    stateMutability: "view",
    inputs: [{ name: "id", type: "bytes32" }],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    type: "function",
    name: "attestationOf",
    stateMutability: "view",
    inputs: [{ name: "id", type: "bytes32" }],
    outputs: [
      { name: "sound", type: "bool" },
      { name: "at", type: "uint64" },
      { name: "nonce", type: "uint64" },
    ],
  },
] as const;

// how far the curve has gone stale against the rate the token publishes, in pips
// (1_000_000 = 100%). positive when the curve is underpricing the yield token,
// which is the side the hook corrects.
export function stalenessPips(referenceRate: bigint, rate: bigint): bigint {
  if (referenceRate === 0n || rate === 0n) return 0n;
  return ((rate - referenceRate) * 1_000_000n) / referenceRate;
}

// the ceiling the hook will accept from a single reading, given elapsed time.
// a reading past this is clamped rather than rejected, so the pool keeps pricing
// in the right direction without taking one report's word for a large move.
export function maxAcceptedPips(maxRateAprPips: bigint, elapsedSeconds: bigint): bigint {
  const YEAR = 31_536_000n;
  return (maxRateAprPips * elapsedSeconds) / YEAR;
}

export const vaultAbi = [
  {
    type: "function",
    name: "rate",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "accrue",
    stateMutability: "nonpayable",
    inputs: [{ name: "pips", type: "uint256" }],
    outputs: [],
  },
] as const;

export const erc20Abi = [
  {
    type: "function",
    name: "balanceOf",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "allowance",
    stateMutability: "view",
    inputs: [
      { name: "owner", type: "address" },
      { name: "spender", type: "address" },
    ],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "approve",
    stateMutability: "nonpayable",
    inputs: [
      { name: "spender", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    type: "function",
    name: "mint",
    stateMutability: "nonpayable",
    inputs: [
      { name: "to", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [],
  },
] as const;

const poolKeyTuple = {
  name: "key",
  type: "tuple",
  components: [
    { name: "currency0", type: "address" },
    { name: "currency1", type: "address" },
    { name: "fee", type: "uint24" },
    { name: "tickSpacing", type: "int24" },
    { name: "hooks", type: "address" },
  ],
} as const;

export const swapRouterAbi = [
  {
    type: "function",
    name: "swap",
    stateMutability: "nonpayable",
    inputs: [
      poolKeyTuple,
      {
        name: "params",
        type: "tuple",
        components: [
          { name: "zeroForOne", type: "bool" },
          { name: "amountSpecified", type: "int256" },
          { name: "sqrtPriceLimitX96", type: "uint160" },
        ],
      },
    ],
    outputs: [{ name: "", type: "int256" }],
  },
] as const;
