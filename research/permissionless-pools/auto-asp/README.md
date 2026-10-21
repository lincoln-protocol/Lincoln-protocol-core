# Fork proof: a meme pool without an operated association set (option A)

A PONS pool that no Lincoln process approves notes for. The unchanged RC.3 pool, registry, join-split circuit and fee adapter are used. Only two small contracts are new:

- [`AutoApproveProvider`](src/AutoApproveProvider.sol) is the registry's only provider. It builds the association tree on chain from the pool's own commitments, under fixed rules. Anyone can call `sync`.
- [`ScreeningList`](src/ScreeningList.sol) is the exclusion lever, and only the guardian Safe can use it. It can deny depositor addresses, exclude single commitments, and mark trusted route adapters. In the planned factory, the factory marks the adapters it deploys.

Approval rules:

| Note | Approved |
| --- | --- |
| Made by a spend (no original depositor) | At once: its inputs were approved |
| Deposited by a trusted route adapter (a private buy) | At once: the source note was approved |
| Any other deposit | After `SCREENING_DELAY` from when `sync` first saw it, unless the Safe denied the depositor or excluded the commitment in the meantime |

Nothing is ever frozen. A withheld deposit can still `ragequit` to its own depositor, and `holderExit` never consults the list. The registry guardian (the Safe) can still suspend the provider. That halts normal spending, never exits.

## Run

Prerequisites are the same as [../fork-adapter](../fork-adapter/README.md). The public RPC rate-limits forks, so give anvil retries:

```sh
cd research/permissionless-pools/auto-asp
forge build
anvil --fork-url https://rpc.mainnet.chain.robinhood.com/ --chain-id 4663 --port 8547 --silent --retries 30 --fork-retry-backoff 5000 --compute-units-per-second 50 &
node run.mts
```

Foundry leaves the Poseidon placeholders unlinked, so `run.mts` links them to the mainnet library addresses itself.

## Result on 2026-10-20 ([result-2026-10-20.json](result-2026-10-20.json))

| Step | Outcome | Gas |
| --- | --- | --- |
| Open the pool: screening list, provider + registry, RC.3 pool, bind | Registry provider = the provider contract, guardian = the Safe | — |
| Buy: 6 USDG note (live USDG pool) → PONS note in the new pool | 21.098 PONS net | 2.06M |
| `sync` the buy output | Approved at once (trusted adapter) | 0.73M |
| Sell: the whole PONS note → USDG note | 5.958 USDG net. Round-trip cost 0.70% = 2 × 0.30% service fee + 2 × 0.05% LP fee + impact | 1.38M |
| Two direct 100 PONS deposits; the Safe denies the second depositor | Both withheld as waiting | 0.11M, then 0.07M |
| After one hour | Clean deposit approved; denied one withheld, ragequit still open to its depositor | 0.72M |

The USDG side still uses the live pool and its live ASP, which is impersonated on the fork as in the first proof. Only the new PONS pool runs without an operator.

## Limits found

- Every approved note costs one `sync` of about 0.72M gas (20 Poseidon hashes plus a policy update), about 0.000015 ETH at a 0.02 gwei base fee. The relay can include it in its jobs.
- Each `sync` that approves something publishes a new epoch. A proof stays valid for 16 epochs or 1 hour after being superseded, so a very busy pool would need batched syncs.
- Denying an address after its note is approved does not revoke that note or the notes spent from it. The live ASP has the same property.
- `bind` trusts its deployer. The factory has to deploy and bind in one transaction.
