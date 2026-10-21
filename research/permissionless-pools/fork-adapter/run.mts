// Fork-only end-to-end: third-party Phase2FeeRouter02Adapter USDG -> PONS, self-submitted by a fresh gas wallet.
// Runs against anvil --fork-url <robinhood mainnet> --chain-id 4663 --port 8547. Never touches the real network.
import { readFileSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { resolve } from 'node:path';
import type { Hex, Log } from 'viem';

// The note SDK, circuits and pool profiles live in the frontend checkout; viem and snarkjs resolve from it too.
const FE = resolve(process.env.LINCOLN_FRONTEND ?? new URL('../../../../privacy-frontend', import.meta.url).pathname);
const fromFrontend = createRequire(`${FE}/package.json`);
const snarkjs = await import(fromFrontend.resolve('snarkjs'));
const {
  createPublicClient, createTestClient, createWalletClient, decodeEventLog, encodeAbiParameters, http, keccak256, parseAbi,
  publicActions, walletActions,
} = await import(fromFrontend.resolve('viem'));
const { privateKeyToAccount, generatePrivateKey } = await import(fromFrontend.resolve('viem/accounts'));
const sdk = await import(`${FE}/src/protocol/asp/sdk.ts`);
const HERE = new URL('.', import.meta.url).pathname;
const RPC = process.env.FORK_RPC ?? 'http://127.0.0.1:8547';
const chain = { id: 4663, name: 'rh-fork', nativeCurrency: { name: 'ETH', symbol: 'ETH', decimals: 18 }, rpcUrls: { default: { http: [RPC] } } } as const;
const pub = createPublicClient({ chain, transport: http(RPC, { timeout: 120_000 }) });
const test = createTestClient({ chain, mode: 'anvil', transport: http(RPC) }).extend(publicActions).extend(walletActions);
const json = (f: string) => JSON.parse(readFileSync(f, 'utf8'));
const out: Record<string, unknown> = {};
const log = (k: string, v: unknown) => { out[k] = v; console.log(k, typeof v === 'bigint' ? String(v) : v); };
const OUT = process.env.RESULT_FILE ?? 'result.json';
const big = (v: unknown) => JSON.parse(JSON.stringify(v, (_, x) => typeof x === 'bigint' ? String(x) : x));

const usdgProfile = json(`${FE}/src/protocol/asp/mainnet/profile.usdg.json`) as any;
const ponsProfile = json(`${FE}/src/protocol/asp/mainnet/profile.pons.json`) as any;
const POOL_ABI = json(`${FE}/src/protocol/asp/abi/Phase2ASPPool.json`);
const REG_ABI = json(`${FE}/src/protocol/asp/abi/Phase2ASPRegistry.json`);
const art = json(`${HERE}out/Phase2FeeRouteAdapter.sol/Phase2FeeRouter02Adapter.json`);
const ADAPTER_ABI = art.abi, BYTECODE = art.bytecode.object as Hex;
const ERC20 = parseAbi(['function balanceOf(address) view returns (uint256)', 'function transfer(address,uint256) returns (bool)', 'function approve(address,uint256) returns (bool)']);
const QUOTER_ABI = parseAbi(['function quoteExactInput(bytes path, uint256 amountIn) returns (uint256 amountOut, uint160[] sqrtPriceX96AfterList, uint32[] initializedTicksCrossedList, uint256 gasEstimate)']);

const USDG = '0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168' as Hex, PONS = '0x39dBED3a2bd333467115dE45665cC57F813C4571' as Hex;
const SRC = usdgProfile.pool.address as Hex, TGT = ponsProfile.pool.address as Hex;
const ROUTER = '0xCaf681a66D020601342297493863E78C959E5cb2' as Hex, FACTORY = '0x1f7d7550B1b028f7571E69A784071F0205FD2EfA' as Hex;
const QUOTER = '0x33e885eD0Ec9bF04EcfB19341582aADCb4c8A9E7' as Hex, WETH = '0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73' as Hex;
const REGISTRY = usdgProfile.registry.address as Hex, PROVIDER = usdgProfile.registry.provider as Hex;
const USDG_WHALE = '0xf2A0bE59AB76b96f957bd5E5b967F2B75e8dB269' as Hex; // non-Uniswap V3 pool holding ~297k USDG
const FEE_BPS = 30;
const pathFor = (fee: number) => `0x${USDG.slice(2)}${fee.toString(16).padStart(6, '0')}${PONS.slice(2)}`.toLowerCase() as Hex;

// Actors: deployer (route owner == nobody; adapter is ownerless), user (depositor/wallet), gas wallet (fresh EOA).
const deployer = privateKeyToAccount('0xac0974bec39a17e36ba4a84b5ffc8b8ae13bd3b3c0a0d0d3d4ab9deb9be9c6c5');
const user = privateKeyToAccount(generatePrivateKey());
const gas = privateKeyToAccount(generatePrivateKey());
const treasury = privateKeyToAccount(generatePrivateKey()).address;
const wallet = (a: any) => createWalletClient({ chain, account: a, transport: http(RPC) });

async function send(p: Promise<Hex>) { const hash = await p; const r = await pub.waitForTransactionReceipt({ hash }); if (r.status !== 'success') throw new Error(`reverted ${hash}`); return r; }

async function poolLogs(address: Hex, from: bigint, head: bigint) {
  const logs: Log[] = []; let span = 200_000n;
  for (let cursor = from; cursor <= head;) {
    const to = cursor + span - 1n < head ? cursor + span - 1n : head;
    try { logs.push(...await pub.getLogs({ address, fromBlock: cursor, toBlock: to })); cursor = to + 1n; }
    catch (e) { if (span <= 1_000n) throw e; span /= 4n; }
  }
  return logs.sort((a, b) => Number(a.blockNumber! - b.blockNumber!) || a.logIndex! - b.logIndex!);
}
async function poolState(profile: any) {
  const address = profile.pool.address as Hex, head = await pub.getBlockNumber();
  const logs = await poolLogs(address, BigInt(profile.pool.startBlock), head);
  const commitments: string[] = [], nullifiers: string[] = [], receipts: any[] = [];
  for (const l of logs) {
    let ev: any; try { ev = decodeEventLog({ abi: POOL_ABI, topics: l.topics, data: l.data, strict: true }); } catch { continue; }
    const a = ev.args;
    if (ev.eventName === 'NewCommitment') { if (Number(a.index) !== commitments.length) throw new Error('gap'); commitments.push(String(a.commitment)); receipts.push({ commitment: String(a.commitment), index: Number(a.index), encryptedOutput: a.encryptedOutput }); }
    else if (ev.eventName === 'NewNullifier') nullifiers.push(String(a.nullifier));
    else if (ev.eventName === 'DynamicDeposited') Object.assign(receipts.at(-1), { value: String(a.value), precommitment: String(a.precommitment), encryptedTemplate: a.encryptedTemplate });
  }
  const root = sdk.buildMerkleTree(commitments).root;
  const onchain = await pub.readContract({ address, abi: POOL_ABI, functionName: 'currentRoot' }) as bigint;
  if (root !== onchain) throw new Error(`root mismatch ${root} vs ${onchain}`);
  const block = await pub.getBlock();
  return { chainId: 4663, pool: address, root: String(root), commitments, nullifiers, receipts, blockTimestamp: String(block.timestamp) };
}

async function main() {
  for (const a of [deployer.address, user.address, gas.address, USDG_WHALE, PROVIDER]) await test.setBalance({ address: a, value: 10n ** 20n });
  log('actors', { deployer: deployer.address, user: user.address, gasWallet: gas.address, treasury });

  // ---- 1. Deploy a third-party adapter. First show what fee 1800 does on the Uniswap factory. ----
  const args = (fee: number) => [SRC, TGT, ROUTER, WETH, 0, pathFor(fee), FEE_BPS, treasury] as const;
  try {
    await pub.estimateGas({ account: deployer.address, data: (BYTECODE + encodeAbiParameters(
      [{ type: 'address' }, { type: 'address' }, { type: 'address' }, { type: 'address' }, { type: 'uint8' }, { type: 'bytes' }, { type: 'uint16' }, { type: 'address' }], args(1800) as any).slice(2)) as Hex });
    log('deploy1800', 'unexpectedly accepted');
  } catch (e: any) { log('deploy1800', `rejected: ${(e.shortMessage ?? e.message).split('\n')[0]} ${e.cause?.data ?? e.cause?.cause?.data ?? ''}`); }
  const FEE_TIER = Number(process.env.FEE_TIER ?? 500);
  const deployHash = await wallet(deployer).deployContract({ abi: ADAPTER_ABI, bytecode: BYTECODE, args: args(FEE_TIER) as any });
  const dr = await pub.waitForTransactionReceipt({ hash: deployHash });
  if (dr.status !== 'success') throw new Error('deploy reverted');
  const adapter = dr.contractAddress! as Hex;
  const code = await pub.getCode({ address: adapter });
  log('adapter', { address: adapter, feeTier: FEE_TIER, gasUsed: dr.gasUsed, runtimeCodeHash: keccak256(code!),
    constructorArgs: encodeAbiParameters([{ type: 'address' }, { type: 'address' }, { type: 'address' }, { type: 'address' }, { type: 'uint8' }, { type: 'bytes' }, { type: 'uint16' }, { type: 'address' }], args(FEE_TIER) as any) });
  const rd = async (fn: string) => pub.readContract({ address: adapter, abi: ADAPTER_ABI, functionName: fn });
  log('adapterImmutables', big({ SOURCE_POOL: await rd('SOURCE_POOL'), TARGET_POOL: await rd('TARGET_POOL'), FACTORY: await rd('FACTORY'), FEE_BPS: await rd('FEE_BPS'), TREASURY: await rd('TREASURY'), HOPS: await rd('HOPS'), hopPools: await rd('hopPools') }));

  // ---- 2. Fund user with USDG, depositDynamic into the USDG pool. ----
  const DEPOSIT = 10_000_000n; // 10 USDG
  await test.impersonateAccount({ address: USDG_WHALE });
  await send(test.writeContract({ account: USDG_WHALE, address: USDG, abi: ERC20, functionName: 'transfer', args: [user.address, DEPOSIT] }));
  await test.stopImpersonatingAccount({ address: USDG_WHALE });
  const account = sdk.createAccount();
  const invoice = sdk.createDynamicReceive(account, usdgProfile);
  await send(wallet(user).writeContract({ address: USDG, abi: ERC20, functionName: 'approve', args: [SRC, DEPOSIT] }));
  const depR = await send(wallet(user).writeContract({ address: SRC, abi: POOL_ABI, functionName: 'depositDynamic', args: [DEPOSIT, invoice.precommitment, invoice.encryptedTemplate] }));
  const depEv = depR.logs.map(l => { try { return decodeEventLog({ abi: POOL_ABI, topics: l.topics, data: l.data }) as any; } catch { return null; } }).find(e => e?.eventName === 'DynamicDeposited');
  const note = sdk.decryptDynamicReceipt(account, usdgProfile, { value: depEv.args.value, precommitment: depEv.args.precommitment, commitment: depEv.args.commitment, encryptedTemplate: depEv.args.encryptedTemplate });
  log('deposit', { tx: depR.transactionHash, commitment: String(note.commitment), value: String(note.value), gasUsed: String(depR.gasUsed) });

  // ---- 3. ASP approval on the fork: impersonate PROVIDER, publish a root containing our note's association leaf. ----
  const leaves = [String(sdk.associationLeaf(note.commitment, usdgProfile))];
  const aspRoot = sdk.buildMerkleTree(leaves).root, digest = sdk.associationSetDigest(leaves);
  const now = (await pub.getBlock()).timestamp, validUntil = now + 7n * 86400n;
  await test.impersonateAccount({ address: PROVIDER });
  await send(test.writeContract({ account: PROVIDER, address: REGISTRY, abi: REG_ABI, functionName: 'updateRoot', args: [aspRoot, digest, validUntil] }));
  await test.stopImpersonatingAccount({ address: PROVIDER });
  const [lr, le, lv] = await pub.readContract({ address: REGISTRY, abi: REG_ABI, functionName: 'latestPolicy' }) as [bigint, bigint, bigint];
  const asp = { root: String(lr), epoch: String(le), validUntil: String(lv), leaves, cidDigest: digest, expired: false };
  log('asp', asp);

  // ---- 4. Build the fee-route swap proof with the frontend SDK. ----
  const state = { ...(await poolState(usdgProfile)), asp } as any;
  log('sourceState', { leaves: state.commitments.length, root: state.root });
  const route = { id: 'self-usdg-to-pons', adapterType: 'Phase2FeeRouter02Adapter', adapter, router: ROUTER, factory: FACTORY, quoter: QUOTER, wrappedNative: WETH,
    protocol: 0, path: pathFor(FEE_TIER), feeBps: FEE_BPS, treasury, sourcePool: SRC, targetPool: TGT };
  const AMOUNT_IN = 6_000_000n; // 6 USDG; leaves 4 USDG change in the source pool
  const { result: [grossQuote] } = await pub.simulateContract({ address: QUOTER, abi: QUOTER_ABI, functionName: 'quoteExactInput', args: [route.path, AMOUNT_IN] }) as any;
  const netQuote = grossQuote - sdk.serviceFee(grossQuote, FEE_BPS), minNet = netQuote * 99n / 100n, maxServiceFee = sdk.serviceFee(grossQuote, FEE_BPS) * 101n / 100n + 1n;
  log('quote', { grossQuote: String(grossQuote), netQuote: String(netQuote), minNet: String(minNet), maxServiceFee: String(maxServiceFee) });
  const deadline = now + 3600n;
  const prepared = sdk.prepareFeeSwap({ account, sourceProfile: usdgProfile, targetProfile: ponsProfile, sourceState: state, route, inputs: [note],
    action: { processor: gas.address, amountIn: AMOUNT_IN, minAmountOut: minNet, deadline, maxServiceFee } });
  // Cross-check the SDK action hash against the deployed adapter's own actionHash.
  const actionTuple = { ...prepared.action, encryptedTemplate: prepared.action.encryptedTemplate as Hex, processor: prepared.action.processor as Hex };
  const onchainHash = await pub.readContract({ address: adapter, abi: ADAPTER_ABI, functionName: 'actionHash', args: [actionTuple] });
  log('actionHashMatch', { sdk: prepared.actionHash, adapter: onchainHash, equal: onchainHash === prepared.actionHash });
  const c = json(`${FE}/src/protocol/asp/mainnet/circuits.json`).joinsplit;
  const file = (p: string) => new Uint8Array(readFileSync(`${FE}/public${p}`));
  const t0 = Date.now();
  const { proof, publicSignals } = await snarkjs.groth16.fullProve(big(prepared.inputSignals), { type: 'mem', data: file(c.wasm.path) } as any, { type: 'mem', data: file(c.zkey.path) } as any);
  log('proveMs', Date.now() - t0);
  if (JSON.stringify(publicSignals) !== JSON.stringify(prepared.publicSignals)) throw new Error('public signal mismatch');
  log('localVerify', await snarkjs.groth16.verify(json(`${FE}/public${c.vkey.path}`), publicSignals, proof));
  const tx = sdk.publicTransaction(prepared, proof);

  // ---- 5. Self-submit adapter.swap from the fresh gas wallet. ----
  const before = {
    treasuryPons: await pub.readContract({ address: PONS, abi: ERC20, functionName: 'balanceOf', args: [treasury] }),
    tgtLeaves: await pub.readContract({ address: TGT, abi: POOL_ABI, functionName: 'nextLeafIndex' }) as bigint,
    srcLeaves: await pub.readContract({ address: SRC, abi: POOL_ABI, functionName: 'nextLeafIndex' }) as bigint,
    tgtPons: await pub.readContract({ address: PONS, abi: ERC20, functionName: 'balanceOf', args: [TGT] }),
  };
  const swapArgs = [actionTuple, { pA: tx.pA.map(BigInt), pB: tx.pB.map(r => r.map(BigInt)), pC: tx.pC.map(BigInt), pubSignals: tx.pubSignals.map(BigInt) },
    { recipient: tx.extData.recipient, feeRecipient: tx.extData.feeRecipient, processor: tx.extData.processor, publicIn: BigInt(tx.extData.publicIn), publicOut: BigInt(tx.extData.publicOut), fee: BigInt(tx.extData.fee) },
    tx.encryptedOutputs] as const;
  writeFileSync(`${HERE}swap-call.json`, JSON.stringify(big({ adapter, args: swapArgs }), null, 1));
  // Negative control: the same calldata from anyone other than action.processor must revert InvalidProcessor.
  try { await pub.simulateContract({ account: user.address, address: adapter, abi: ADAPTER_ABI, functionName: 'swap', args: swapArgs as any }); log('wrongSender', 'unexpectedly accepted'); }
  catch (e: any) { log('wrongSender', (e.shortMessage ?? e.message).split('\n').slice(0, 2).join(' ')); }
  const swapHash = await wallet(gas).writeContract({ address: adapter, abi: ADAPTER_ABI, functionName: 'swap', args: swapArgs as any, gas: 3_000_000n });
  const sr = await pub.waitForTransactionReceipt({ hash: swapHash });
  log('swapTx', { hash: swapHash, status: sr.status, gasUsed: String(sr.gasUsed), from: sr.from });
  if (sr.status !== 'success') throw new Error('swap reverted');

  // ---- 6. Verify. ----
  const evs = sr.logs.map(l => { for (const abi of [ADAPTER_ABI, POOL_ABI]) { try { return { address: l.address, ...(decodeEventLog({ abi, topics: l.topics, data: l.data }) as any) }; } catch {} } return null; }).filter(Boolean);
  const reshield = evs.find((e: any) => e.eventName === 'SwapReshielded'), fee = evs.find((e: any) => e.eventName === 'ServiceFeePaid');
  const tgtDep = evs.find((e: any) => e.eventName === 'DynamicDeposited' && e.address.toLowerCase() === TGT.toLowerCase());
  const ponsNote = sdk.decryptDynamicReceipt(account, ponsProfile, { value: tgtDep.args.value, precommitment: tgtDep.args.precommitment, commitment: tgtDep.args.commitment, encryptedTemplate: tgtDep.args.encryptedTemplate });
  const after = {
    treasuryPons: await pub.readContract({ address: PONS, abi: ERC20, functionName: 'balanceOf', args: [treasury] }),
    tgtLeaves: await pub.readContract({ address: TGT, abi: POOL_ABI, functionName: 'nextLeafIndex' }) as bigint,
    srcLeaves: await pub.readContract({ address: SRC, abi: POOL_ABI, functionName: 'nextLeafIndex' }) as bigint,
    tgtPons: await pub.readContract({ address: PONS, abi: ERC20, functionName: 'balanceOf', args: [TGT] }),
  };
  // Change note in the source pool (encryptedOutputs[0]) also decrypts for the user.
  const changeNote = sdk.decryptReceipt(account, usdgProfile, prepared.outputNotes[0].commitment, tx.encryptedOutputs[0]);
  log('verify', big({
    swapReshielded: reshield?.args, serviceFeePaid: fee?.args, before, after,
    treasuryDelta: (after.treasuryPons as bigint) - (before.treasuryPons as bigint), targetPoolPonsDelta: (after.tgtPons as bigint) - (before.tgtPons as bigint),
    targetNewLeaves: after.tgtLeaves - before.tgtLeaves, sourceNewLeaves: after.srcLeaves - before.srcLeaves,
    ponsNote: { commitment: ponsNote.commitment, value: ponsNote.value, ownedByTestWallet: ponsNote.ownerPublicKey === BigInt(sdk.receiverAddress(account, ponsProfile).ownerPublicKey) },
    changeNote: { commitment: changeNote.commitment, value: changeNote.value },
    ponsCommitmentKnown: await pub.readContract({ address: TGT, abi: POOL_ABI, functionName: 'commitments', args: [ponsNote.commitment] }),
  }));
  writeFileSync(`${HERE}${OUT}`, JSON.stringify(big(out), null, 1));
}
main().then(() => process.exit(0), e => { console.error(e); writeFileSync(`${HERE}${OUT}`, JSON.stringify(big({ ...out, error: String(e?.stack ?? e) }), null, 1)); process.exit(1); });
