# Permissionless meme pool factory (research)

Anyone opens a private pool for any token and adds in-pool trade routes. Lincoln approves neither. Not deployed, not reviewed, outside the RC.3 audit scope.

| Contract | Role |
| --- | --- |
| [`LincolnMemeFactory`](src/LincolnMemeFactory.sol) | `createPool(token)`, `createV3Route(source, target, path)`, `createV4Route(source, target, key)`. No owner or setters. Records pools (with generations per token), providers and route adapters |
| [`AutoApproveProvider`](src/AutoApproveProvider.sol) | One per pool, the sole provider of the pool's own RC.3 registry. Approves notes by rule and publishes them at a limited rate. Anyone calls `sync` and `publish` |
| [`ScreeningList`](src/ScreeningList.sol) | Shared. Only the Safe can deny depositors or exclude commitments |
| [`Deployers`](src/Deployers.sol) | Hold the pool, provider, V3 adapter and V4 adapter creation code (24 KB limit). Only the factory can deploy through them; the factory address is set once at rollout |
| [`Phase2FeeV4Adapter`](src/Phase2FeeV4Adapter.sol) | Single-pool Uniswap V4 fee route for any PoolKey: native ETH, any fee tier, any hook. Same `swap` shape, events and envelope as the RC.3 V3 adapter, with its own domain. See [fork/README-v4.md](fork/README-v4.md) |

What the caller cannot choose: verifiers, the guardian (the Safe), caps (none: `type(uint128).max`), the screening delay, the 30 bps route fee and its treasury (the Safe), the base pools (the live ETH and USDG pools).

Approval rules (provider):

| Note | Approved |
| --- | --- |
| Made by a spend | At once: its inputs were approved |
| Any deposit, including a route adapter's (a private buy) | After the screening delay (1 hour in tests, at least 10 minutes), counted from the first `sync` that sees it, unless the Safe denied the depositor (an address, or a route's adapter) or excluded the commitment |

Adapter deposits are not trusted at once: a route can trade through any venue, including a pool or hook its creator controls, so its output is not bounded by the approved input note (audit F-1, below).

Publishing: `sync` inserts approved leaves; a new registry policy covering them is published at most every 4 minutes, when leaves are pending or the policy is within a day of expiry (`publish()` is permissionless and rate-limited). Sixteen epochs therefore take over an hour, so a proof has at least an hour to land. Clients build the association tree from the first `publishedLeafCount` `LeafApproved` leaves; `usable(commitment)` says whether a note can be proved now.

What the Safe can still do on every factory pool: lower caps, pause deposits, raise caps after 12 hours, suspend a provider (halts normal spending, never exits), deny or exclude. It cannot move funds or block `holderExit`/`ragequit`.

## Tests

```sh
forge test    # 42 passed: Factory.t.sol 11, AuditFixes.t.sol 6, V4Adapter.t.sol 25
```

Creation and binding, rejected tokens (duplicate, zero, EOA, base asset, non-ERC20), deployer and binder access, the approval rules (delay, denied, excluded, spend outputs, adapter deposits), the Safe's levers, and route rules: a factory pool on at least one side, unique per id, and the adapters' own checks on V3 paths and V4 keys. The V4 route tests run the real deployer and adapter against a mock PoolManager. `V4Adapter.t.sol` covers the adapter itself: constructor checks, envelope binding, callback access, partial fills, settlement mismatches, fee-on-transfer tokens, fee and min-out edges, and a balance fuzz in both directions. `AuditFixes.t.sol` turns the audit's proofs of concept into regressions.

Sizes: factory 5.6 KB runtime; the largest deployers, V3 and V4 routes, are 19.1 KB and 17.1 KB.

## Fork run ([fork/run.mts](fork/run.mts), result [fork/result-2026-10-22.json](fork/result-2026-10-22.json); before the audit fixes: [result-2026-10-21.json](fork/result-2026-10-21.json))

The fork uses real mainnet verifiers, the Uniswap V3 router, the live ETH and USDG pools as base pools, and the Safe as guardian, admin and treasury. The Safe and the live USDG pool's ASP provider are impersonated.

| Step | Result | Gas |
| --- | --- | --- |
| Rollout: screening list, three deployers, factory, `setFactory` | Lincoln deployer, once | — |
| A stranger calls `createPool(PONS)` | Uncapped pool; registry provider = its provider; guardian = Safe | 7.80M |
| The stranger adds USDG→PONS and PONS→USDG V3 routes | Recorded as factory routes | 3.20M, 3.18M |
| Buy 6 USDG note → PONS note | 20.735 PONS net | 2.06M |
| `sync` the bought note | Seen, waits the delay | 0.07M |
| One hour later, `sync` again | Approved and published in the same call; `usable` is true | 0.76M |
| Sell the whole PONS note → USDG note | 5.958 USDG net | 1.36M |
| Two direct deposits; the Safe denies one depositor; one hour passes | Clean approved, denied withheld, ragequit open to the depositor | 0.11M, 0.06M, 0.72M |

```sh
forge build
anvil --fork-url https://rpc.mainnet.chain.robinhood.com/ --chain-id 4663 --port 8547 --silent --retries 30 --fork-retry-backoff 5000 --compute-units-per-second 50 &
node fork/run.mts
```

The public RPC rate-limits forks. On 2026-10-21, two of four attempts passed (one receipt timeout; one revert at the impersonated `updateRoot` on the live USDG registry, outside the factory code, reason not captured). The 2026-10-22 run after the audit fixes passed on the first attempt.

## V4 fork runs ([fork/README-v4.md](fork/README-v4.md))

The adapter was tested on its own on a mainnet fork: private buy and sell of 0.06 ETH through two real V4 pools.

| Pool | Round-trip cost |
| --- | --- |
| HOOKR, fee 0.25%, no hook | 1.17% |
| GLOAM, a hooked pool | 4.53%, mostly the hook's tax |

A fee-on-transfer token (TORCH) made the buy revert with the note unspent. The V4 routes have not yet gone through the factory on a fork.

## Audit, 2026-10-21

An independent review of c76f4c2 (run by the backend session, PoCs in Foundry) found:

| Finding | Status |
| --- | --- |
| **F-1 High**: route adapter deposits were approved at once, so denied funds could be loaded into an attacker-controlled venue and come out as an approved note in one transaction | Fixed: adapter deposits wait the screening delay; the Safe can exclude the commitment or deny the adapter |
| **F-2 High**: `refresh()` and every approving `sync` published an epoch, so 16 calls pushed every in-flight proof out of the accepted window | Fixed: publishing is rate-limited to every 4 minutes; `refresh()` removed |
| **F-3 Low**: 2^20 dust deposits fill a pool's tree and, with one pool per token, retire the token for good | Fixed: a token reopens as a new generation once its tree is within 16 leaves of full (`generationsOf`) |
| **F-4 Low**: approvals are irreversible and the factory cannot re-provision a provider | Accepted, as with the live ASP: the Safe can suspend the provider (normal spending stops, exits continue) or rotate it after the registry's 3-day delay |
| Info: a zero screening delay was allowed | Fixed: at least 10 minutes |
| Info: ragequit of an adapter-deposited note pays the adapter, where funds are stuck | Open: wallets and relays must offer `holderExit` instead for those notes (`factory.isRouteAdapter(originalDepositor)`) |
| Info: the screening clock starts at the first `sync`, not at the deposit | Accepted: the pool has no deposit time on chain; the relay syncs every 30 s |
| Info: the V4 adapter accepts ETH from the source pool at any time; any hook can be listed | Accepted: stray ETH does not affect the balance-delta checks; the app should prefer hookless or vetted routes |
| Info: rollout scripts should assert the deployer → factory bindings | Open, for the rollout script |

## Known limits

- V4 adapters accept any hook. The only economic guard is the user's `minAmountOut`, so a hook can tax up to that limit or revert. No hook, token or manager code hashes are pinned.
- The V4 adapter's check that the pool is initialized reads v4-core's storage layout (pools mapping at slot 6).

- Notes that enter through a base pool are screened only by that pool's ASP, which today approves all current notes. A buy from the ETH pool therefore skips the factory pool's delay. That matches the trust already placed in the live pools.
- Denial does not revoke notes that are already approved. The live ASP has the same property.
- A new note becomes provable only after the next publish, up to 4 minutes after its approval.
- A bought meme note can be sold or moved only after the screening delay. Selling right after buying is also easy to link by timing, so the wait costs little privacy.
- Per-meme anonymity sets start empty. The app must show crowd sizes.
