// Fork-only end-to-end for Phase2FeeV4Adapter: a private buy and sell of a meme that trades on a Uniswap v4 pool.
// ETH note (live ETH privacy pool) -> meme note in a fresh RC.3 pool (AutoApproveProvider ASP, as ../../auto-asp/run.mts),
// then the whole meme note back to an ETH note. Runs against anvil --fork-url <robinhood mainnet> --chain-id 4663 --port 8548.
// Never touches the real network: every transaction goes to the local fork.
import { readFileSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { resolve } from 'node:path';
import type { Hex, Log } from 'viem';

const FE = resolve(process.env.LINCOLN_FRONTEND ?? new URL('../../../../../privacy-frontend', import.meta.url).pathname);
const fromFrontend = createRequire(`${FE}/package.json`);
const snarkjs = await import(fromFrontend.resolve('snarkjs'));
const {
  createPublicClient, createTestClient, createWalletClient, decodeEventLog, encodeAbiParameters, encodePacked, http, keccak256, parseAbi,
  publicActions, stringToHex, toHex, walletActions,
} = await import(fromFrontend.resolve('viem'));
const { privateKeyToAccount, generatePrivateKey } = await import(fromFrontend.resolve('viem/accounts'));
const sdk = await import(`${FE}/src/protocol/asp/sdk.ts`);

const HERE = new URL('.', import.meta.url).pathname;
const RPC = process.env.FORK_RPC ?? 'http://127.0.0.1:8548';
const OUT = process.env.RESULT_FILE ?? `result-v4-${new Date().toISOString().slice(0, 10)}.json`;
const chain = { id: 4663, name: 'rh-fork', nativeCurrency: { name: 'ETH', symbol: 'ETH', decimals: 18 }, rpcUrls: { default: { http: [RPC] } } } as const;
const pub = createPublicClient({ chain, transport: http(RPC, { timeout: 300_000 }) });
const test = createTestClient({ chain, mode: 'anvil', transport: http(RPC, { timeout: 300_000 }) }).extend(publicActions).extend(walletActions);
const json = (f: string) => JSON.parse(readFileSync(f, 'utf8'));
const out: Record<string, unknown> = {};
const big = (v: unknown) => JSON.parse(JSON.stringify(v, (_, x) => typeof x === 'bigint' ? String(x) : x));
const log = (k: string, v: unknown) => { out[k] = big(v); console.log(k, JSON.stringify(big(v))); };

const ethProfile = json(`${FE}/src/protocol/asp/mainnet/profile.eth.json`);
const ponsProfile = json(`${FE}/src/protocol/asp/mainnet/profile.pons.json`);
const POOL_ABI = json(`${FE}/src/protocol/asp/abi/Phase2ASPPool.json`);
const REG_ABI = json(`${FE}/src/protocol/asp/abi/Phase2ASPRegistry.json`);
const own = (file: string, name: string) => json(`${HERE}../out-v4/${file}/${name}.json`);
const autoAsp = (file: string, name: string) => json(`${HERE}../../auto-asp/out/${file}/${name}.json`);
const ERC20 = parseAbi(['function balanceOf(address) view returns (uint256)', 'function symbol() view returns (string)', 'function decimals() view returns (uint8)']);
const PM_ABI = parseAbi(['function extsload(bytes32) view returns (bytes32)']);

const ZERO = '0x0000000000000000000000000000000000000000' as Hex;
const POOL_MANAGER = '0x8366a39CC670B4001A1121B8F6A443A643e40951' as Hex;
const ETH_POOL = ethProfile.pool.address as Hex;
const LIVE_REGISTRY = ethProfile.registry.address as Hex, LIVE_PROVIDER = ethProfile.registry.provider as Hex;
// Default: HOOKR/ETH, 0.25% LP fee, tick spacing 25, no hook. Override with V4_KEY='{"currency0":..,"currency1":..,"fee":..,"tickSpacing":..,"hooks":..}'.
// EXPECT_REVERT=1 stops after simulating the buy and records the adapter's revert (used for a fee-on-transfer meme).
const KEY = process.env.V4_KEY ? JSON.parse(process.env.V4_KEY) : {
  currency0: ZERO, currency1: '0x18E674231A58c239Dc7DaeDcffE15Ec3A24cff5c', fee: 2500, tickSpacing: 25, hooks: ZERO,
};
const EXPECT_REVERT = process.env.EXPECT_REVERT === '1';
class ExpectedRevert extends Error {}
const MEME = KEY.currency1 as Hex;
const LIBRARIES: Record<string, Hex> = { PoseidonT3: ponsProfile.libraries.PoseidonT3.address, PoseidonT4: ponsProfile.libraries.PoseidonT4.address };
const FEE_BPS = 30, DELAY = 3600n, DEPOSIT = BigInt(process.env.ETH_DEPOSIT ?? 10n ** 17n), BUY_IN = BigInt(process.env.ETH_IN ?? 6n * 10n ** 16n);
const V4_DOMAIN = keccak256(stringToHex('LINCOLN_PHASE2_FEE_V4_ROUTES_V1'));
const POOL_ID = keccak256(encodeAbiParameters(
  [{ type: 'address' }, { type: 'address' }, { type: 'uint24' }, { type: 'int24' }, { type: 'address' }],
  [KEY.currency0, KEY.currency1, KEY.fee, KEY.tickSpacing, KEY.hooks]));

const key = () => privateKeyToAccount(generatePrivateKey());
const deployer = key(), safe = key(), user = key(), gas = key(), stranger = key(), treasury = key().address;
const wallet = (a: any) => createWalletClient({ chain, account: a, transport: http(RPC, { timeout: 300_000 }) });

// Foundry leaves the Poseidon placeholders in; link them to the libraries already on mainnet.
function linked(art: any): Hex {
  let code: string = art.bytecode.object.slice(2);
  for (const [, libs] of Object.entries(art.bytecode.linkReferences ?? {}) as [string, Record<string, { start: number; length: number }[]>][])
    for (const [name, refs] of Object.entries(libs))
      for (const { start, length } of refs) code = code.slice(0, start * 2) + LIBRARIES[name].slice(2).toLowerCase() + code.slice((start + length) * 2);
  return `0x${code}` as Hex;
}
async function send(p: Promise<Hex>) { const hash = await p; const r = await pub.waitForTransactionReceipt({ hash, timeout: 600_000 }); if (r.status !== 'success') throw new Error(`reverted ${hash}`); return r; }
async function deploy(account: any, art: any, args: unknown[]) {
  const r = await send(wallet(account).deployContract({ abi: art.abi, bytecode: linked(art), args }));
  return { address: r.contractAddress as Hex, gasUsed: r.gasUsed };
}
const events = (receipt: any, abis: any[]) => receipt.logs.map((l: Log) => {
  for (const abi of abis) { try { return { address: l.address, ...(decodeEventLog({ abi, topics: l.topics, data: l.data }) as any) }; } catch {} }
  return null;
}).filter(Boolean);
const balance = (asset: Hex, who: Hex) => asset === ZERO ? pub.getBalance({ address: who }) : pub.readContract({ address: asset, abi: ERC20, functionName: 'balanceOf', args: [who] }) as Promise<bigint>;

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

// ---- V4 action hash / proof. The SDK's prepareFeeSwap hard-codes the V3 hash, so this mirrors it with the V4 layout. ----
type V4Route = { adapter: Hex; sourcePool: Hex; targetPool: Hex; zeroForOne: boolean };
function v4ActionHash(r: V4Route, a: any): Hex {
  return keccak256(encodeAbiParameters([
    { type: 'bytes32' }, { type: 'uint256' }, { type: 'address' }, { type: 'address' }, { type: 'address' }, { type: 'address' }, { type: 'bytes32' },
    { type: 'address' }, { type: 'address' }, { type: 'uint24' }, { type: 'int24' }, { type: 'address' }, { type: 'bool' }, { type: 'uint16' }, { type: 'address' },
    { type: 'address' }, { type: 'uint128' }, { type: 'uint128' }, { type: 'uint256' }, { type: 'uint256' }, { type: 'bytes32' }, { type: 'uint128' },
  ], [V4_DOMAIN, 4663n, r.adapter, r.sourcePool, r.targetPool, POOL_MANAGER, POOL_ID, KEY.currency0, KEY.currency1, KEY.fee, KEY.tickSpacing, KEY.hooks,
    r.zeroForOne, FEE_BPS, treasury, a.processor, a.amountIn, a.minAmountOut, a.deadline, a.targetPrecommitment, keccak256(a.encryptedTemplate), a.maxServiceFee]));
}
function prepareV4FeeSwap({ account, sourceProfile, targetProfile, sourceState, route, action, inputs }: any) {
  const invoice = sdk.createDynamicReceive(account, targetProfile);
  const a = { ...action, targetPrecommitment: invoice.precommitment, encryptedTemplate: invoice.encryptedTemplate as Hex };
  const prepared = sdk.prepareJoinSplit({ account, profile: sourceProfile, state: sourceState, inputs, outputs: [], externalData: {
    recipient: route.adapter, feeRecipient: ZERO, processor: route.adapter, publicIn: 0n, publicOut: a.amountIn, fee: 0n } });
  if (prepared.outputNotes[1].commitment !== 0n) throw new Error('second source output must be empty');
  const actionHash = v4ActionHash(route, a), actionEnvelope = `${actionHash}${'00'.repeat(224)}` as Hex;
  prepared.encryptedOutputs[1] = actionEnvelope;
  const context = sdk.joinSplitContext(sourceProfile, prepared.extData, prepared.encryptedOutputs, sourceState.asp);
  prepared.inputSignals.contextBase = sdk.joinSplitContextBase(sourceProfile, prepared.extData, prepared.encryptedOutputs);
  prepared.inputSignals.context = context; prepared.publicSignals[3] = String(context);
  return { ...prepared, action: a, actionHash, actionEnvelope };
}

async function main() {
  for (const a of [deployer, safe, user, gas, stranger]) await test.setBalance({ address: a.address, value: 10n ** 20n });
  await test.setBalance({ address: LIVE_PROVIDER, value: 10n ** 20n });
  const startBlock = await pub.getBlockNumber();
  const forkBlock = startBlock;

  // ---- 0. The v4 pool: recompute the PoolId and read slot0 / liquidity from PoolManager storage. ----
  const stateSlot = BigInt(keccak256(encodePacked(['bytes32', 'uint256'], [POOL_ID, 6n])));
  const ext = async (s: bigint) => BigInt(await pub.readContract({ address: POOL_MANAGER, abi: PM_ABI, functionName: 'extsload', args: [toHex(s, { size: 32 })] }) as Hex);
  const slot0 = await ext(stateSlot), liquidity = (await ext(stateSlot + 3n)) & ((1n << 128n) - 1n);
  const sqrtPriceX96 = slot0 & ((1n << 160n) - 1n);
  const symbol = await pub.readContract({ address: MEME, abi: ERC20, functionName: 'symbol' }), decimals = await pub.readContract({ address: MEME, abi: ERC20, functionName: 'decimals' });
  log('v4Pool', { forkBlock, poolManager: POOL_MANAGER, key: KEY, poolId: POOL_ID, symbol, decimals, sqrtPriceX96, liquidity,
    managerMemeBalance: await balance(MEME, POOL_MANAGER), managerEthBalance: await balance(ZERO, POOL_MANAGER),
    virtualEthReserve: sqrtPriceX96 ? liquidity * (1n << 96n) / sqrtPriceX96 : 0n });
  if (sqrtPriceX96 === 0n || liquidity === 0n) throw new Error('pool not initialized or without in-range liquidity');
  if (KEY.currency0 !== ZERO) throw new Error('this script routes a native-ETH v4 pool against the live ETH privacy pool');
  const quoterArt = own('V4QuoteHelper.sol', 'V4QuoteHelper');
  const quoter = (await deploy(deployer, quoterArt, [POOL_MANAGER])).address;
  const quote = async (zeroForOne: boolean, amountIn: bigint) => {
    const { result: [a0, a1] } = await pub.simulateContract({ address: quoter, abi: quoterArt.abi, functionName: 'quote', args: [KEY, zeroForOne, amountIn], account: deployer.address }) as any;
    const [inD, outD] = zeroForOne ? [a0, a1] : [a1, a0];
    if (inD !== -amountIn) throw new Error(`quote is a partial fill: ${inD}`);
    return outD as bigint;
  };

  // ---- 1. Open a meme pool without Lincoln (as auto-asp): screening list (admin = Safe), provider + registry, RC.3 pool, bind. ----
  const screenArt = autoAsp('ScreeningList.sol', 'ScreeningList'), providerArt = autoAsp('AutoApproveProvider.sol', 'AutoApproveProvider');
  const screening = (await deploy(deployer, screenArt, [safe.address])).address;
  const provider = (await deploy(deployer, providerArt, [safe.address, screening, DELAY])).address;
  const readP = (functionName: string, args: unknown[] = []) => pub.readContract({ address: provider, abi: providerArt.abi, functionName, args }) as Promise<any>;
  const registry = await readP('REGISTRY') as Hex;
  const pool = (await deploy(deployer, own('Phase2ASPPool.sol', 'Phase2ASPPool'),
    [ponsProfile.verifier.address, ponsProfile.exitVerifier.address, registry, MEME, 10n ** 30n, 10n ** 31n])).address;
  await send(wallet(deployer).writeContract({ address: provider, abi: providerArt.abi, functionName: 'bind', args: [pool] }));
  log('opened', { screening, provider, registry, pool, poolScope: await pub.readContract({ address: pool, abi: POOL_ABI, functionName: 'SCOPE' }) });

  const memeProfile = structuredClone(ponsProfile);
  Object.assign(memeProfile.pool, { address: pool, asset: MEME, startBlock: String(startBlock), scope: undefined });
  Object.assign(memeProfile.registry, { address: registry, provider, guardian: safe.address, startBlock: String(startBlock) });
  const memeASP = async () => {
    const logs = await pub.getLogs({ address: provider, fromBlock: startBlock, toBlock: 'latest' });
    const leaves = logs.map((l: Log) => { try { return decodeEventLog({ abi: providerArt.abi, topics: l.topics, data: l.data }) as any; } catch { return null; } })
      .filter((e: any) => e?.eventName === 'LeafApproved').map((e: any) => String(e.args.leaf));
    const [root, epoch, validUntil] = await pub.readContract({ address: registry, abi: REG_ABI, functionName: 'latestPolicy' }) as [bigint, bigint, bigint];
    if (sdk.buildMerkleTree(leaves).root !== root) throw new Error('association root mismatch');
    return { root: String(root), epoch: String(epoch), validUntil: String(validUntil), leaves, expired: false };
  };

  // ---- 2. V4 adapters: buy (ETH pool -> meme pool, zeroForOne) and sell (meme pool -> ETH pool). The Safe trusts the buy adapter. ----
  const adapterArt = own('Phase2FeeV4Adapter.sol', 'Phase2FeeV4Adapter');
  const buyD = await deploy(deployer, adapterArt, [ETH_POOL, pool, POOL_MANAGER, KEY, FEE_BPS, treasury]);
  const sellD = await deploy(deployer, adapterArt, [pool, ETH_POOL, POOL_MANAGER, KEY, FEE_BPS, treasury]);
  const buy = buyD.address, sell = sellD.address;
  await send(wallet(safe).writeContract({ address: screening, abi: screenArt.abi, functionName: 'setTrustedDepositor', args: [buy, true] }));
  const readA = (address: Hex, functionName: string, args: unknown[] = []) => pub.readContract({ address, abi: adapterArt.abi, functionName, args }) as Promise<any>;
  if (await readA(buy, 'POOL_ID') !== POOL_ID || await readA(buy, 'ZERO_FOR_ONE') !== true || await readA(sell, 'ZERO_FOR_ONE') !== false) throw new Error('adapter route mismatch');
  const runtime = await pub.getCode({ address: buy });
  log('adapters', { buy, sell, treasury, deployGas: [buyD.gasUsed, sellD.gasUsed], runtimeBytes: (runtime!.length - 2) / 2,
    initcodeBytes: (adapterArt.bytecode.object.length - 2) / 2, buyLimit: await readA(buy, 'SQRT_PRICE_LIMIT_X96'), sellLimit: await readA(sell, 'SQRT_PRICE_LIMIT_X96') });

  // ---- 3. A private ETH note in the live ETH pool; its live ASP provider is impersonated (as in auto-asp). ----
  const maxDeposit = await pub.readContract({ address: ETH_POOL, abi: POOL_ABI, functionName: 'maxDeposit' }) as bigint;
  if (DEPOSIT > maxDeposit) throw new Error(`deposit above the live cap ${maxDeposit}`);
  const account = sdk.createAccount();
  const invoice = sdk.createDynamicReceive(account, ethProfile);
  const depR = await send(wallet(user).writeContract({ address: ETH_POOL, abi: POOL_ABI, functionName: 'depositDynamic', value: DEPOSIT, args: [DEPOSIT, invoice.precommitment, invoice.encryptedTemplate] }));
  const depEv = events(depR, [POOL_ABI]).find((e: any) => e.eventName === 'DynamicDeposited');
  const ethNote = sdk.decryptDynamicReceipt(account, ethProfile, depEv.args);
  const ethLeaves = [String(sdk.associationLeaf(ethNote.commitment, ethProfile))];
  const now = (await pub.getBlock()).timestamp;
  await test.impersonateAccount({ address: LIVE_PROVIDER });
  await send(test.writeContract({ account: LIVE_PROVIDER, address: LIVE_REGISTRY, abi: REG_ABI, functionName: 'updateRoot', args: [sdk.buildMerkleTree(ethLeaves).root, sdk.associationSetDigest(ethLeaves), now + 7n * 86400n] }));
  await test.stopImpersonatingAccount({ address: LIVE_PROVIDER });
  const [lr, le, lv] = await pub.readContract({ address: LIVE_REGISTRY, abi: REG_ABI, functionName: 'latestPolicy' }) as [bigint, bigint, bigint];
  const ethASP = { root: String(lr), epoch: String(le), validUntil: String(lv), leaves: ethLeaves, expired: false };
  log('ethNote', { deposit: DEPOSIT, maxDeposit, commitment: ethNote.commitment, depositGas: depR.gasUsed });

  async function feeSwap(label: string, o: { adapter: Hex; zeroForOne: boolean; source: any; target: any; sourceState: any; note: any; amountIn: bigint; output: Hex }) {
    const gross = await quote(o.zeroForOne, o.amountIn);
    const fee = gross * BigInt(FEE_BPS) / 10_000n, minNet = (gross - fee) * 99n / 100n, maxServiceFee = fee * 101n / 100n + 1n;
    const route = { adapter: o.adapter, sourcePool: o.source.pool.address, targetPool: o.target.pool.address, zeroForOne: o.zeroForOne };
    const prepared = prepareV4FeeSwap({ account, sourceProfile: o.source, targetProfile: o.target, sourceState: o.sourceState, route, inputs: [o.note],
      action: { processor: gas.address, amountIn: o.amountIn, minAmountOut: minNet, deadline: BigInt(o.sourceState.blockTimestamp) + 3600n, maxServiceFee } });
    const action = { ...prepared.action, processor: prepared.action.processor as Hex };
    const onchainHash = await readA(o.adapter, 'actionHash', [action]);
    if (onchainHash !== prepared.actionHash) throw new Error(`action hash mismatch: script ${prepared.actionHash} vs adapter ${onchainHash}`);
    const c = json(`${FE}/src/protocol/asp/mainnet/circuits.json`).joinsplit;
    const file = (p: string) => new Uint8Array(readFileSync(`${FE}/public${p}`));
    const t0 = Date.now();
    const { proof, publicSignals } = await snarkjs.groth16.fullProve(big(prepared.inputSignals), { type: 'mem', data: file(c.wasm.path) } as any, { type: 'mem', data: file(c.zkey.path) } as any);
    const proveMs = Date.now() - t0;
    if (JSON.stringify(publicSignals) !== JSON.stringify(prepared.publicSignals)) throw new Error('public signal mismatch');
    const tx = sdk.publicTransaction(prepared, proof);
    const args = [action,
      { pA: tx.pA.map(BigInt), pB: tx.pB.map((row: string[]) => row.map(BigInt)), pC: tx.pC.map(BigInt), pubSignals: tx.pubSignals.map(BigInt) },
      { recipient: tx.extData.recipient, feeRecipient: tx.extData.feeRecipient, processor: tx.extData.processor, publicIn: BigInt(tx.extData.publicIn), publicOut: BigInt(tx.extData.publicOut), fee: BigInt(tx.extData.fee) },
      tx.encryptedOutputs];
    // The same calldata from anyone but the bound processor reverts.
    let strangerReverted = false;
    try { await pub.simulateContract({ address: o.adapter, abi: adapterArt.abi, functionName: 'swap', args, account: stranger.address }); } catch { strangerReverted = true; }
    if (!strangerReverted) throw new Error('stranger could submit the swap');
    if (EXPECT_REVERT) {
      try { await pub.simulateContract({ address: o.adapter, abi: adapterArt.abi, functionName: 'swap', args, account: gas.address, gas: 5_000_000n }); }
      catch (e: any) {
        const name = e?.cause?.data?.errorName ?? e?.walk?.((x: any) => x?.data?.errorName)?.data?.errorName ?? String(e?.shortMessage ?? e);
        log(label, { expectedRevert: true, error: name, amountIn: o.amountIn, quotedGross: gross, actionHash: prepared.actionHash, actionHashMatchesAdapter: true, strangerReverted });
        throw new ExpectedRevert(name);
      }
      throw new Error('swap was expected to revert');
    }
    const before = { treasury: await balance(o.output, treasury), target: await balance(o.output, o.target.pool.address), adapterIn: await balance(KEY.currency0, o.adapter), adapterOut: await balance(MEME, o.adapter) };
    const r = await send(wallet(gas).writeContract({ address: o.adapter, abi: adapterArt.abi, functionName: 'swap', gas: 5_000_000n, args }));
    const evs = events(r, [adapterArt.abi, POOL_ABI]);
    const reshield = evs.find((e: any) => e.eventName === 'SwapReshielded'), paid = evs.find((e: any) => e.eventName === 'ServiceFeePaid');
    const dep = evs.find((e: any) => e.eventName === 'DynamicDeposited' && e.address.toLowerCase() === o.target.pool.address.toLowerCase());
    const received = sdk.decryptDynamicReceipt(account, o.target, dep.args);
    const after = { treasury: await balance(o.output, treasury), target: await balance(o.output, o.target.pool.address), adapterIn: await balance(KEY.currency0, o.adapter), adapterOut: await balance(MEME, o.adapter) };
    if (after.treasury - before.treasury !== paid.args.serviceFee || after.target - before.target !== reshield.args.amountOut
      || after.adapterIn !== before.adapterIn || after.adapterOut !== before.adapterOut || received.value !== reshield.args.amountOut) throw new Error('balance check failed');
    log(label, { tx: r.transactionHash, gasUsed: r.gasUsed, proveMs, processor: r.from, actionHash: prepared.actionHash, actionHashMatchesAdapter: true, strangerReverted,
      amountIn: o.amountIn, quotedGross: gross, gross: paid.args.grossAmountOut, serviceFee: paid.args.serviceFee, amountOutNet: reshield.args.amountOut, minAmountOut: minNet, maxServiceFee,
      note: { commitment: received.commitment, value: received.value } });
    return received;
  }

  // ---- 4. Buy: part of the ETH note -> meme note in the new pool, through the v4 pool. ----
  const ethState = { ...(await poolState(ETH_POOL, BigInt(ethProfile.pool.startBlock))), asp: ethASP };
  const memeNote = await feeSwap('buy', { adapter: buy, zeroForOne: true, source: ethProfile, target: memeProfile, sourceState: ethState, note: ethNote, amountIn: BUY_IN, output: MEME });

  // ---- 5. Sync the bought note: deposited by the trusted buy adapter, so approved at once. ----
  const sr = await send(wallet(gas).writeContract({ address: provider, abi: providerArt.abi, functionName: 'sync', args: [[memeNote.commitment]] }));
  log('syncBuyOutput', { gasUsed: sr.gasUsed, approved: await readP('approved', [memeNote.commitment]) });

  // ---- 6. Sell: the whole meme note -> ETH note in the live ETH pool. ----
  const memeState = { ...(await poolState(pool, startBlock)), asp: await memeASP() };
  const ethBack = await feeSwap('sell', { adapter: sell, zeroForOne: false, source: memeProfile, target: ethProfile, sourceState: memeState, note: memeNote, amountIn: memeNote.value, output: ZERO });

  log('summary', { ethSpent: BUY_IN, memeBought: memeNote.value, ethBack: ethBack.value, roundTripCostBps: (BUY_IN - ethBack.value) * 10_000n / BUY_IN,
    treasuryMeme: await balance(MEME, treasury), treasuryEth: await balance(ZERO, treasury),
    adapterBalances: { buyEth: await balance(ZERO, buy), buyMeme: await balance(MEME, buy), sellEth: await balance(ZERO, sell), sellMeme: await balance(MEME, sell) } });
  writeFileSync(`${HERE}${OUT}`, JSON.stringify(out, null, 1));
}
main().then(() => process.exit(0), e => {
  if (e instanceof ExpectedRevert) { writeFileSync(`${HERE}${OUT}`, JSON.stringify(out, null, 1)); process.exit(0); } console.error(e); writeFileSync(`${HERE}${OUT}`, JSON.stringify({ ...out, error: String(e?.stack ?? e) }, null, 1)); process.exit(1); });
