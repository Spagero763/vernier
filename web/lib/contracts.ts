export const ADDR = {
  poolManager: "0x00B036B58a818B1BC34d502D3fE730Db729e62AC",
  stateView: "0xc199f1072a74d4e905aba1a84d9a45e2546b6222",
  hook: "0x56399d47B53cdd89b0840A477602a4cC74AeC680",
  usdc: "0x8494B7d150c1a32Af256dDe48aF4b676b4E56894",
  syield: "0x7a7C98591E98E1F80ac4D9d5E86dDfD59da4079F",
  vault: "0xeaafc02bd710989fb3fD20C4eAa29e64796ea3f3",
  rateSource: "0x30747A302528ad95986a00E43309C3Efed2Af207",
  // stateless helper routers, reusable across pools on the same PoolManager
  lpRouter: "0xfEC4087C2a9e87C3205c137bf4fFcd50bbA25c39",
  swapRouter: "0xC43A265B6AA1627264a07206eBc61B833477d7bd",
} as const;

export const POOL_ID =
  "0xfe9bc2ce73e72c31ddf85953ec09b757d202050bdde25fed7949997fc9c13e84" as const;

// currency0 = sYIELD (lower address), currency1 = USDC
export const POOL_KEY = {
  currency0: ADDR.syield,
  currency1: ADDR.usdc,
  fee: 8388608, // DYNAMIC_FEE_FLAG
  tickSpacing: 60,
  hooks: ADDR.hook,
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
      { name: "accPerLiquidity", type: "uint256" },
      { name: "totalLiquidity", type: "uint256" },
      { name: "totalRetained", type: "uint256" },
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
    name: "pendingRetention",
    stateMutability: "view",
    inputs: [
      { name: "id", type: "bytes32" },
      { name: "owner", type: "address" },
      { name: "tickLower", type: "int24" },
      { name: "tickUpper", type: "int24" },
      { name: "salt", type: "bytes32" },
    ],
    outputs: [{ name: "", type: "uint256" }],
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
] as const;

// signed gap between the pool price and the par price implied by the yield
// token's rate, in pips (1_000_000 = 100%). positive when the pool trades
// above par. mirrors the hook's fee computation.
export function signedGapPips(sqrtPriceX96: bigint, rate: bigint): bigint {
  if (sqrtPriceX96 === 0n || rate === 0n) return 0n;
  const Q96 = 2n ** 96n;
  const priceX96 = (sqrtPriceX96 * sqrtPriceX96) / Q96;
  const pool = (priceX96 * 10n ** 18n) / Q96;
  const fair = YIELD_IS_CURRENCY1 ? 10n ** 36n / rate : rate;
  if (pool === 0n || fair === 0n) return 0n;
  return pool > fair
    ? ((pool - fair) * 1_000_000n) / fair
    : -(((fair - pool) * 1_000_000n) / pool);
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
