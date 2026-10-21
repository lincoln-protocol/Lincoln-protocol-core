# Permissionless meme pool factory (research)

Anyone opens a private pool for any token and adds in-pool trade routes. Lincoln approves neither. Not deployed, not reviewed, outside the RC.3 audit scope.

| Contract | Role |
| --- | --- |
| [`LincolnMemeFactory`](src/LincolnMemeFactory.sol) | `createPool(token)`, `createV3Route(source, target, path)`, `createV4Route(source, target, key)`. No owner or setters. Records pools, providers and route adapters |
| [`AutoApproveProvider`](src/AutoApproveProvider.sol) | One per pool, the sole provider of the pool's own RC.3 registry. Approves notes by rule. Anyone calls `sync` |
| [`ScreeningList`](src/ScreeningList.sol) | Shared. Only the Safe can deny depositors or exclude commitments |
| [`Deployers`](src/Deployers.sol) | Hold the pool, provider, V3 adapter and V4 adapter creation code (24 KB limit). Only the factory can deploy through them; the factory address is set once at rollout |
| [`Phase2FeeV4Adapter`](src/Phase2FeeV4Adapter.sol) | Single-pool Uniswap V4 fee route for any PoolKey: native ETH, any fee tier, any hook. Same `swap` shape, events and envelope as the RC.3 V3 adapter, with its own domain. See [fork/README-v4.md](fork/README-v4.md) |

What the caller cannot choose: verifiers, the guardian (the Safe), caps (none: `type(uint128).max`), the screening delay, the 30 bps route fee and its treasury (the Safe), the base pools (the live ETH and USDG pools).

Approval rules (provider):

| Note | Approved |
| --- | --- |
| Made by a spend | At once |
| Deposited by a route adapter this factory deployed | At once: it comes from an approved note in the source pool |
| Any other deposit | After the screening delay (1 hour in tests), unless the Safe denied the depositor or excluded the commitment |

What the Safe can still do on every factory pool: lower caps, pause deposits, raise caps after 12 hours, suspend a provider (halts normal spending, never exits), deny or exclude. It cannot move funds or block `holderExit`/`ragequit`.

## Tests

```sh
forge test    # 36 passed: Factory.t.sol 11, V4Adapter.t.sol 25
```

Creation and binding, rejected tokens (duplicate, zero, EOA, base asset, non-ERC20), deployer and binder access, the approval rules (delay, denied, excluded, spend outputs, adapter deposits), the Safe's levers, and route rules: a factory pool on at least one side, unique per id, and the adapters' own checks on V3 paths and V4 keys. The V4 route tests run the real deployer and adapter against a mock PoolManager. `V4Adapter.t.sol` covers the adapter itself: constructor checks, envelope binding, callback access, partial fills, settlement mismatches, fee-on-transfer tokens, fee and min-out edges, and a balance fuzz in both directions.

Sizes: factory 5.6 KB runtime; the largest deployers, V3 and V4 routes, are 19.1 KB and 17.1 KB.

## Fork run ([fork/run.mts](fork/run.mts), result [fork/result-2026-10-21.json](fork/result-2026-10-21.json))

The fork uses real mainnet verifiers, the Uniswap V3 router, the live ETH and USDG pools as base pools, and the Safe as guardian, admin and treasury. The Safe and the live USDG pool's ASP provider are impersonated.

| Step | Result | Gas |
| --- | --- | --- |
| Rollout: screening list, three deployers, factory, `setFactory` | Lincoln deployer, once | — |
| A stranger calls `createPool(PONS)` | Uncapped pool; registry provider = its provider; guardian = Safe | 7.62M |
| The stranger adds USDG→PONS and PONS→USDG V3 routes | Both trusted by the provider | 3.20M, 3.18M |
| Buy 6 USDG note → PONS note | 21.203 PONS net | 2.07M |
| `sync` the bought note | Approved at once | 0.73M |
| Sell the whole PONS note → USDG note | 5.958 USDG net | 1.35M |
| Two direct deposits; the Safe denies one depositor; one hour passes | Clean approved, denied withheld, ragequit open to the depositor | 0.11M, 0.07M, 0.72M |

```sh
forge build
anvil --fork-url https://rpc.mainnet.chain.robinhood.com/ --chain-id 4663 --port 8547 --silent --retries 30 --fork-retry-backoff 5000 --compute-units-per-second 50 &
node fork/run.mts
```

The public RPC rate-limits forks. Of four attempts on 2026-10-21, two passed and one timed out waiting for a receipt. One reverted at the impersonated `updateRoot` on the live USDG registry, a step outside the factory code; its reason was not captured.

## V4 fork runs ([fork/README-v4.md](fork/README-v4.md))

The adapter was tested on its own on a mainnet fork: private buy and sell of 0.06 ETH through two real V4 pools.

| Pool | Round-trip cost |
| --- | --- |
| HOOKR, fee 0.25%, no hook | 1.17% |
| GLOAM, a hooked pool | 4.53%, mostly the hook's tax |

A fee-on-transfer token (TORCH) made the buy revert with the note unspent. The V4 routes have not yet gone through the factory on a fork.

## Known limits

- V4 adapters accept any hook. The only economic guard is the user's `minAmountOut`, so a hook can tax up to that limit or revert. No hook, token or manager code hashes are pinned.
- The V4 adapter's check that the pool is initialized reads v4-core's storage layout (pools mapping at slot 6).

- Notes that enter through a base pool are screened only by that pool's ASP, which today approves all current notes. A buy from the ETH pool therefore skips the factory pool's delay. That matches the trust already placed in the live pools.
- Denial does not revoke notes that are already approved. The live ASP has the same property.
- Every approving `sync` is a new epoch. Proofs stay valid for 16 epochs or 1 hour, so busy pools need batched syncs.
- Per-meme anonymity sets start empty. The app must show crowd sizes.
