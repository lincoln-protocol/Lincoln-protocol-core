# Permissionless meme pools

Status: draft, 2026-10-20. Nothing here is deployed or reviewed.

**Decision (user, 2026-10-20): option A.** No Lincoln process approves pools or notes, but the guardian Safe keeps an exclusion lever, because a pool nobody can screen invites sanctions. Option B (no association set, no guardian) is rejected. Fork proof: [auto-asp/](auto-asp/README.md).

**Decisions (user, 2026-10-21):** factory pools have no deposit caps (the Safe can still lower them); Uniswap V4 routes are supported; the app lists every pool. Factory, tests and fork run: [factory/](factory/README.md).

## Goal

Any token holder can open a private pool for a meme token without asking Lincoln. Holders then trade privately inside it: ETH note → meme note (buy) and meme note → ETH note (sell). Each trade is one transaction through a fee adapter, so the DEX sees the trade but not who made it.

## What gates a new pool today

| Step | Who does it now | Permissionless already? |
| --- | --- | --- |
| Deploy `Phase2ASPPool` | Lincoln deployer, from a reviewed plan | Technically yes: the constructor has no owner check. But the deployer picks the caps, and nobody indexes a pool that anyone deploys |
| Deploy buy/sell fee adapters | Lincoln deployer | Yes, proven on a fork ([fork-adapter/](fork-adapter/)) |
| ASP approval of the pool's notes | Publisher, fixed `poolIds` list | **No.** This is the real gate |
| Relay for the pool | One relay process + DNS + Access per pool | **No** |
| App support | CATALOG entry, synced profile and routes, Worker `RELAY_URLS` | **No** |

The circuits and verifiers do not need to change. `SCOPE = keccak(DOMAIN, chainId, pool)` makes every pool distinct, and the existing join-split and exit verifiers serve any pool that binds them.

## Design

### 1. On-chain: `LincolnPoolFactory` (new, ownerless)

- `createPool(token)` deploys `Phase2ASPPool` with CREATE2 (salt = token), so each token gets exactly one pool and anyone can compute its address. Verifiers, registry and chain ID are fixed. The pool bytecode is unchanged RC.3.
- Pools are created without deposit caps; the caller cannot set caps (see Decisions).
- `createRoutes(token, path)` deploys the buy adapter (ETH pool → token pool) and the sell adapter (token pool → ETH pool) through a separate adapter factory, also with CREATE2 on `(source, target, path)`. Treasury = the Safe, service fee = 30 bps. Both are fixed in the factory, not chosen by the caller. The adapter constructor already rejects a path without a V3 pool.
- It emits `PoolCreated(token, pool, creator)` and `RoutesCreated(token, buyAdapter, sellAdapter, path)`. Everything downstream discovers pools from these events.
- Size: pool initcode is 13.6 KB and adapter initcode is 17.5 KB, so they need two factories (EIP-170 limit 24 KB).
- The guardian keeps its existing powers on every factory pool: lower caps, pause deposits, raise caps after 12 hours. That is an emergency brake, not an approval step. Holder exits always work.

What the factory checks: the token has code, `decimals()` and `totalSupply()` return values, and no pool exists for it yet. Exact-transfer is enforced by the pool on every deposit, so fee-on-transfer tokens fail at the first deposit. Rebasing tokens cannot be detected on chain; the app warns about them.

### 2. Association set: on-chain auto-approval with exclusion (option A, replaces the publisher for factory pools)

- Each factory pool gets its own registry whose only provider is an `AutoApproveProvider` contract. The factory deploys the provider, registry and pool, and binds them in one transaction.
- Rules: notes made by spends and by factory route adapters are approved at once. Direct deposits wait a screening delay (1 hour in the fork run) and are then approved, unless the Safe denied the depositor or excluded the commitment.
- One shared `ScreeningList` holds the Safe's denials. Nothing is frozen: ragequit and holder exit stay open.
- Anyone can call `sync` (about 0.72M gas per approved note). The relay calls it as part of its jobs, so users never wait on a Lincoln process. The backend publisher is not involved, and its outages no longer stop factory pools.
- The registry guardian stays the Safe, so it can suspend a provider in an emergency.

### 3. Relay (backend)

- One relay serves every factory pool (`/relay/pool/<address>/v3/...`) instead of one process per pool.
- Relay fee for buys: unchanged. The source is the ETH pool, so the relay fee is paid in ETH as it is today.
- Relay fee for sells: the source is the meme pool, so an ExtData fee would arrive in the meme token. Use ExtData fee 0 instead and let the 30 bps service fee, which a sell pays to the Safe in ETH, cover the gas. Relay fees already go to the Safe. A swap costs about 2.1M gas (fork run), roughly 0.00005 ETH at the base fee seen on 2026-10-17. 30 bps covers that from about 0.02 ETH, which becomes the minimum sell.
- Plain withdrawals from a meme pool would pay the relay in the meme token. For the first version, the relay does not take them. Users either sell to the ETH pool first or use `holderExit` themselves.

### 4. App, SDK, MCP (frontend repo)

- The Worker indexes factory events (`/pools`). Profiles are built from the factory record instead of committed `profile.<asset>.json` files.
- Pages: a meme list, a page per token (pool size, anonymity level, share of supply in the pool, public depositors), and "Open a private pool" for a token address.
- `operations.ts`: route quotes and submits to the generic relay for factory pools, and offer self-submit as a fallback.

## Privacy and abuse notes

- Buyers come from the ETH pool, which has a large set, so a buy hides who bought. The meme note itself sits in a small set. A quick sell after a buy is easy to link by timing. The app already shows crowd levels and should show them here.
- A team could deposit its own supply and sell privately. Deposits are public (`originalDepositor`, `DynamicDeposited`), so the token page should show how much of the pool came from which addresses. Pools have no caps, so this disclosure is the main safeguard.
- This is new contract code during an audit that is still in progress. The factories should join the audit scope before mainnet.

## Decisions

1. **Caps:** none at creation (decided 2026-10-21). The Safe can lower them or pause deposits.
2. **DEX coverage:** V3 through the RC.3 adapter, and V4 through a new single-pool adapter (decided 2026-10-21).
3. **Listing:** the app lists every pool (decided 2026-10-21).
4. **Who deploys the factory:** still open. The plan is one rollout by the Lincoln deployer after review; after that, no Lincoln transaction is needed per pool.

## Order of work

1. Factory and adapter factory contracts with Foundry tests (this repo, this branch).
2. Fork run: create a pool for a real Robinhood meme, buy and sell through the new adapters. The ASP is impersonated as in the fork proof.
3. Publisher and generic relay specs handed to the backend session.
4. App pages and discovery.
5. Audit scope update, then the mainnet factory deploy (user runs it).
