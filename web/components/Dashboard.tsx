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
  MIN_SQRT_PRICE_PLUS_ONE,
  MAX_SQRT_PRICE_MINUS_ONE,
  signedGapPips,
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

const fadeUp = {
  hidden: { opacity: 0, y: 18 },
  show: { opacity: 1, y: 0, transition: { duration: 0.55, ease: "easeOut" } },
};

const stagger = {
  hidden: {},
  show: { transition: { staggerChildren: 0.09 } },
};

type Toast = { kind: "pending" | "ok" | "err"; text: string } | null;

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
      { address: ADDR.hook, abi: hookAbi, functionName: "poolRetention", args: [POOL_ID] },
      { address: ADDR.hook, abi: hookAbi, functionName: "lastRateOf", args: [POOL_ID] },
      { address: ADDR.vault, abi: vaultAbi, functionName: "rate" },
      { address: ADDR.stateView, abi: stateViewAbi, functionName: "getSlot0", args: [POOL_ID] },
    ],
    query: { refetchInterval: 4000 },
  });

  const retention = data?.[0]?.result as readonly [bigint, bigint, bigint] | undefined;
  const totalLiquidity = retention?.[1] ?? 0n;
  const totalRetained = retention?.[2] ?? 0n;
  const rate = (data?.[2]?.result as bigint | undefined) ?? 10n ** 18n;
  const slot0 = data?.[3]?.result as readonly [bigint, number, number, number] | undefined;

  const retainedNum = Number(formatUnits(totalRetained, 18));
  const rateNum = Number(formatUnits(rate, 18));
  const liqNum = Number(formatUnits(totalLiquidity, 18));
  const gapPct = slot0 ? Number(signedGapPips(slot0[0], rate)) / 10_000 : 0;
  const absGap = Math.abs(gapPct);
  const feePct = Math.min(absGap, 5);
  const poolAbovePar = gapPct > 0.0005;

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

  const accrue = () =>
    run("accrue", () =>
      writeContractAsync({
        address: ADDR.vault,
        abi: vaultAbi,
        functionName: "accrue",
        args: [2000n],
      }),
    );

  // trade toward par from whichever side the pool is on, so the demo swap
  // always captures the live gap
  const trade = () =>
    run("trade", () =>
      writeContractAsync({
        address: ADDR.swapRouter,
        abi: swapRouterAbi,
        functionName: "swap",
        args: [
          POOL_KEY,
          {
            zeroForOne: poolAbovePar,
            amountSpecified: -(10n ** 16n),
            sqrtPriceLimitX96: poolAbovePar ? MIN_SQRT_PRICE_PLUS_ONE : MAX_SQRT_PRICE_MINUS_ONE,
          },
        ],
      }),
    );

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

      <motion.section
        variants={stagger}
        initial="hidden"
        animate="show"
        className="mt-14 text-center"
      >
        <motion.div variants={fadeUp} className="flex justify-center">
          <span className="pill">
            <span className="dot-live" />
            Live on Unichain Sepolia
          </span>
        </motion.div>
        <motion.h1
          variants={fadeUp}
          className="mx-auto mt-6 max-w-3xl text-4xl font-semibold leading-tight tracking-tight sm:text-5xl"
        >
          The liquidity venue for <span className="grad-text">yield-bearing assets</span>
        </motion.h1>
        <motion.p variants={fadeUp} className="mx-auto mt-4 max-w-2xl text-white/60">
          Vernier reads each token&apos;s on-chain yield rate and prices it in real time, so the yield stays with
          liquidity providers instead of leaking to arbitrage bots.
        </motion.p>
        <motion.div variants={fadeUp} className="mt-7 flex justify-center gap-3">
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
        <PegMonitor gapPct={gapPct} feePct={feePct} rateNum={rateNum} />
      </motion.section>

      <motion.section
        variants={stagger}
        initial="hidden"
        whileInView="show"
        viewport={{ once: true, margin: "-60px" }}
        className="mt-6 grid gap-4 sm:grid-cols-2 lg:grid-cols-4"
      >
        <motion.div variants={fadeUp} className="card card-hero card-hover p-8">
          <div className="text-sm text-white/50">Yield retained for LPs</div>
          <div className="mt-2 font-mono text-3xl font-semibold text-mint">
            <Counter value={retainedNum} decimals={6} />
          </div>
          <div className="mt-1 text-xs text-white/40">captured on-chain, would leak to bots elsewhere</div>
        </motion.div>
        <Stat label="Current par rate" value={`${rateNum.toFixed(4)}×`} hint="from the token's own rate" />
        <Stat
          label="Pool gap from par"
          value={`${absGap.toFixed(3)}%`}
          hint="what an arbitrageur pays right now"
        />
        <Stat
          label="Pool liquidity"
          value={liqNum.toLocaleString(undefined, { maximumFractionDigits: 2 })}
          hint="active in range"
        />
      </motion.section>

      <motion.section
        variants={stagger}
        initial="hidden"
        whileInView="show"
        viewport={{ once: true, margin: "-60px" }}
        className="mt-10 grid gap-4 sm:grid-cols-3"
      >
        <Step
          n="01"
          title="Read par"
          body="The hook reads the yield token's own on-chain rate. No external oracle, nothing to manipulate."
        />
        <Step
          n="02"
          title="Price the gap"
          body="Every swap is checked against par. Trades that harvest the mispricing pay a fee equal to the gap they capture. Everyone else pays nothing extra."
        />
        <Step
          n="03"
          title="Pay it to LPs"
          body="The captured value accrues to in-range liquidity providers, weighted by real exposure. The yield stays with the people who fund the market."
        />
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
                Mint test tokens, let yield accrue, then trade and watch the retained number climb.
              </div>
            </div>
            <div className="flex flex-wrap gap-2">
              <button className="btn" disabled={!isConnected || wrongChain || !!busy} onClick={getTokens}>
                {busy === "tokens" ? "Minting…" : "Get test tokens"}
              </button>
              <button className="btn" disabled={!isConnected || wrongChain || !!busy} onClick={accrue}>
                {busy === "accrue" ? "Accruing…" : "Accrue yield +0.2%"}
              </button>
              <button className="btn btn-primary" disabled={!isConnected || wrongChain || !!busy} onClick={trade}>
                {busy === "trade" ? "Trading…" : "Trade → capture yield"}
              </button>
            </div>
          </div>
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
        <Addr label="VernierHook" addr={ADDR.hook} />
        <Addr label="Pool manager" addr={ADDR.poolManager} />
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

function PegMonitor({ gapPct, feePct, rateNum }: { gapPct: number; feePct: number; rateNum: number }) {
  const clamped = Math.max(-0.6, Math.min(0.6, gapPct));
  const pos = 50 + (clamped / 0.6) * 48;
  const above = gapPct > 0.0005;
  const below = gapPct < -0.0005;
  const fillLeft = Math.min(pos, 50);
  const fillWidth = Math.abs(pos - 50);

  return (
    <div className="card p-6 sm:p-8">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="flex items-center gap-2.5">
          <span className="dot-live" />
          <span className="font-medium">Peg monitor</span>
          <span className="text-sm text-white/40">pool price vs par, updated live</span>
        </div>
        <span className="font-mono text-sm text-white/60">par {rateNum.toFixed(4)} USDC</span>
      </div>

      <div className="relative mt-8 h-2 rounded-full bg-white/5">
        <motion.div
          className="absolute h-2 rounded-full bg-gradient-to-r from-mint/60 to-iris/60"
          animate={{ left: `${fillLeft}%`, width: `${fillWidth}%` }}
          transition={{ type: "spring", stiffness: 120, damping: 22 }}
        />
        <div className="absolute left-1/2 top-1/2 h-5 w-px -translate-x-1/2 -translate-y-1/2 bg-white/40" />
        <motion.div
          className="absolute top-1/2 -translate-x-1/2 -translate-y-1/2"
          animate={{ left: `${pos}%` }}
          transition={{ type: "spring", stiffness: 120, damping: 22 }}
        >
          <div className="h-4 w-4 rounded-full border-2 border-mint bg-[#05060b] shadow-[0_0_16px_rgba(94,234,212,0.6)]" />
        </motion.div>
      </div>

      <div className="mt-2 flex justify-between font-mono text-[11px] text-white/30">
        <span>-0.6%</span>
        <span className="text-white/50">par</span>
        <span>+0.6%</span>
      </div>

      <div className="mt-5 text-sm text-white/60">
        {above && (
          <>
            Pool trades <span className="font-mono text-mint">{Math.abs(gapPct).toFixed(3)}%</span> above par.
            Selling sYIELD captures the gap and pays a{" "}
            <span className="font-mono text-mint">{feePct.toFixed(3)}%</span> surcharge straight to LPs.
          </>
        )}
        {below && (
          <>
            Pool trades <span className="font-mono text-mint">{Math.abs(gapPct).toFixed(3)}%</span> below par.
            Buying sYIELD captures the gap and pays a{" "}
            <span className="font-mono text-mint">{feePct.toFixed(3)}%</span> surcharge straight to LPs.
          </>
        )}
        {!above && !below && (
          <>Pool is at par. No arbitrage exists right now, and regular trades pay nothing extra.</>
        )}
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

function Step({ n, title, body }: { n: string; title: string; body: string }) {
  return (
    <motion.div variants={fadeUp} className="card card-hover p-6">
      <div className="font-mono text-xs text-mint">{n}</div>
      <div className="mt-2 font-medium">{title}</div>
      <div className="mt-2 text-sm leading-relaxed text-white/55">{body}</div>
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
