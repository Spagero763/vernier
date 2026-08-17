import { defineChain } from "viem";

// the public endpoint works but is shared and rate limited, which is worst exactly
// when several people open the page at once. set NEXT_PUBLIC_RPC_URL to a dedicated
// one in any environment that matters.
export const RPC_URL = process.env.NEXT_PUBLIC_RPC_URL ?? "https://sepolia.unichain.org";

export const unichainSepolia = defineChain({
  id: 1301,
  name: "Unichain Sepolia",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: {
    default: { http: [RPC_URL] },
  },
  blockExplorers: {
    default: { name: "Uniscan", url: "https://sepolia.uniscan.xyz" },
  },
  testnet: true,
});
