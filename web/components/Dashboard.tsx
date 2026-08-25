"use client";

import { AnimatePresence, motion } from "framer-motion";
import { formatUnits, parseUnits } from "viem";
import {
  useAccount,
  useConnect,
  useDisconnect,
  useReadContracts,
  useSwitchChain,
  useWriteContract,
} from "wagmi";
import { waitForTransactionReceipt } from "wagmi/actions";
import { useState } from "react";
import { injected } from "wagmi/connectors";
import { wagmiConfig } from "@/lib/wagmi";
import { unichainSepolia } from "@/lib/chain";
import {
  ADDR,
  POOL_ID,
  POOL_KEY,
  BASELINE_POOL_ID,
  BASELINE_POOL_KEY,
  MIN_SQRT_PRICE_PLUS_ONE,
  stalenessPips,
  maxAcceptedPips,
  hookAbi,
  stateViewAbi,
  vaultAbi,
  erc20Abi,
  swapRouterAbi,
} from "@/lib/contracts";
import { Counter } from "./Counter";
import { Logo } from "./Logo";

const short = (a: string) => `${a.slice(0, 6)}…${a.slice(-4)}`;
const EXPLORER = unichainSepolia.blockExplorers.default.url;
const Q128 = 2n ** 128n;

const fadeUp = {
  hidden: { opacity: 0, y: 18 },
  show: { opacity: 1, y: 0, transition: { duration: 0.55, ease: "easeOut" } },
};

const stagger = {
  hidden: {},
  show: { transition: { staggerChildren: 0.09 } },
};

type Toast = { kind: "pending" | "ok" | "err"; text: string } | null;

// fee growth is per unit of liquidity, scaled by 2^128
const earned = (growth: bigint, liquidity: bigint) => (growth * liquidity) / Q128;

export function Dashboard() {
  const { address, isConnected, chainId } = useAccount();
  const { connect } = useConnect();
  const { disconnect } = useDisconnect();
  const { switchChain } = useSwitchChain();
  const { writeContractAsync } = useWriteContract();
  const [busy, setBusy] = useState<string | null>(null);
  const [toast, setToast] = useState<Toast>(null);

  const wrongChain = isConnected && chainId !== unichainSepolia.id;

  const { data, refetch } = useReadContracts({
    contracts: [
      { address: ADDR.stateView, abi: stateViewAbi, functionName: "getFeeGrowthGlobals", args: [POOL_ID] },
      { address: ADDR.stateView, abi: stateViewAbi, functionName: "getFeeGrowthGlobals", args: [BASELINE_POOL_ID] },
      { address: ADDR.stateView, abi: stateViewAbi, functionName: "getLiquidity", args: [POOL_ID] },
      { address: ADDR.stateView, abi: stateViewAbi, functionName: "getLiquidity", args: [BASELINE_POOL_ID] },
      { address: ADDR.hook, abi: hookAbi, functionName: "configOf", args: [POOL_ID] },
      { address: ADDR.hook, abi: hookAbi, functionName: "lastRateOf", args: [POOL_ID] },
      { address: ADDR.vault, abi: vaultAbi, functionName: "rate" },
    ],
    query: { refetchInterval: 4000 },
  });

  const vernGrowth = data?.[0]?.result as readonly [bigint, bigint] | undefined;
  const baseGrowth = data?.[1]?.result as readonly [bigint, bigint] | undefined;
  const vernLiq = (data?.[2]?.result as bigint | undefined) ?? 0n;
  const baseLiq = (data?.[3]?.result as bigint | undefined) ?? 0n;
  const config = data?.[4]?.result as
    | readonly [string, bigint, bigint, number, boolean, boolean]
    | undefined;
  const accepted = (data?.[5]?.result as bigint | undefined) ?? 10n ** 18n;
  const reported = (data?.[6]?.result as bigint | undefined) ?? 10n ** 18n;

  const referenceRate = config?.[1] ?? 10n ** 18n;
  const lastRateAt = config?.[2] ?? 0n;
  const maxAprPips = BigInt(config?.[3] ?? 0);

  // the yield token is currency1 here, so the corrected leg is index 1
  const vernYield = vernGrowth ? earned(vernGrowth[1], vernLiq) : 0n;
  const baseYield = baseGrowth ? earned(baseGrowth[1], baseLiq) : 0n;
  const vernQuote = vernGrowth ? earned(vernGrowth[0], vernLiq) : 0n;
  const baseQuote = baseGrowth ? earned(baseGrowth[0], baseLiq) : 0n;

  // a pool with nothing in range has nothing to trade against, so a swap walks the
  // price to the tick limit and pins it there for good. never offer that trade.
  const poolsFunded = vernLiq > 0n && baseLiq > 0n;

  const keptNum = Number(formatUnits(vernYield - baseYield, 18));
  const acceptedPct = Number(stalenessPips(referenceRate, accepted)) / 10_000;
  const reportedPct = Number(stalenessPips(referenceRate, reported)) / 10_000;
  const clamped = reported > accepted;

  const nowSec = BigInt(Math.floor(Date.now() / 1000));
  const elapsed = lastRateAt > 0n && nowSec > lastRateAt ? nowSec - lastRateAt : 0n;
  const headroomPct = Number(maxAcceptedPips(maxAprPips, elapsed)) / 10_000;

  async function run(label: string, fn: () => Promise<`0x${string}`>) {
    try {
      setBusy(label);
      setToast({ kind: "pending", text: "Confirm in your wallet, then waiting on-chain" });
      const hash = await fn();
      await waitForTransactionReceipt(wagmiConfig, { hash });
      await refetch();
      setToast({ kind: "ok", text: "Confirmed on Unichain Sepolia" });
      setTimeout(() => setToast((t) => (t?.kind === "ok" ? null : t)), 3500);
    } catch (e) {
      console.error(e);
      setToast({ kind: "err", text: "Transaction failed or was rejected" });
      setTimeout(() => setToast((t) => (t?.kind === "err" ? null : t)), 4000);
    } finally {
      setBusy(null);
    }
  }

  const getTokens = () =>
    run("tokens", async () => {
      const steps = [
        () =>
          writeContractAsync({
            address: ADDR.usdc,
            abi: erc20Abi,
            functionName: "mint",
            args: [address!, parseUnits("1000", 18)],
          }),
        () =>
          writeContractAsync({
            address: ADDR.syield,
            abi: erc20Abi,
            functionName: "mint",
            args: [address!, parseUnits("1000", 18)],
          }),
        () =>
          writeContractAsync({
            address: ADDR.usdc,
            abi: erc20Abi,
            functionName: "approve",
            args: [ADDR.swapRouter, 2n ** 255n],
          }),
      ];
      for (const step of steps) {
        const h = await step();
        await waitForTransactionReceipt(wagmiConfig, { hash: h });
      }
      return writeContractAsync({
        address: ADDR.syield,
        abi: erc20Abi,
        functionName: "approve",
        args: [ADDR.swapRouter, 2n ** 255n],
      });
    });

  // accrue only what elapsed time can justify, so the demo shows the correction
  // rather than the bound refusing an impossible rate
  const accrue = () =>
    run("accrue", () => {
      const pips = maxAcceptedPips(maxAprPips, elapsed) / 2n;
      return writeContractAsync({
        address: ADDR.vault,
        abi: vaultAbi,
        functionName: "accrue",
        args: [pips > 0n ? pips : 1n],
      });
    });

  // buying the yield token is the side a stale curve favours, so it is the side
  // the hook corrects
  const tradeBoth = () =>
    run("trade", async () => {
      const params = {
        zeroForOne: true,
        amountSpecified: -(10n ** 16n),
        sqrtPriceLimitX96: MIN_SQRT_PRICE_PLUS_ONE,
      } as const;

      const h = await writeContractAsync({
        address: ADDR.swapRouter,
        abi: swapRouterAbi,
        functionName: "swap",
        args: [BASELINE_POOL_KEY, params],
      });
      await waitForTransactionReceipt(wagmiConfig, { hash: h });

      return writeContractAsync({
        address: ADDR.swapRouter,
        abi: swapRouterAbi,
        functionName: "swap",
        args: [POOL_KEY, params],
      });
    });

  return (
    <main className="mx-auto max-w-5xl px-5 pb-16">
      <header className="sticky top-0 z-40 -mx-5 mb-4 border-b border-white/5 bg-[#05060b]/70 px-5 py-4 backdrop-blur-xl">
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-3">
            <Logo className="h-9 w-9" />
            <span className="text-lg font-semibold tracking-tight">Vernier</span>
          </div>
          {isConnected ? (
            <div className="flex items-center gap-2">
              {wrongChain && (
                <button
                  className="btn btn-primary text-sm"
                  onClick={() => switchChain({ chainId: unichainSepolia.id })}
                >
                  Switch to Unichain Sepolia
                </button>
              )}
              <span className="rounded-lg border border-line px-3 py-2 font-mono text-sm text-white/70">
                {short(address!)}
              </span>
              <button className="btn text-sm" onClick={() => disconnect()}>
                Disconnect
              </button>
            </div>
          ) : (
            <button className="btn btn-primary" onClick={() => connect({ connector: injected() })}>
              Connect wallet
            </button>
          )}
        </div>
      </header>

      <motion.section variants={stagger} initial="hidden" animate="show" className="mt-20 text-center">
        <motion.h1
          variants={fadeUp}
          className="mx-auto mt-6 max-w-3xl text-4xl font-semibold leading-tight tracking-tight sm:text-5xl"
        >
          Your pool is quoting yesterday&apos;s price
        </motion.h1>
        <motion.p variants={fadeUp} className="mx-auto mt-4 max-w-2xl text-white/60">
          A yield-bearing token publishes the rate at which it appreciates. The pool holding it does not
          read that rate, so it keeps quoting the old price until someone buys the difference. Vernier
          corrects the curve by exactly the amount the token has already announced.
        </motion.p>
        <motion.div variants={fadeUp} className="mt-7 flex justify-center gap-3">
          {isConnected && !poolsFunded && (
            <div className="mt-3 text-sm text-amber-300/70">
              Pools are unfunded, so trading is disabled. A swap against an empty pool
              walks the price to the tick limit and cannot be undone.
            </div>
          )}
          {!isConnected && (
            <button className="btn btn-primary" onClick={() => connect({ connector: injected() })}>
              Connect wallet
            </button>
          )}
          <a href="#demo" className="btn">
            Run the live demo
          </a>
        </motion.div>
      </motion.section>

      <motion.section
        variants={fadeUp}
        initial="hidden"
        whileInView="show"
        viewport={{ once: true, margin: "-60px" }}
        className="mt-12"
      >
        <HeadToHead
          vernYield={Number(formatUnits(vernYield, 18))}
          baseYield={Number(formatUnits(baseYield, 18))}
          vernQuote={Number(formatUnits(vernQuote, 18))}
          baseQuote={Number(formatUnits(baseQuote, 18))}
        />
      </motion.section>

      <motion.section
        variants={stagger}
        initial="hidden"
        whileInView="show"
        viewport={{ once: true, margin: "-60px" }}
        className="mt-6 grid gap-4 sm:grid-cols-2 lg:grid-cols-4"
      >
        <motion.div variants={fadeUp} className="card card-hero card-hover p-8">
          <div className="text-sm text-white/50">Accrual kept by LPs</div>
          <div className="mt-2 font-mono text-3xl font-semibold text-mint">
            <Counter value={keptNum} decimals={9} />
          </div>
          <div className="mt-1 text-xs text-white/40">sYIELD the identical bare pool gave away</div>
        </motion.div>
        <Stat
          label="Curve staleness"
          value={`${acceptedPct.toFixed(4)}%`}
          hint="priced in, against the reference rate"
        />
        <Stat
          label="Plausibility headroom"
          value={`${headroomPct.toFixed(4)}%`}
          hint={`what ${(Number(maxAprPips) / 10_000).toFixed(0)}% APR justifies by now`}
        />
        <Stat
          label="Reported rate"
          value={`${(Number(formatUnits(reported, 18))).toFixed(6)}×`}
          hint={clamped ? "ahead of what the bound accepts" : "within the bound"}
        />
      </motion.section>

      {clamped && (
        <motion.section
          variants={fadeUp}
          initial="hidden"
          animate="show"
          className="mt-4"
        >
          <div className="card border-amber-400/30 p-5">
            <div className="flex items-center gap-2.5">
              <span className="h-2 w-2 rounded-full bg-amber-400" />
              <span className="font-medium">Rate clamped</span>
            </div>
            <div className="mt-2 text-sm text-white/60">
              The source reports <span className="font-mono text-white/80">{reportedPct.toFixed(4)}%</span> of
              appreciation, more than elapsed time can justify at the configured bound. Vernier is pricing{" "}
              <span className="font-mono text-mint">{acceptedPct.toFixed(4)}%</span> and will track the rest as
              time passes, rather than taking one reading&apos;s word for a large move.
            </div>
          </div>
        </motion.section>
      )}

      <motion.section
        variants={stagger}
        initial="hidden"
        whileInView="show"
        viewport={{ once: true, margin: "-60px" }}
        className="mt-10"
      >
        <motion.div variants={fadeUp} className="card p-6 sm:p-8">
          <div className="max-w-3xl space-y-4 text-sm leading-relaxed text-white/60">
            <p>
              The rate comes from the token itself, <span className="font-mono text-white/80">convertToAssets</span> on
              an ERC-4626 share or pooled ETH per share on stETH. No feed, no keeper, and nothing that trading
              pressure can move.
            </p>
            <p>
              Accrual makes the curve stale by a factor that is already public, so the hook applies that factor
              rather than quoting a target price. Quoting par outright would make this a fixed-price maker, and
              the first time the token traded at a discount it would be drained. Correcting by a factor leaves
              genuine market moves on the curve where they belong.
            </p>
            <p>
              The correction lands on the leg the swapper did not specify, so neither exact input nor exact
              output routes around it, and it settles through{" "}
              <span className="font-mono text-white/80">donate</span> so v4 splits it across in-range liquidity
              on its own terms.
            </p>
          </div>
        </motion.div>
      </motion.section>

      <motion.section
        id="demo"
        variants={fadeUp}
        initial="hidden"
        whileInView="show"
        viewport={{ once: true, margin: "-60px" }}
        className="mt-4 scroll-mt-24"
      >
        <div className="card p-6">
          <div className="flex flex-wrap items-center justify-between gap-4">
            <div>
              <div className="font-medium">Live demo</div>
              <div className="text-sm text-white/50">
                Mint test tokens, accrue what elapsed time allows, then run the same trade against both pools.
              </div>
            </div>
            <div className="flex flex-wrap gap-2">
              <button className="btn" disabled={!isConnected || wrongChain || !!busy} onClick={getTokens}>
                {busy === "tokens" ? "Minting…" : "Get test tokens"}
              </button>
              <button className="btn" disabled={!isConnected || wrongChain || !!busy} onClick={accrue}>
                {busy === "accrue" ? "Accruing…" : "Accrue yield"}
              </button>
              <button
                className="btn btn-primary"
                disabled={!isConnected || wrongChain || !!busy || !poolsFunded}
                onClick={tradeBoth}
              >
                {busy === "trade" ? "Trading…" : "Trade both pools"}
              </button>
            </div>
          </div>
          {isConnected && !poolsFunded && (
            <div className="mt-3 text-sm text-amber-300/70">
              Pools are unfunded, so trading is disabled. A swap against an empty pool
              walks the price to the tick limit and cannot be undone.
            </div>
          )}
          {!isConnected && (
            <div className="mt-3 text-sm text-white/40">Connect a wallet on Unichain Sepolia to run the demo.</div>
          )}
        </div>
      </motion.section>

      <motion.section
        variants={stagger}
        initial="hidden"
        whileInView="show"
        viewport={{ once: true, margin: "-40px" }}
        className="mt-8 grid gap-3 text-sm sm:grid-cols-2"
      >
        <Addr label="VernierParHook" addr={ADDR.hook} />
        <Addr label="Rate attestation service" addr={ADDR.attestor} />
        <Addr label="Yield token (sYIELD)" addr={ADDR.syield} />
        <Addr label="Rate source" addr={ADDR.rateSource} />
      </motion.section>

      <footer className="mt-10 flex items-center justify-center gap-2 text-xs text-white/30">
        <span>Built on Uniswap v4</span>
        <span>·</span>
        <span>Unichain Sepolia</span>
        <span>·</span>
        <a
          href={`${EXPLORER}/address/${ADDR.hook}`}
          target="_blank"
          rel="noreferrer"
          className="font-mono transition hover:text-white/60"
        >
          pool {short(POOL_ID)}
        </a>
      </footer>

      <AnimatePresence>
        {toast && (
          <motion.div
            initial={{ opacity: 0, y: 24, scale: 0.96 }}
            animate={{ opacity: 1, y: 0, scale: 1 }}
            exit={{ opacity: 0, y: 24, scale: 0.96 }}
            transition={{ duration: 0.25, ease: "easeOut" }}
            className="fixed bottom-6 left-1/2 z-50 -translate-x-1/2"
          >
            <div className="card flex items-center gap-3 px-5 py-3 text-sm">
              {toast.kind === "pending" && (
                <span className="h-3.5 w-3.5 animate-spin rounded-full border-2 border-white/20 border-t-mint" />
              )}
              {toast.kind === "ok" && <span className="dot-live" />}
              {toast.kind === "err" && <span className="h-2 w-2 rounded-full bg-red-400" />}
              <span className="text-white/80">{toast.text}</span>
            </div>
          </motion.div>
        )}
      </AnimatePresence>
    </main>
  );
}

function HeadToHead({
  vernYield,
  baseYield,
  vernQuote,
  baseQuote,
}: {
  vernYield: number;
  baseYield: number;
  vernQuote: number;
  baseQuote: number;
}) {
  const max = Math.max(vernYield, baseYield, 1e-12);

  return (
    <div className="card p-6 sm:p-8">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="flex items-center gap-2.5">
          <span className="font-medium">Two pools, one difference</span>
          <span className="text-sm text-white/40">same pair, fee, spacing and start price</span>
        </div>
        <span className="font-mono text-sm text-white/40">earned per LP position, sYIELD</span>
      </div>

      <div className="mt-7 space-y-5">
        <Bar label="Vernier" value={vernYield} max={max} tone="mint" />
        <Bar label="No hook" value={baseYield} max={max} tone="dim" />
      </div>

      <div className="mt-6 grid gap-3 border-t border-white/5 pt-5 text-sm sm:grid-cols-2">
        <div className="text-white/50">
          Quote-leg fees are the ordinary swap fee and land on both:{" "}
          <span className="font-mono text-white/70">{vernQuote.toFixed(9)}</span> against{" "}
          <span className="font-mono text-white/70">{baseQuote.toFixed(9)}</span> USDC.
        </div>
        <div className="text-white/50">
          The yield leg is the whole claim. Only the hooked pool keeps the accrual; the bare pool hands it to
          whoever trades first.
        </div>
      </div>
    </div>
  );
}

function Bar({ label, value, max, tone }: { label: string; value: number; max: number; tone: "mint" | "dim" }) {
  const pct = Math.max(1.5, (value / max) * 100);
  return (
    <div>
      <div className="flex items-baseline justify-between">
        <span className="text-sm text-white/60">{label}</span>
        <span className={`font-mono text-sm ${tone === "mint" ? "text-mint" : "text-white/40"}`}>
          {value.toFixed(9)}
        </span>
      </div>
      <div className="mt-2 h-2.5 rounded-full bg-white/5">
        <motion.div
          className={`h-2.5 rounded-full ${
            tone === "mint" ? "bg-gradient-to-r from-mint/70 to-iris/70" : "bg-white/15"
          }`}
          initial={{ width: 0 }}
          animate={{ width: `${pct}%` }}
          transition={{ type: "spring", stiffness: 90, damping: 20 }}
        />
      </div>
    </div>
  );
}

function Stat({ label, value, hint }: { label: string; value: string; hint: string }) {
  return (
    <motion.div variants={fadeUp} className="card card-hover p-8">
      <div className="text-sm text-white/50">{label}</div>
      <div className="mt-2 font-mono text-3xl font-semibold">{value}</div>
      <div className="mt-1 text-xs text-white/40">{hint}</div>
    </motion.div>
  );
}

function Addr({ label, addr }: { label: string; addr: string }) {
  return (
    <motion.a
      variants={fadeUp}
      href={`${EXPLORER}/address/${addr}`}
      target="_blank"
      rel="noreferrer"
      className="card flex items-center justify-between p-4 transition hover:border-mint/40"
    >
      <span className="text-white/60">{label}</span>
      <span className="font-mono text-white/80">{short(addr)}</span>
    </motion.a>
  );
}
