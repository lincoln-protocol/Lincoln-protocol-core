# Fork proof: private buy and sell through a Uniswap v4 pool

[`Phase2FeeV4Adapter`](../src/Phase2FeeV4Adapter.sol) routes a note through one Uniswap v4 pool on Robinhood Chain (PoolManager `0x8366a39CC670B4001A1121B8F6A443A643e40951`). It keeps the RC.3 fee adapter's `Action`/`Proof`/`ExtData` shapes, `swap` signature, events and 256-byte envelope. The domain is new: `LINCOLN_PHASE2_FEE_V4_ROUTES_V1`. Any PoolKey works, including native ETH as currency0, any fee tier and any hook. Deploy one adapter per direction.

[`v4.mts`](v4.mts) runs only against a local anvil fork. It sends nothing to the real network. Here is what it does:

1. Recomputes the PoolId and reads slot0 and liquidity from PoolManager storage (`extsload`).
2. Opens a fresh RC.3 `Phase2ASPPool` for the meme. Its ASP is an `AutoApproveProvider` plus a `ScreeningList` from [`../../auto-asp`](../../auto-asp/README.md), wired the same way `auto-asp/run.mts` wires them. The Poseidon libraries are linked to the mainnet copies.
3. Deploys a buy adapter (live ETH pool → meme pool) and a sell adapter (meme pool → live ETH pool). The Safe marks the buy adapter as a trusted depositor.
4. Deposits 0.1 ETH into the live ETH pool. The live ASP provider is impersonated to approve the note, as in `auto-asp`.
5. **Buy**: 0.06 ETH of that note becomes a meme note. A revert-based helper quotes the gross output first ([`V4QuoteHelper`](../test/mocks/V4QuoteHelper.sol), called with `eth_call`). `minAmountOut` is set to 99% of the quoted net. The proof is built with the frontend SDK's `prepareJoinSplit`, with the V4 envelope in `encryptedOutputs[1]` and the context recomputed. The script's action hash must equal the adapter's on-chain `actionHash`, and the same calldata sent from a stranger must revert.
6. `sync`s the bought note. The buy adapter is trusted, so the note is approved at once.
7. **Sell**: the whole meme note goes back to an ETH note in the live ETH pool. The adapter pays the fee in native ETH.
8. Checks the exact balance changes: treasury +fee, target pool +net, both adapters back to zero.

## Run

```sh
cd research/permissionless-pools/factory
forge build src/Phase2FeeV4Adapter.sol test/mocks/V4QuoteHelper.sol test/V4Adapter.t.sol --out out-v4 --cache-path cache-v4
(cd ../auto-asp && forge build)   # provider + screening list artifacts, if not built
anvil --fork-url https://rpc.mainnet.chain.robinhood.com/ --chain-id 4663 --port 8548 --silent \
  --retries 30 --fork-retry-backoff 5000 --compute-units-per-second 50 &
node fork/v4.mts                  # default: HOOKR/ETH; V4_KEY='{"currency0":..}' for another native-ETH pool
```

To record that a fee-on-transfer meme is rejected, set `EXPECT_REVERT=1`. The script then stops after simulating the buy and records the revert.

## Pools used (fork block ≈ 94,009,200)

Pools were picked from the PoolManager's `Initialize` logs: 518,699 native-ETH pools in total, of which 1,182 had swaps in the last 100k blocks. The candidates were ranked by recent ETH volume and in-range liquidity. A transfer out of the PoolManager was then tested on the fork to screen out fee-on-transfer tokens.

| Run | PoolKey (currency0 = ETH) | PoolId | Liquidity | ≈ virtual ETH |
| --- | --- | --- | --- | --- |
| [result-v4-2026-10-21.json](result-v4-2026-10-21.json) | HOOKR `0x18E6…cff5c`, fee 2500, spacing 25, no hook | `0x590dcb6a…5fdf` | 8.256e22 | 258.5 |
| [result-v4-2026-10-21-gloam-hook.json](result-v4-2026-10-21-gloam-hook.json) | GLOAM `0xDcD8…724d`, fee 0, spacing 200, hook `0x9533…00CC` | `0xc5f37371…dd1a` | 1.227e21 | 40.5 |
| [result-v4-2026-10-21-torch-fot.json](result-v4-2026-10-21-torch-fot.json) | TORCH `0x0000…1111`, fee 3000, spacing 60, no hook | `0x1649550a…2a1d` | 2.738e23 | 667.9 |

"Virtual ETH" is L·2⁹⁶/√P. It is a depth indicator, not the pool's ETH balance.

## Results

| Step | HOOKR (no hook) | GLOAM (hook with swap return deltas) |
| --- | --- | --- |
| Buy 0.06 ETH → meme | 6,101.21 gross, 18.30 fee, **6,082.90 net**; gas **1.95M** | 53.969 gross, 0.162 fee, **53.807 net**; gas **1.98M** |
| `sync` buy output | approved at once; gas 0.73M | approved at once; gas 0.73M |
| Sell whole note → ETH | 0.059474 gross, 0.000178 fee, **0.059295 ETH net**; gas **1.25M** | 0.057451 gross, 0.000172 fee, **0.057279 ETH net**; gas **1.27M** |
| Round-trip cost | 1.17% = 2 × 0.30% service + 2 × 0.25% LP + impact | 4.53%: the hook taxes both sides |
| Quote vs executed gross | equal to the wei | equal to the wei |
| Action hash script = adapter; stranger reverts | yes / yes | yes / yes |

Other measurements:

- Adapter deploy: 2.95M gas.
- Runtime: 13,290 B. Initcode: 15,503 B.
- One Groth16 proof takes about 1.2–1.6 s in Node.

For comparison, the V3 fee-adapter run in `auto-asp` used 2.06M gas for its buy and 1.38M for its sell.

In the GLOAM runs, the hook's `beforeSwap` returned a nonzero delta on the buy, and its `afterSwap` returned one on the sell. So the adapter settled correctly with hook return deltas in both directions.

**Fee-on-transfer is rejected.** TORCH sends 98% of a transfer to the recipient and diverts the rest. The buy reverts with `UnexpectedBalanceDelta`: `take` reported 10,044.21 TORCH, but the adapter received less. The whole transaction reverts, so the source note stays unspent.

## Limits and what this does not show

- **Slippage**: the swap uses the extreme price limit, so `minAmountOut` (NET) is the user's only price protection. A thin or manipulated pool fills at whatever price clears `minAmountOut`, and the quote is taken one block earlier.
- **Hooks**: any hook is accepted and treated as an opaque part of the venue. There are no hook code-hash pins and no `maxHookTaxBps`. The adapter checks only measured balances, so a hook can raise its tax up to the user's `minAmountOut`, or revert. A sender-dependent hook may also quote differently for the quote helper than for the adapter.
- **Fee-on-transfer, rebasing or blacklisting memes** cannot be routed. Once a route is live, a meme that changes its transfer rules stops it, and `holderExit` is unaffected.
- **Live ETH pool's ASP**: it is impersonated on the fork. Its root is replaced with only the test leaf, so live notes do not see that change.
- **Gas**: the figures are anvil L2 execution gas. They exclude Robinhood's L1 data component.
- **Not tested on the fork**: an ERC20/ERC20 v4 pool such as meme/USDG (it is covered by unit tests only), cap exhaustion, and multiple tick crossings or large trades.
- Unaudited research code.
