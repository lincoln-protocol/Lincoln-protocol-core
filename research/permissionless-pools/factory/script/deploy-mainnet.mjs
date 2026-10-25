// LincolnMemeFactory rollout on Robinhood Chain mainnet: pin, plan, deploy (resumable) and verify.
//   node script/deploy-mainnet.mjs --pin --screening-delay <seconds> --screening-admin <0x…>   (after review; writes deploy-plan.json)
//   node script/deploy-mainnet.mjs --plan                       (read-only preflight; prints the predicted addresses)
//   script/deploy-mainnet.sh                                    (interactive; asks for the lincoln-deployer keystore password)
//   node script/deploy-mainnet.mjs --verify                     (post-deploy checks against the recorded addresses)
// RPC_URL overrides the RPC. Rehearsal only: FORK_UNLOCKED=1 sends as lincoln-deployer through an anvil fork's
// impersonation (same account and nonce as mainnet, so the same predicted addresses), refused unless RPC_URL is local.
//
// Rollout (10 transactions from lincoln-deployer, in this order):
//   1 ScreeningList(admin)                 4 V3RouteDeployer(router, WETH, 30, Safe)   7-10 setFactory(factory) on the
//   2 PoolDeployer(verifier, exitVerifier) 5 V4RouteDeployer(poolManager, 30, Safe)        four deployers
//   3 ProviderDeployer(Safe, screening, delay)   6 LincolnMemeFactory(deployers…, [ETH pool, USDG pool])
// Each contract's address is predicted from the deployer's nonce and checked against its receipt; a state file
// records finished steps so an interrupted rollout resumes instead of starting over.
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const PROJECT = join(HERE, '..');
const RPC = process.env.RPC_URL ?? 'https://rpc.mainnet.chain.robinhood.com/';
// PLAN_FILE / STATE_FILE: rehearsals keep their files out of the repo.
const PLAN = process.env.PLAN_FILE ?? join(PROJECT, 'deploy-plan.json');
const STATE = process.env.STATE_FILE ?? join(PROJECT, 'deploy-state.json');
const RECORD = join(PROJECT, '..', '..', '..', 'deployments', 'robinhood-mainnet', 'meme-factory.json');
const LOCAL = /^https?:\/\/(127\.0\.0\.1|localhost)(:\d+)?\/?$/.test(RPC);

// Live mainnet contracts the factory builds on (frontend profiles and core deployments; checked for code in preflight).
const M = {
  chainId: 4663,
  deployer: '0x555998Ba2B2723C97d91FB20Da0ddb896749797e',
  safe: '0x9CF17a6E3c75D200f58283A165C442a8A3994555',            // guardian of every pool, route fee treasury
  verifier: '0xA5bC542708D7fEBD706E7fD78caD2ACa785B9dF4',
  exitVerifier: '0xF430E5d1aa6d970de10C745DC04cb7e7E1F53Ab5',
  libraries: { PoseidonT3: '0x4781B6D29Dd0CeFEf101049E23f31D2165a553fa', PoseidonT4: '0x9096D809dc96BCeE1F9c7b64BAd8F79FA6dCF165' },
  ethPool: '0xF9c767CAb9B9A7dE8Dd959967269787880267ab2',
  usdgPool: '0x5Cd4c081eb747406DAb66e22004324600f1928C9',
  v3Router: '0xCaf681a66D020601342297493863E78C959E5cb2',
  weth: '0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73',
  v4PoolManager: '0x8366a39CC670B4001A1121B8F6A443A643e40951',
  routeFeeBps: 30,
  minScreeningDelay: 600,
  minBalanceWei: 10_000_000_000_000_000n,
};
const STEPS = [
  { id: 'screening', file: 'ScreeningList.sol', contract: 'ScreeningList' },
  { id: 'poolDeployer', file: 'Deployers.sol', contract: 'PoolDeployer' },
  { id: 'providerDeployer', file: 'Deployers.sol', contract: 'ProviderDeployer' },
  { id: 'v3Routes', file: 'Deployers.sol', contract: 'V3RouteDeployer' },
  { id: 'v4Routes', file: 'Deployers.sol', contract: 'V4RouteDeployer' },
  { id: 'factory', file: 'LincolnMemeFactory.sol', contract: 'LincolnMemeFactory' },
];
const DEPLOYERS = ['poolDeployer', 'providerDeployer', 'v3Routes', 'v4Routes'];

const cast = (...args) => execFileSync('cast', args, { encoding: 'utf8' }).trim();
const fail = message => { console.error(JSON.stringify({ error: message })); process.exit(1); };
const lower = s => s.toLowerCase();
const arg = name => { const i = process.argv.indexOf(name); return i > 0 ? process.argv[i + 1] : undefined; };
const artifact = (file, contract) => JSON.parse(readFileSync(join(PROJECT, 'out', file, `${contract}.json`), 'utf8'));
const strip = s => s.replace(/a264697066735822[0-9a-f]{68}64736f6c6343[0-9a-f]{6}0033$/, '');
const linkCode = (object, linkReferences) => {
  let code = object.replace(/^0x/, '');
  for (const libs of Object.values(linkReferences ?? {}))
    for (const [name, refs] of Object.entries(libs)) {
      if (!M.libraries[name]) fail(`UNKNOWN_LIBRARY ${name}`);
      for (const { start, length } of refs) code = code.slice(0, start * 2) + M.libraries[name].slice(2).toLowerCase() + code.slice((start + length) * 2);
    }
  if (/__\$[0-9a-f]{34}\$__/.test(code)) fail('UNLINKED_PLACEHOLDER');
  return code;
};
const creation = step => { const a = artifact(step.file, step.contract); return linkCode(a.bytecode.object, a.bytecode.linkReferences); };
const encode = (sig, ...values) => cast('abi-encode', sig, ...values.map(String)).slice(2);
const constructorArgs = (id, p, addr) => ({
  screening: () => encode('constructor(address)', p.screeningAdmin),
  poolDeployer: () => encode('constructor(address,address)', M.verifier, M.exitVerifier),
  providerDeployer: () => encode('constructor(address,address,uint64)', M.safe, addr.screening, p.screeningDelay),
  v3Routes: () => encode('constructor(address,address,uint16,address)', M.v3Router, M.weth, M.routeFeeBps, M.safe),
  v4Routes: () => encode('constructor(address,uint16,address)', M.v4PoolManager, M.routeFeeBps, M.safe),
  factory: () => encode('constructor(address,address,address,address,address[])', addr.poolDeployer, addr.providerDeployer, addr.v3Routes, addr.v4Routes, `[${M.ethPool},${M.usdgPool}]`),
})[id]();
const predict = nonce => STEPS.reduce((a, s, i) => ({ ...a, [s.id]: cast('compute-address', M.deployer, '--nonce', String(nonce + i)).split(' ').pop() }), {});
const readPlan = () => { if (!existsSync(PLAN)) fail('NO_PLAN: run --pin after the review'); return JSON.parse(readFileSync(PLAN, 'utf8')); };
const readState = () => existsSync(STATE) ? JSON.parse(readFileSync(STATE, 'utf8')) : null;

function pin() {
  const screeningDelay = Number(arg('--screening-delay')), screeningAdmin = arg('--screening-admin');
  if (!Number.isInteger(screeningDelay) || screeningDelay < M.minScreeningDelay) fail(`--screening-delay must be whole seconds >= ${M.minScreeningDelay}`);
  if (!/^0x[0-9a-fA-F]{40}$/.test(screeningAdmin ?? '')) fail('--screening-admin must be an address');
  const plan = {
    schema: 'lincoln-meme-factory-deploy-plan/v1', chainId: M.chainId, deployer: M.deployer, status: 'not-deployed',
    parameters: { screeningDelay, screeningAdmin: cast('to-check-sum-address', screeningAdmin) },
    constants: { ...M, minBalanceWei: String(M.minBalanceWei) },
    compiler: { solc: '0.8.28', viaIR: true, optimizerRuns: 10000, evmVersion: 'cancun' },
    sources: Object.fromEntries(['ScreeningList', 'Deployers', 'LincolnMemeFactory', 'AutoApproveProvider', 'Phase2FeeV4Adapter'].map(n =>
      [n, execFileSync('shasum', ['-a', '256', join(PROJECT, 'src', `${n}.sol`)], { encoding: 'utf8' }).split(' ')[0]])),
    creationCodeKeccak: Object.fromEntries(STEPS.map(s => [s.id, cast('keccak', `0x${creation(s)}`)])),
  };
  writeFileSync(PLAN, JSON.stringify(plan, null, 1) + '\n');
  console.log(JSON.stringify({ pinned: PLAN, parameters: plan.parameters, creationCodeKeccak: plan.creationCodeKeccak }, null, 2));
}

function preflight() {
  const plan = readPlan(), checks = {};
  checks.planNotDeployed = plan.status === 'not-deployed';
  checks.buildMatchesPin = STEPS.every(s => cast('keccak', `0x${creation(s)}`) === plan.creationCodeKeccak[s.id]);
  checks.chainId = Number(cast('chain-id', '--rpc-url', RPC)) === M.chainId;
  for (const [k, a] of Object.entries({ safe: M.safe, verifier: M.verifier, exitVerifier: M.exitVerifier, poseidonT3: M.libraries.PoseidonT3,
    poseidonT4: M.libraries.PoseidonT4, ethPool: M.ethPool, usdgPool: M.usdgPool, v3Router: M.v3Router, weth: M.weth, v4PoolManager: M.v4PoolManager }))
    checks[`${k}HasCode`] = cast('code', a, '--rpc-url', RPC).length > 2;
  checks.screeningAdminHasCode = cast('code', plan.parameters.screeningAdmin, '--rpc-url', RPC).length > 2;
  checks.basePoolsMatchProfiles = lower(cast('call', M.ethPool, 'ASSET()(address)', '--rpc-url', RPC)) === '0x0000000000000000000000000000000000000000'
    && lower(cast('call', M.usdgPool, 'ASSET()(address)', '--rpc-url', RPC)) === '0x5fc5360d0400a0fd4f2af552add042d716f1d168';
  const balance = BigInt(cast('balance', M.deployer, '--rpc-url', RPC));
  checks.deployerFunded = balance >= M.minBalanceWei;
  checks.notRecordedYet = !existsSync(RECORD);
  const nonce = Number(cast('nonce', M.deployer, '--rpc-url', RPC));
  const failed = Object.entries(checks).filter(([, ok]) => !ok).map(([k]) => k);
  return { plan, checks, failed, balance, nonce };
}

function signer() {
  if (process.env.FORK_UNLOCKED) {
    if (!LOCAL) fail('FORK_UNLOCKED_ON_NON_LOCAL_RPC');
    return ['--unlocked', '--from', M.deployer];
  }
  const passwordFile = arg('--password-file');
  if (!passwordFile || !existsSync(passwordFile)) fail('PASSWORD_FILE_REQUIRED');
  const who = cast('wallet', 'address', '--account', 'lincoln-deployer', '--password-file', passwordFile);
  if (lower(who) !== lower(M.deployer)) fail(`WRONG_SIGNER ${who}`);
  return ['--account', 'lincoln-deployer', '--password-file', passwordFile];
}

function send(auth, args) {
  // Flags first: cast treats everything after `--create <code>` as constructor arguments.
  const raw = JSON.parse(cast('send', ...auth, '--rpc-url', RPC, '--json', ...args));
  if (raw.schema_version !== undefined && !raw.success) fail(`SEND_FAILED ${JSON.stringify(raw.errors)}`);
  const receipt = raw.schema_version !== undefined ? raw.data : raw;
  if (receipt.status !== '0x1' && receipt.status !== 1 && receipt.status !== '1') fail(`REVERTED ${receipt.transactionHash}`);
  return receipt;
}

function deploy() {
  const { plan, failed, nonce } = preflight();
  const resume = readState();
  if (failed.length && !(resume && failed.every(f => f === 'notRecordedYet'))) fail(`PREFLIGHT_FAILED: ${failed.join(', ')}`);
  const auth = signer();
  const state = resume ?? { predicted: predict(nonce), done: {}, setFactory: {}, startNonce: nonce };
  const save = () => writeFileSync(STATE, JSON.stringify(state, null, 1) + '\n');
  save();
  for (const step of STEPS) {
    if (state.done[step.id]) continue;
    const addr = Object.fromEntries(Object.entries(state.done).map(([k, v]) => [k, v.address]));
    const initcode = `0x${creation(step)}${constructorArgs(step.id, plan.parameters, addr)}`;
    const receipt = send(auth, ['--create', initcode]);
    if (lower(receipt.contractAddress) !== lower(state.predicted[step.id])) fail(`ADDRESS_MISMATCH ${step.id} ${receipt.contractAddress} != ${state.predicted[step.id]}`);
    state.done[step.id] = { address: receipt.contractAddress, transactionHash: receipt.transactionHash, blockNumber: String(BigInt(receipt.blockNumber)) };
    save();
    console.log(JSON.stringify({ deployed: step.contract, address: receipt.contractAddress }));
  }
  const factory = state.done.factory.address;
  for (const id of DEPLOYERS) {
    if (state.setFactory[id]) continue;
    const receipt = send(auth, [state.done[id].address, 'setFactory(address)', factory]);
    state.setFactory[id] = receipt.transactionHash;
    save();
  }
  const verification = verify(state);
  const record = { schema: 'lincoln-meme-factory-deployment/v1', chainId: M.chainId, deployer: M.deployer, parameters: plan.parameters,
    startBlock: state.done.factory.blockNumber, contracts: state.done, setFactory: state.setFactory, constants: plan.constants,
    sources: plan.sources, compiler: plan.compiler, verification, recordedAt: new Date().toISOString() };
  if (!LOCAL) writeFileSync(RECORD, JSON.stringify(record, null, 2) + '\n');
  console.log(JSON.stringify({ factory, startBlock: record.startBlock, contracts: Object.fromEntries(Object.entries(state.done).map(([k, v]) => [k, v.address])), verification, record: LOCAL ? '(fork: not recorded)' : RECORD }, null, 2));
  if (!verification.ok) fail('POST_DEPLOY_VERIFICATION_FAILED');
}

function verify(state = readState()) {
  if (!state) fail('NO_STATE');
  const plan = readPlan(), a = Object.fromEntries(Object.entries(state.done).map(([k, v]) => [k, v.address]));
  const call = (to, sig, ...args) => cast('call', to, sig, ...args.map(String), '--rpc-url', RPC).split(' ')[0];
  const eq = (x, y) => lower(String(x)) === lower(String(y));
  const runtime = {};
  for (const step of STEPS) {
    const art = artifact(step.file, step.contract);
    let expected = linkCode(art.deployedBytecode.object, art.deployedBytecode.linkReferences), code = cast('code', a[step.id], '--rpc-url', RPC).slice(2);
    for (const refs of Object.values(art.deployedBytecode.immutableReferences ?? {}))
      for (const { start, length } of refs) {
        expected = expected.slice(0, start * 2) + '00'.repeat(length) + expected.slice((start + length) * 2);
        code = code.slice(0, start * 2) + '00'.repeat(length) + code.slice((start + length) * 2);
      }
    runtime[step.id] = strip(code) === strip(expected);
  }
  const p = plan.parameters, checks = {
    runtimeMatchesBuild: Object.values(runtime).every(Boolean),
    screeningAdmin: eq(call(a.screening, 'ADMIN()(address)'), p.screeningAdmin),
    poolVerifiers: eq(call(a.poolDeployer, 'VERIFIER()(address)'), M.verifier) && eq(call(a.poolDeployer, 'EXIT_VERIFIER()(address)'), M.exitVerifier),
    provider: eq(call(a.providerDeployer, 'GUARDIAN()(address)'), M.safe) && eq(call(a.providerDeployer, 'SCREENING()(address)'), a.screening)
      && BigInt(call(a.providerDeployer, 'SCREENING_DELAY()(uint64)')) === BigInt(p.screeningDelay),
    v3Routes: eq(call(a.v3Routes, 'ROUTER()(address)'), M.v3Router) && eq(call(a.v3Routes, 'WRAPPED_NATIVE()(address)'), M.weth)
      && Number(call(a.v3Routes, 'FEE_BPS()(uint16)')) === M.routeFeeBps && eq(call(a.v3Routes, 'TREASURY()(address)'), M.safe),
    v4Routes: eq(call(a.v4Routes, 'POOL_MANAGER()(address)'), M.v4PoolManager) && Number(call(a.v4Routes, 'FEE_BPS()(uint16)')) === M.routeFeeBps
      && eq(call(a.v4Routes, 'TREASURY()(address)'), M.safe),
    factoryWiring: eq(call(a.factory, 'POOL_DEPLOYER()(address)'), a.poolDeployer) && eq(call(a.factory, 'PROVIDER_DEPLOYER()(address)'), a.providerDeployer)
      && eq(call(a.factory, 'V3_ROUTES()(address)'), a.v3Routes) && eq(call(a.factory, 'V4_ROUTES()(address)'), a.v4Routes),
    basePools: call(a.factory, 'isBasePool(address)(bool)', M.ethPool) === 'true' && call(a.factory, 'isBasePool(address)(bool)', M.usdgPool) === 'true',
    deployersBound: DEPLOYERS.every(id => eq(call(a[id], 'factory()(address)'), a.factory) && eq(call(a[id], 'SETTER()(address)'), M.deployer)),
    noPoolsYet: Number(call(a.factory, 'poolCount()(uint256)')) === 0,
  };
  return { ok: Object.values(checks).every(Boolean), checks, runtime };
}

const mode = process.argv[2];
if (mode === '--pin') pin();
else if (mode === '--plan') {
  const { plan, checks, failed, balance, nonce } = preflight();
  console.log(JSON.stringify({ network: 'Robinhood Chain mainnet (4663)', deployer: M.deployer, deployerBalanceEth: Number(balance) / 1e18,
    parameters: plan.parameters, transactions: 10, predictedAddresses: predict(nonce), checks, ready: failed.length === 0 }, null, 2));
  process.exit(failed.length ? 1 : 0);
} else if (mode === '--deploy') deploy();
else if (mode === '--verify') console.log(JSON.stringify(verify(), null, 2));
else fail('Use --pin --screening-delay <s> --screening-admin <0x…>, --plan, --deploy --password-file <file>, or --verify.');
