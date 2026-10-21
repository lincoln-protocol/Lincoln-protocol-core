// Fork-only end-to-end for option A: a PONS pool that nobody at Lincoln runs an association set for.
// An AutoApproveProvider approves its notes by rule and a ScreeningList (the "Safe") keeps the exclusion lever.
// Runs against anvil --fork-url <robinhood mainnet> --chain-id 4663 --port 8547. Never touches the real network.
import { readFileSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { resolve } from 'node:path';
import type { Hex, Log } from 'viem';

const FE = resolve(process.env.LINCOLN_FRONTEND ?? new URL('../../../../privacy-frontend', import.meta.url).pathname);
const fromFrontend = createRequire(`${FE}/package.json`);
const snarkjs = await import(fromFrontend.resolve('snarkjs'));
const {
  createPublicClient, createTestClient, createWalletClient, decodeEventLog, http, parseAbi, publicActions, walletActions,
} = await import(fromFrontend.resolve('viem'));
const { privateKeyToAccount, generatePrivateKey } = await import(fromFrontend.resolve('viem/accounts'));
const sdk = await import(`${FE}/src/protocol/asp/sdk.ts`);

const HERE = new URL('.', import.meta.url).pathname;
const RPC = process.env.FORK_RPC ?? 'http://127.0.0.1:8547';
const OUT = process.env.RESULT_FILE ?? 'result.json';
const chain = { id: 4663, name: 'rh-fork', nativeCurrency: { name: 'ETH', symbol: 'ETH', decimals: 18 }, rpcUrls: { default: { http: [RPC] } } } as const;
const pub = createPublicClient({ chain, transport: http(RPC, { timeout: 120_000 }) });
const test = createTestClient({ chain, mode: 'anvil', transport: http(RPC) }).extend(publicActions).extend(walletActions);
const json = (f: string) => JSON.parse(readFileSync(f, 'utf8'));
const out: Record<string, unknown> = {};
const big = (v: unknown) => JSON.parse(JSON.stringify(v, (_, x) => typeof x === 'bigint' ? String(x) : x));
const log = (k: string, v: unknown) => { out[k] = big(v); console.log(k, JSON.stringify(big(v))); };

const usdgProfile = json(`${FE}/src/protocol/asp/mainnet/profile.usdg.json`);
const ponsProfile = json(`${FE}/src/protocol/asp/mainnet/profile.pons.json`);
const POOL_ABI = json(`${FE}/src/protocol/asp/abi/Phase2ASPPool.json`);
const REG_ABI = json(`${FE}/src/protocol/asp/abi/Phase2ASPRegistry.json`);
const artifact = (file: string, name: string) => json(`${HERE}out/${file}/${name}.json`);
const ERC20 = parseAbi(['function balanceOf(address) view returns (uint256)', 'function transfer(address,uint256) returns (bool)', 'function approve(address,uint256) returns (bool)']);
const QUOTER_ABI = parseAbi(['function quoteExactInput(bytes path, uint256 amountIn) returns (uint256 amountOut, uint160[] sqrtPriceX96AfterList, uint32[] initializedTicksCrossedList, uint256 gasEstimate)']);

const USDG = '0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168' as Hex, PONS = '0x39dBED3a2bd333467115dE45665cC57F813C4571' as Hex;
const USDG_POOL = usdgProfile.pool.address as Hex;
const ROUTER = '0xCaf681a66D020601342297493863E78C959E5cb2' as Hex, FACTORY = '0x1f7d7550B1b028f7571E69A784071F0205FD2EfA' as Hex;
const QUOTER = '0x33e885eD0Ec9bF04EcfB19341582aADCb4c8A9E7' as Hex, WETH = '0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73' as Hex;
const LIVE_REGISTRY = usdgProfile.registry.address as Hex, LIVE_PROVIDER = usdgProfile.registry.provider as Hex;
const USDG_WHALE = '0xf2A0bE59AB76b96f957bd5E5b967F2B75e8dB269' as Hex;
const PONS_WHALE = '0x46534760B24aBE79AafdD82d4a37681DEc311133' as Hex; // the USDG/PONS 0.05% Uniswap V3 pool
const LIBRARIES: Record<string, Hex> = { PoseidonT3: ponsProfile.libraries.PoseidonT3.address, PoseidonT4: ponsProfile.libraries.PoseidonT4.address };
const FEE_TIER = 500, FEE_BPS = 30, DELAY = 3600n;
const path = (a: Hex, b: Hex) => `0x${a.slice(2)}${FEE_TIER.toString(16).padStart(6, '0')}${b.slice(2)}`.toLowerCase() as Hex;

const key = () => privateKeyToAccount(generatePrivateKey());
const deployer = key(), safe = key(), user = key(), gas = key(), holder = key(), flagged = key(), treasury = key().address;
const wallet = (a: any) => createWalletClient({ chain, account: a, transport: http(RPC) });

// Foundry left the Poseidon placeholders in; link them to the libraries already on mainnet.
function linked(art: any): Hex {
  let code: string = art.bytecode.object.slice(2);
  for (const [, libs] of Object.entries(art.bytecode.linkReferences ?? {}) as [string, Record<string, { start: number; length: number }[]>][])
    for (const [name, refs] of Object.entries(libs))
      for (const { start, length } of refs) code = code.slice(0, start * 2) + LIBRARIES[name].slice(2).toLowerCase() + code.slice((start + length) * 2);
  return `0x${code}` as Hex;
}
async function send(p: Promise<Hex>) { const hash = await p; const r = await pub.waitForTransactionReceipt({ hash }); if (r.status !== 'success') throw new Error(`reverted ${hash}`); return r; }
async function deploy(account: any, art: any, args: unknown[]) {
  const r = await send(wallet(account).deployContract({ abi: art.abi, bytecode: linked(art), args }));
  return r.contractAddress as Hex;
}
const events = (receipt: any, abis: any[]) => receipt.logs.map((l: Log) => {
  for (const abi of abis) { try { return { address: l.address, ...(decodeEventLog({ abi, topics: l.topics, data: l.data }) as any) }; } catch {} }
  return null;
}).filter(Boolean);

async function poolState(address: Hex, fromBlock: bigint) {
  const logs = await pub.getLogs({ address, fromBlock, toBlock: 'latest' });
  const commitments: string[] = [], nullifiers: string[] = [], receipts: any[] = [];
  for (const l of logs) {
    let ev: any; try { ev = decodeEventLog({ abi: POOL_ABI, topics: l.topics, data: l.data, strict: true }); } catch { continue; }
    const a = ev.args;
    if (ev.eventName === 'NewCommitment') { commitments.push(String(a.commitment)); receipts.push({ commitment: String(a.commitment), index: Number(a.index), encryptedOutput: a.encryptedOutput }); }
    else if (ev.eventName === 'NewNullifier') nullifiers.push(String(a.nullifier));
    else if (ev.eventName === 'DynamicDeposited') Object.assign(receipts.at(-1), { value: String(a.value), precommitment: String(a.precommitment), encryptedTemplate: a.encryptedTemplate });
  }
  const root = sdk.buildMerkleTree(commitments).root;
  if (root !== await pub.readContract({ address, abi: POOL_ABI, functionName: 'currentRoot' })) throw new Error('pool root mismatch');
  return { chainId: 4663, pool: address, root: String(root), commitments, nullifiers, receipts, blockTimestamp: String((await pub.getBlock()).timestamp) };
}

async function main() {
  for (const a of [deployer, safe, user, gas, holder, flagged]) await test.setBalance({ address: a.address, value: 10n ** 20n });
  for (const a of [USDG_WHALE, PONS_WHALE, LIVE_PROVIDER]) await test.setBalance({ address: a, value: 10n ** 20n });
  const startBlock = await pub.getBlockNumber();

  // ---- 1. Open a PONS pool without Lincoln: screening list (admin = the Safe), provider + registry, RC.3 pool, bind. ----
  const screenArt = artifact('ScreeningList.sol', 'ScreeningList'), providerArt = artifact('AutoApproveProvider.sol', 'AutoApproveProvider');
  const screening = await deploy(deployer, screenArt, [safe.address]);
  const provider = await deploy(deployer, providerArt, [safe.address, screening, DELAY]);
  const readP = (functionName: string, args: unknown[] = []) => pub.readContract({ address: provider, abi: providerArt.abi, functionName, args }) as Promise<any>;
  const registry = await readP('REGISTRY') as Hex;
  const pool = await deploy(deployer, artifact('Phase2ASPPool.sol', 'Phase2ASPPool'),
    [ponsProfile.verifier.address, ponsProfile.exitVerifier.address, registry, PONS, 10n ** 30n, 10n ** 31n]);
  await send(wallet(deployer).writeContract({ address: provider, abi: providerArt.abi, functionName: 'bind', args: [pool] }));
  const regGuardian = await pub.readContract({ address: registry, abi: REG_ABI, functionName: 'GUARDIAN' });
  log('opened', { screening, provider, registry, pool, registryProvider: await pub.readContract({ address: registry, abi: REG_ABI, functionName: 'PROVIDER' }), registryGuardian: regGuardian,
    poolScope: await pub.readContract({ address: pool, abi: POOL_ABI, functionName: 'SCOPE' }) });

  // The SDK's view of the new pool: the PONS profile with this pool, registry and provider.
  const memeProfile = structuredClone(ponsProfile);
  Object.assign(memeProfile.pool, { address: pool, startBlock: String(startBlock), scope: undefined });
  Object.assign(memeProfile.registry, { address: registry, provider, guardian: safe.address, startBlock: String(startBlock) });
  const memeASP = async () => {
    const logs = await pub.getLogs({ address: provider, fromBlock: startBlock, toBlock: 'latest' });
    const leaves = logs.map((l: Log) => { try { return decodeEventLog({ abi: providerArt.abi, topics: l.topics, data: l.data }) as any; } catch { return null; } })
      .filter((e: any) => e?.eventName === 'LeafApproved').map((e: any) => String(e.args.leaf));
    const [root, epoch, validUntil] = await pub.readContract({ address: registry, abi: REG_ABI, functionName: 'latestPolicy' }) as [bigint, bigint, bigint];
    if (sdk.buildMerkleTree(leaves).root !== root) throw new Error('association root mismatch');
    return { root: String(root), epoch: String(epoch), validUntil: String(validUntil), leaves, expired: false };
  };
  const sync = async (commitments: bigint[]) => {
    const r = await send(wallet(gas).writeContract({ address: provider, abi: providerArt.abi, functionName: 'sync', args: [commitments] }));
    return { gasUsed: r.gasUsed, events: events(r, [providerArt.abi]).map((e: any) => ({ event: e.eventName, ...e.args })) };
  };

  // ---- 2. Route adapters: buy (USDG pool -> meme pool) and sell (meme pool -> USDG pool). The Safe trusts the buy adapter's deposits. ----
  const adapterArt = artifact('Phase2FeeRouteAdapter.sol', 'Phase2FeeRouter02Adapter');
  const buy = await deploy(deployer, adapterArt, [USDG_POOL, pool, ROUTER, WETH, 0, path(USDG, PONS), FEE_BPS, treasury]);
  const sell = await deploy(deployer, adapterArt, [pool, USDG_POOL, ROUTER, WETH, 0, path(PONS, USDG), FEE_BPS, treasury]);
  await send(wallet(safe).writeContract({ address: screening, abi: screenArt.abi, functionName: 'setTrustedDepositor', args: [buy, true] }));
  log('adapters', { buy, sell });

  // ---- 3. A private USDG note (the live pool; its live ASP is impersonated, as in the fork-adapter proof). ----
  await test.impersonateAccount({ address: USDG_WHALE });
  await send(test.writeContract({ account: USDG_WHALE, address: USDG, abi: ERC20, functionName: 'transfer', args: [user.address, 10_000_000n] }));
  await test.stopImpersonatingAccount({ address: USDG_WHALE });
  const account = sdk.createAccount();
  const invoice = sdk.createDynamicReceive(account, usdgProfile);
  await send(wallet(user).writeContract({ address: USDG, abi: ERC20, functionName: 'approve', args: [USDG_POOL, 10_000_000n] }));
  const depR = await send(wallet(user).writeContract({ address: USDG_POOL, abi: POOL_ABI, functionName: 'depositDynamic', args: [10_000_000n, invoice.precommitment, invoice.encryptedTemplate] }));
  const depEv = events(depR, [POOL_ABI]).find((e: any) => e.eventName === 'DynamicDeposited');
  const usdgNote = sdk.decryptDynamicReceipt(account, usdgProfile, depEv.args);
  const usdgLeaves = [String(sdk.associationLeaf(usdgNote.commitment, usdgProfile))];
  const now = (await pub.getBlock()).timestamp;
  await test.impersonateAccount({ address: LIVE_PROVIDER });
  await send(test.writeContract({ account: LIVE_PROVIDER, address: LIVE_REGISTRY, abi: REG_ABI, functionName: 'updateRoot', args: [sdk.buildMerkleTree(usdgLeaves).root, sdk.associationSetDigest(usdgLeaves), now + 7n * 86400n] }));
  await test.stopImpersonatingAccount({ address: LIVE_PROVIDER });
  const [lr, le, lv] = await pub.readContract({ address: LIVE_REGISTRY, abi: REG_ABI, functionName: 'latestPolicy' }) as [bigint, bigint, bigint];
  const usdgASP = { root: String(lr), epoch: String(le), validUntil: String(lv), leaves: usdgLeaves, expired: false };

  async function feeSwap(label: string, opts: { adapter: Hex; source: any; target: any; sourceState: any; note: any; amountIn: bigint; path: Hex }) {
    const route = { id: label, adapterType: 'Phase2FeeRouter02Adapter', adapter: opts.adapter, router: ROUTER, factory: FACTORY, quoter: QUOTER, wrappedNative: WETH,
      protocol: 0, path: opts.path, feeBps: FEE_BPS, treasury, sourcePool: opts.source.pool.address, targetPool: opts.target.pool.address };
    const { result: [gross] } = await pub.simulateContract({ address: QUOTER, abi: QUOTER_ABI, functionName: 'quoteExactInput', args: [opts.path, opts.amountIn] }) as any;
    const fee = sdk.serviceFee(gross, FEE_BPS), minNet = (gross - fee) * 99n / 100n, maxServiceFee = fee * 101n / 100n + 1n;
    const prepared = sdk.prepareFeeSwap({ account, sourceProfile: opts.source, targetProfile: opts.target, sourceState: opts.sourceState, route, inputs: [opts.note],
      action: { processor: gas.address, amountIn: opts.amountIn, minAmountOut: minNet, deadline: BigInt(opts.sourceState.blockTimestamp) + 3600n, maxServiceFee } });
    const c = json(`${FE}/src/protocol/asp/mainnet/circuits.json`).joinsplit;
    const file = (p: string) => new Uint8Array(readFileSync(`${FE}/public${p}`));
    const { proof, publicSignals } = await snarkjs.groth16.fullProve(big(prepared.inputSignals), { type: 'mem', data: file(c.wasm.path) } as any, { type: 'mem', data: file(c.zkey.path) } as any);
    if (JSON.stringify(publicSignals) !== JSON.stringify(prepared.publicSignals)) throw new Error('public signal mismatch');
    const tx = sdk.publicTransaction(prepared, proof);
    const action = { ...prepared.action, encryptedTemplate: prepared.action.encryptedTemplate as Hex, processor: prepared.action.processor as Hex };
    const r = await send(wallet(gas).writeContract({ address: opts.adapter, abi: adapterArt.abi, functionName: 'swap', gas: 3_000_000n, args: [action,
      { pA: tx.pA.map(BigInt), pB: tx.pB.map((row: string[]) => row.map(BigInt)), pC: tx.pC.map(BigInt), pubSignals: tx.pubSignals.map(BigInt) },
      { recipient: tx.extData.recipient, feeRecipient: tx.extData.feeRecipient, processor: tx.extData.processor, publicIn: BigInt(tx.extData.publicIn), publicOut: BigInt(tx.extData.publicOut), fee: BigInt(tx.extData.fee) },
      tx.encryptedOutputs] }));
    const evs = events(r, [adapterArt.abi, POOL_ABI]);
    const reshield = evs.find((e: any) => e.eventName === 'SwapReshielded');
    const dep = evs.find((e: any) => e.eventName === 'DynamicDeposited' && e.address.toLowerCase() === opts.target.pool.address.toLowerCase());
    const received = sdk.decryptDynamicReceipt(account, opts.target, dep.args);
    log(label, { tx: r.transactionHash, gasUsed: r.gasUsed, from: r.from, amountIn: reshield.args.amountIn, amountOutNet: reshield.args.amountOut, note: { commitment: received.commitment, value: received.value } });
    return received;
  }

  // ---- 4. Buy: 6 USDG note -> PONS note in the new pool. Deposited by the trusted buy adapter, so approved at once. ----
  const ponsNote = await feeSwap('buy', { adapter: buy, source: usdgProfile, target: memeProfile, sourceState: { ...(await poolState(USDG_POOL, BigInt(usdgProfile.pool.startBlock))), asp: usdgASP },
    note: usdgNote, amountIn: 6_000_000n, path: path(USDG, PONS) });
  log('syncBuyOutput', await sync([ponsNote.commitment]));

  // ---- 5. Sell: the whole PONS note -> USDG note in the USDG pool. No Lincoln party approved anything in the PONS pool. ----
  const usdgBack = await feeSwap('sell', { adapter: sell, source: memeProfile, target: usdgProfile, sourceState: { ...(await poolState(pool, startBlock)), asp: await memeASP() },
    note: ponsNote, amountIn: ponsNote.value, path: path(PONS, USDG) });

  // ---- 6. Screening: a direct deposit waits the delay; a deposit from an address the Safe denies in that window stays unapproved. ----
  await test.impersonateAccount({ address: PONS_WHALE });
  for (const a of [holder, flagged]) await send(test.writeContract({ account: PONS_WHALE, address: PONS, abi: ERC20, functionName: 'transfer', args: [a.address, 100n * 10n ** 18n] }));
  await test.stopImpersonatingAccount({ address: PONS_WHALE });
  const directDeposit = async (who: any) => {
    const inv = sdk.createDynamicReceive(sdk.createAccount(), memeProfile);
    await send(wallet(who).writeContract({ address: PONS, abi: ERC20, functionName: 'approve', args: [pool, 100n * 10n ** 18n] }));
    const r = await send(wallet(who).writeContract({ address: pool, abi: POOL_ABI, functionName: 'depositDynamic', args: [100n * 10n ** 18n, inv.precommitment, inv.encryptedTemplate] }));
    return events(r, [POOL_ABI]).find((e: any) => e.eventName === 'DynamicDeposited').args.commitment as bigint;
  };
  const clean = await directDeposit(holder), dirty = await directDeposit(flagged);
  log('syncOnDeposit', await sync([clean, dirty]));
  await send(wallet(safe).writeContract({ address: screening, abi: screenArt.abi, functionName: 'setDenied', args: [[flagged.address], true] }));
  log('syncBeforeDelay', await sync([clean, dirty]));
  await test.increaseTime({ seconds: Number(DELAY) }); await test.mine({ blocks: 1 });
  log('syncAfterDelay', await sync([clean, dirty]));
  log('approved', { clean: await readP('approved', [clean]), dirty: await readP('approved', [dirty]),
    dirtyRagequitStillPossibleTo: await pub.readContract({ address: pool, abi: POOL_ABI, functionName: 'originalDepositor', args: [dirty] }) });
  log('summary', { usdgSpent: 6_000_000n, ponsBought: ponsNote.value, usdgBack: usdgBack.value, epochs: (await memeASP()).epoch });
  writeFileSync(`${HERE}${OUT}`, JSON.stringify(out, null, 1));
}
main().then(() => process.exit(0), e => { console.error(e); writeFileSync(`${HERE}${OUT}`, JSON.stringify({ ...out, error: String(e?.stack ?? e) }, null, 1)); process.exit(1); });
