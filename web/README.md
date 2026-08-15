# Carry web

Live dashboard for the Carry hook on Unichain Sepolia. Reads pool retention straight from the deployed contracts and lets you accrue yield and trade to watch the retained-yield number climb.

## Run

```
npm install
npm run dev
```

Open http://localhost:3000, connect a wallet on Unichain Sepolia, then use the demo panel.

## Notes

- Contract addresses live in `lib/contracts.ts`.
- The chain is defined in `lib/chain.ts` (Unichain Sepolia, id 1301).
- No API keys required; it reads the public RPC.
