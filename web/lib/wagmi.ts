import { createConfig, http } from "wagmi";
import { injected } from "wagmi/connectors";
import { unichainSepolia } from "./chain";

export const wagmiConfig = createConfig({
  chains: [unichainSepolia],
  connectors: [injected()],
  transports: {
    [unichainSepolia.id]: http("https://sepolia.unichain.org"),
  },
  ssr: true,
});
