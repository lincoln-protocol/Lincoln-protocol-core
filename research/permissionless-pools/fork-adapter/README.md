# Fork proof: a third-party fee adapter

Shows that anyone, not only the Lincoln deployer, can deploy the RC.3 `Phase2FeeRouter02Adapter` and run an in-pool swap through it. The script runs only against a local Anvil fork of Robinhood mainnet. It sends no public transaction.

The script does six things:

1. A throwaway key deploys `Phase2FeeRouter02Adapter` for USDG pool → PONS pool on Uniswap V3 (fee tier 500) with a 30 bps service fee to a random treasury. The same deploy with fee tier 1800 reverts, because the adapter constructor rejects a path without a V3 pool.
2. A fresh user deposits 10 USDG into the live USDG pool (`depositDynamic`).
3. The ASP provider is impersonated to publish a root that contains this note. On mainnet this is the one step a third party cannot do.
4. The frontend SDK builds the fee-swap proof. The SDK action hash equals the adapter's `actionHash`.
5. A fresh gas wallet submits `swap` as the processor. The same calldata from another sender reverts.
6. The checks pass: the PONS pool gets one new note owned by the user, the USDG pool gets a 4 USDG change note, and the treasury receives the 30 bps fee in PONS.

## Run

The SDK, circuits and pool profiles come from a frontend checkout (default `../privacy-frontend` next to this repository; override with `LINCOLN_FRONTEND`). Node 22.18+ runs the TypeScript directly.

```sh
cd research/permissionless-pools/fork-adapter
forge build                      # RC.3 fee adapter from releases/rc3, same runtime bytecode as the 2026-10-18 run
anvil --fork-url https://rpc.mainnet.chain.robinhood.com/ --chain-id 4663 --port 8547 --silent &
node run.mts                     # writes result.json (ignored)
```

## Recorded runs

| File | Fork | Swap | Gas |
| --- | --- | --- | --- |
| [result-2026-10-18.json](result-2026-10-18.json) | USDG pool at 4 leaves | 6 USDG → 20.997 PONS net, 0.0632 PONS fee | adapter deploy 3.32M, swap 2.10M |
| [result-2026-10-20.json](result-2026-10-20.json) | USDG pool at 111 leaves | 6 USDG → 20.585 PONS net, 0.0619 PONS fee | proof 1.2 s in Node |

## What this proves and what it does not

- The adapter has no owner and no allowlist. Any address can deploy it for any pair of existing pools that has a V3 path.
- The pool accepts the swap from any processor. Neither the relay nor the deployer is needed.
- The ASP is still a gate. On mainnet a note is spendable only after the publisher includes `H(commitment, SCOPE)` in a root, and the publisher only covers the pools it is configured for.
- Nothing here creates a pool. See [../DESIGN.md](../DESIGN.md) for making pool creation permissionless.
