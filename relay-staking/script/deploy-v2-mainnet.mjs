// RelayStakeRegistryV2 on Robinhood Chain mainnet: pin, plan, deploy and record.
//   node relay-staking/script/deploy-v2-mainnet.mjs --pin       (after review: writes deploy-v2-plan.json from this build)
//   node relay-staking/script/deploy-v2-mainnet.mjs --plan      (read-only checks)
//   relay-staking/script/deploy-v2-mainnet.sh                   (interactive; asks for the keystore password)
//   node relay-staking/script/deploy-v2-mainnet.mjs --verify <address>   (post-deploy checks; RPC_URL overrides the RPC)
// The deploy sends exactly the init code pinned in deploy-v2-plan.json and refuses if this build no longer matches it.
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const PROJECT = join(HERE, '..');
const RPC = process.env.RPC_URL ?? 'https://rpc.mainnet.chain.robinhood.com/';
const PLAN = join(PROJECT, 'deploy-v2-plan.json');
const ARTIFACT = join(PROJECT, 'out/RelayStakeRegistryV2.sol/RelayStakeRegistryV2.json');
const RECORD = join(PROJECT, '..', 'deployments', 'robinhood-mainnet', 'relay-stake-registry-v2.json');
const EXPECT = {
  chainId: 4663,
  stakeToken: '0x2796cdF7328916e0A6c04C296A72C5C6d70B3AEE',
  minStake: 5_000_000n * 10n ** 18n,
  unbondingSeconds: 1_209_600n,
  guardian: '0x9CF17a6E3c75D200f58283A165C442a8A3994555',
  deployer: '0x555998Ba2B2723C97d91FB20Da0ddb896749797e',
  minBalanceWei: 3_000_000_000_000_000n,
};

const cast = (...args) => execFileSync('cast', args, { encoding: 'utf8' }).trim();
const fail = message => { console.error(JSON.stringify({ error: message })); process.exit(1); };
const lower = s => s.toLowerCase();
const strip = s => s.replace(/a264697066735822[0-9a-f]{68}64736f6c6343[0-9a-f]{6}0033$/, '');
const artifact = () => JSON.parse(readFileSync(ARTIFACT, 'utf8'));
const constructorArgs = () => cast('abi-encode', 'constructor(address,uint128,uint64,address)', EXPECT.stakeToken, String(EXPECT.minStake), String(EXPECT.unbondingSeconds), EXPECT.guardian);
const buildInitcode = () => artifact().bytecode.object + constructorArgs().slice(2);

function pin() {
  const initcode = buildInitcode();
  const plan = {
    schema: 'lincoln-relay-staking-v2-deploy-plan/v1', chainId: EXPECT.chainId, contract: 'RelayStakeRegistryV2',
    source: 'relay-staking/src/RelayStakeRegistryV2.sol',
    sourceSHA256: execFileSync('shasum', ['-a', '256', join(PROJECT, 'src/RelayStakeRegistryV2.sol')], { encoding: 'utf8' }).split(' ')[0],
    compiler: { solc: '0.8.28', viaIR: true, optimizerRuns: 10000, evmVersion: 'cancun' },
    constructor: { stakeToken: EXPECT.stakeToken, minStake: String(EXPECT.minStake), unbondingSeconds: Number(EXPECT.unbondingSeconds), guardian: EXPECT.guardian },
    constructorArgs: constructorArgs(), initcodeKeccak256: cast('keccak', initcode), initcode, deployer: EXPECT.deployer, status: 'not-deployed',
  };
  writeFileSync(PLAN, JSON.stringify(plan, null, 1) + '\n');
  console.log(JSON.stringify({ pinned: PLAN, initcodeKeccak256: plan.initcodeKeccak256, sourceSHA256: plan.sourceSHA256 }, null, 2));
}

function preflight() {
  if (!existsSync(PLAN)) fail('NO_PLAN: run --pin after the review');
  const plan = JSON.parse(readFileSync(PLAN, 'utf8')), checks = {};
  checks.planNotDeployed = plan.status === 'not-deployed';
  checks.initcodeKeccak = lower(cast('keccak', plan.initcode)) === lower(plan.initcodeKeccak256);
  checks.buildMatchesPin = strip(buildInitcode().slice(2, -plan.constructorArgs.slice(2).length)) === strip(plan.initcode.slice(2, -plan.constructorArgs.slice(2).length))
    && plan.initcode.endsWith(constructorArgs().slice(2));
  checks.chainId = Number(cast('chain-id', '--rpc-url', RPC)) === EXPECT.chainId;
  checks.stakeTokenHasCode = cast('code', EXPECT.stakeToken, '--rpc-url', RPC).length > 2;
  checks.guardianHasCode = cast('code', EXPECT.guardian, '--rpc-url', RPC).length > 2;
  const balance = BigInt(cast('balance', EXPECT.deployer, '--rpc-url', RPC));
  checks.deployerFunded = balance >= EXPECT.minBalanceWei;
  checks.notRecordedYet = !existsSync(RECORD);
  const failed = Object.entries(checks).filter(([, ok]) => !ok).map(([k]) => k);
  return { plan, checks, failed, balance };
}

function verifyDeployed(address) {
  const read = sig => cast('call', address, sig, '--rpc-url', RPC).split(' ')[0];
  const onchain = { STAKE_TOKEN: read('STAKE_TOKEN()(address)'), MIN_STAKE: read('MIN_STAKE()(uint128)'),
    UNBONDING_SECONDS: read('UNBONDING_SECONDS()(uint64)'), GUARDIAN: read('GUARDIAN()(address)'), relayCount: read('relayCount()(uint256)') };
  const art = artifact();
  let expected = art.deployedBytecode.object.slice(2), code = cast('code', address, '--rpc-url', RPC).slice(2);
  for (const refs of Object.values(art.deployedBytecode.immutableReferences))
    for (const { start, length } of refs) {
      expected = expected.slice(0, start * 2) + '00'.repeat(length) + expected.slice((start + length) * 2);
      code = code.slice(0, start * 2) + '00'.repeat(length) + code.slice((start + length) * 2);
    }
  return {
    onchain, runtimeMatchesBuild: strip(code) === strip(expected),
    parametersMatch: lower(onchain.STAKE_TOKEN) === lower(EXPECT.stakeToken) && BigInt(onchain.MIN_STAKE) === EXPECT.minStake
      && BigInt(onchain.UNBONDING_SECONDS) === EXPECT.unbondingSeconds && lower(onchain.GUARDIAN) === lower(EXPECT.guardian),
  };
}

const mode = process.argv[2];
if (mode === '--pin') pin();
else if (mode === '--plan') {
  const { checks, failed, balance, plan } = preflight();
  console.log(JSON.stringify({ contract: 'RelayStakeRegistryV2', network: 'Robinhood Chain mainnet (4663)', deployer: EXPECT.deployer,
    deployerBalanceEth: Number(balance) / 1e18, initcodeKeccak256: plan.initcodeKeccak256, constructor: plan.constructor, checks, ready: failed.length === 0 }, null, 2));
  process.exit(failed.length ? 1 : 0);
} else if (mode === '--deploy') {
  const passwordFile = process.argv[process.argv.indexOf('--password-file') + 1];
  if (!passwordFile || !existsSync(passwordFile)) fail('PASSWORD_FILE_REQUIRED');
  const { plan, failed } = preflight();
  if (failed.length) fail(`PREFLIGHT_FAILED: ${failed.join(', ')}`);
  const signer = cast('wallet', 'address', '--account', 'lincoln-deployer', '--password-file', passwordFile);
  if (lower(signer) !== lower(EXPECT.deployer)) fail(`WRONG_SIGNER ${signer}`);
  // Flags first: cast treats everything after `--create <code>` as constructor arguments.
  const raw = JSON.parse(cast('send', '--account', 'lincoln-deployer', '--password-file', passwordFile, '--rpc-url', RPC, '--json', '--create', plan.initcode));
  // cast 1.8 wraps errors as {schema_version, success, errors}; a success is the plain receipt.
  if (raw.schema_version !== undefined && !raw.success) fail(`SEND_FAILED ${JSON.stringify(raw.errors)}`);
  const receipt = raw.schema_version !== undefined ? raw.data : raw;
  if (receipt.status !== '0x1' && receipt.status !== 1 && receipt.status !== '1') fail(`DEPLOY_REVERTED ${receipt.transactionHash}`);
  const address = receipt.contractAddress, verified = verifyDeployed(address);
  const record = { schema: 'lincoln-relay-stake-registry-deployment/v1', chainId: EXPECT.chainId, contract: 'RelayStakeRegistryV2', address,
    startBlock: String(BigInt(receipt.blockNumber)), transactionHash: receipt.transactionHash, deployer: EXPECT.deployer, gasUsed: String(BigInt(receipt.gasUsed)),
    constructor: plan.constructor, initcodeKeccak256: plan.initcodeKeccak256, source: { path: plan.source, sha256: plan.sourceSHA256 }, compiler: plan.compiler,
    supersedes: { contract: 'RelayStakeRegistry', address: '0x1429f7BAA41baee9d6C7989DBdDc4C6344c8204B', reason: 'V1 made the relay signing key the staker' },
    verification: verified, recordedAt: new Date().toISOString() };
  writeFileSync(RECORD, JSON.stringify(record, null, 2) + '\n');
  console.log(JSON.stringify({ address, startBlock: record.startBlock, transactionHash: record.transactionHash, verification: verified, record: RECORD }, null, 2));
  if (!verified.runtimeMatchesBuild || !verified.parametersMatch) fail('POST_DEPLOY_VERIFICATION_FAILED');
} else if (mode === '--verify') {
  console.log(JSON.stringify(verifyDeployed(process.argv[3]), null, 2));
} else fail('Use --pin, --plan, --deploy --password-file <file> or --verify <address>.');
