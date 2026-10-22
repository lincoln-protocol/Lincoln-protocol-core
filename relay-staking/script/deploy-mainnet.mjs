// RelayStakeRegistry on Robinhood Chain mainnet: plan, deploy and record.
//   node relay-staking/script/deploy-mainnet.mjs --plan
//   relay-staking/script/deploy-mainnet.sh            (interactive; asks for the keystore password)
//   node relay-staking/script/deploy-mainnet.mjs --verify <address>   (post-deploy checks; RPC_URL overrides the RPC)
// It sends exactly the init code pinned in deploy-mainnet-plan.json (the audited build, constructor
// arguments appended) and nothing else. Every check runs before the password is used.
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const PROJECT = join(HERE, '..');
const RPC = process.env.RPC_URL ?? 'https://rpc.mainnet.chain.robinhood.com/';
const RECORD = join(PROJECT, '..', 'deployments', 'robinhood-mainnet', 'relay-stake-registry.json');
const EXPECT = {
  chainId: 4663,
  stakeToken: '0x2796cdF7328916e0A6c04C296A72C5C6d70B3AEE',
  minStake: 5_000_000n * 10n ** 18n,
  unbondingSeconds: 1_209_600n,
  guardian: '0x9CF17a6E3c75D200f58283A165C442a8A3994555',
  deployer: '0x555998Ba2B2723C97d91FB20Da0ddb896749797e',
  initcodeKeccak: '0x1eff9ad0f5bc312fe6666638be245774e32853ca6aaf21746173d0199e949bf7',
  minBalanceWei: 3_000_000_000_000_000n, // 0.003 ETH
};

const cast = (...args) => execFileSync('cast', args, { encoding: 'utf8' }).trim();
const fail = message => { console.error(JSON.stringify({ error: message })); process.exit(1); };
const lower = s => s.toLowerCase();
const word = (hex, i) => BigInt('0x' + hex.slice(i * 64, i * 64 + 64));
const addressWord = (hex, i) => '0x' + hex.slice(i * 64 + 24, i * 64 + 64);

function preflight() {
  const plan = JSON.parse(readFileSync(join(PROJECT, 'deploy-mainnet-plan.json'), 'utf8'));
  const checks = {};
  checks.planNotDeployed = plan.status === 'not-deployed';
  checks.initcodeKeccak = lower(cast('keccak', plan.initcode)) === EXPECT.initcodeKeccak && plan.initcodeSHA256 === EXPECT.initcodeKeccak;
  const args = plan.constructorArgs.slice(2);
  checks.initcodeEndsWithArgs = plan.initcode.endsWith(args) && args.length === 4 * 64;
  checks.constructorArgs = lower(addressWord(args, 0)) === lower(EXPECT.stakeToken) && word(args, 1) === EXPECT.minStake
    && word(args, 2) === EXPECT.unbondingSeconds && lower(addressWord(args, 3)) === lower(EXPECT.guardian);
  checks.chainId = Number(cast('chain-id', '--rpc-url', RPC)) === EXPECT.chainId;
  checks.stakeTokenHasCode = cast('code', EXPECT.stakeToken, '--rpc-url', RPC).length > 2;
  checks.guardianHasCode = cast('code', EXPECT.guardian, '--rpc-url', RPC).length > 2;
  const balance = BigInt(cast('balance', EXPECT.deployer, '--rpc-url', RPC));
  checks.deployerFunded = balance >= EXPECT.minBalanceWei;
  checks.notRecordedYet = !existsSync(RECORD);
  // Same executable code as this project's Foundry build (metadata hash aside).
  const art = JSON.parse(readFileSync(join(PROJECT, 'out/RelayStakeRegistry.sol/RelayStakeRegistry.json'), 'utf8'));
  const strip = s => s.replace(/a264697066735822[0-9a-f]{68}64736f6c6343[0-9a-f]{6}0033$/, '');
  checks.matchesFoundryBuild = strip(art.bytecode.object.slice(2)) === strip(plan.initcode.slice(2, plan.initcode.length - args.length));
  const failed = Object.entries(checks).filter(([, ok]) => !ok).map(([k]) => k);
  return { plan, checks, failed, balance };
}

function verifyDeployed(address) {
  const read = (sig, ret) => cast('call', address, sig, '--rpc-url', RPC).split(' ')[0];
  const onchain = {
    STAKE_TOKEN: read('STAKE_TOKEN()(address)'), MIN_STAKE: read('MIN_STAKE()(uint128)'),
    UNBONDING_SECONDS: read('UNBONDING_SECONDS()(uint64)'), GUARDIAN: read('GUARDIAN()(address)'),
    relayCount: read('relayCount()(uint256)'),
  };
  const art = JSON.parse(readFileSync(join(PROJECT, 'out/RelayStakeRegistry.sol/RelayStakeRegistry.json'), 'utf8'));
  let expected = art.deployedBytecode.object.slice(2), code = cast('code', address, '--rpc-url', RPC).slice(2);
  // Blank immutable slots and the metadata tail on both sides before comparing.
  for (const refs of Object.values(art.deployedBytecode.immutableReferences))
    for (const { start, length } of refs) {
      expected = expected.slice(0, start * 2) + '00'.repeat(length) + expected.slice((start + length) * 2);
      code = code.slice(0, start * 2) + '00'.repeat(length) + code.slice((start + length) * 2);
    }
  const strip = s => s.replace(/a264697066735822[0-9a-f]{68}64736f6c6343[0-9a-f]{6}0033$/, '');
  return {
    onchain,
    runtimeMatchesBuild: strip(code) === strip(expected),
    parametersMatch: lower(onchain.STAKE_TOKEN) === lower(EXPECT.stakeToken) && BigInt(onchain.MIN_STAKE) === EXPECT.minStake
      && BigInt(onchain.UNBONDING_SECONDS) === EXPECT.unbondingSeconds && lower(onchain.GUARDIAN) === lower(EXPECT.guardian),
  };
}

const mode = process.argv[2];
if (mode === '--plan') {
  const { checks, failed, balance } = preflight();
  console.log(JSON.stringify({ contract: 'RelayStakeRegistry', network: 'Robinhood Chain mainnet (4663)', deployer: EXPECT.deployer,
    deployerBalanceEth: Number(balance) / 1e18, constructor: { stakeToken: EXPECT.stakeToken, minStakeTokens: '5000000',
      unbondingDays: 14, guardian: EXPECT.guardian }, checks, ready: failed.length === 0 }, null, 2));
  process.exit(failed.length ? 1 : 0);
} else if (mode === '--deploy') {
  const passwordFile = process.argv[process.argv.indexOf('--password-file') + 1];
  if (!passwordFile || !existsSync(passwordFile)) fail('PASSWORD_FILE_REQUIRED');
  const { plan, failed } = preflight();
  if (failed.length) fail(`PREFLIGHT_FAILED: ${failed.join(', ')}`);
  const signer = cast('wallet', 'address', '--account', 'lincoln-deployer', '--password-file', passwordFile);
  if (lower(signer) !== lower(EXPECT.deployer)) fail(`WRONG_SIGNER ${signer}`);
  // Flags first: cast treats everything after `--create <code>` as constructor arguments.
  const raw = JSON.parse(cast('send', '--account', 'lincoln-deployer', '--password-file', passwordFile,
    '--rpc-url', RPC, '--json', '--create', plan.initcode));
  // cast 1.8 wraps --json output as {schema_version, success, data, errors}.
  if (raw.schema_version !== undefined && !raw.success) fail(`SEND_FAILED ${JSON.stringify(raw.errors)}`);
  const receipt = raw.schema_version !== undefined ? raw.data : raw;
  if (receipt.status !== '0x1' && receipt.status !== 1 && receipt.status !== '1') fail(`DEPLOY_REVERTED ${receipt.transactionHash}`);
  const address = receipt.contractAddress;
  const verified = verifyDeployed(address);
  const record = {
    schema: 'lincoln-relay-stake-registry-deployment/v1', chainId: EXPECT.chainId, contract: 'RelayStakeRegistry',
    address, startBlock: String(BigInt(receipt.blockNumber)), transactionHash: receipt.transactionHash, deployer: EXPECT.deployer,
    gasUsed: String(BigInt(receipt.gasUsed)), constructor: plan.constructor, initcodeKeccak256: EXPECT.initcodeKeccak,
    source: { repository: 'LincolnProtocol backend', path: plan.source, sha256: 'f99b8d7c5cb840250399b9e983e40b06433e7066611c9129fbe9c072e5de3ccc' },
    compiler: { solc: '0.8.28', viaIR: true, optimizerRuns: 10000, evmVersion: 'cancun' }, audit: plan.audit, verification: verified,
    recordedAt: new Date().toISOString(),
  };
  writeFileSync(RECORD, JSON.stringify(record, null, 2) + '\n');
  console.log(JSON.stringify({ address, startBlock: record.startBlock, transactionHash: record.transactionHash, verification: verified, record: RECORD }, null, 2));
  if (!verified.runtimeMatchesBuild || !verified.parametersMatch) fail('POST_DEPLOY_VERIFICATION_FAILED');
} else if (mode === '--verify') {
  // Re-run the post-deploy checks against an address (also used on a fork before the real deploy).
  console.log(JSON.stringify(verifyDeployed(process.argv[3]), null, 2));
} else {
  fail('Use --plan or --deploy --password-file <file>.');
}
