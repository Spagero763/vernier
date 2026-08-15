import type { Metadata } from "next";
import { Inter, JetBrains_Mono } from "next/font/google";
import "./globals.css";
import { Providers } from "./providers";

const inter = Inter({ subsets: ["latin"], variable: "--font-sans", display: "swap" });
const jetbrains = JetBrains_Mono({ subsets: ["latin"], variable: "--font-mono", display: "swap" });

export const metadata: Metadata = {
  title: "Vernier | The liquidity venue for yield-bearing assets",
  description:
    "Vernier reads each yield-bearing token's on-chain rate and prices it in real time, so accrued yield goes to liquidity providers instead of leaking to arbitrage.",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className={`${inter.variable} ${jetbrains.variable}`}>
      <body className="font-sans">
        <div className="bg-fx" aria-hidden />
        <div className="bg-grid" aria-hidden />
        <Providers>{children}</Providers>
      </body>
    </html>
  );
}
