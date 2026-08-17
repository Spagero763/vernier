import { createConfig, http } from "wagmi";
import { injected } from "wagmi/connectors";
import { unichainSepolia, RPC_URL } from "./chain";

export const wagmiConfig = createConfig({
  chains: [unichainSepolia],
  connectors: [injected()],
  transports: {
    [unichainSepolia.id]: http(RPC_URL),
  },
  ssr: true,
});
