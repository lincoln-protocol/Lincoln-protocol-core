# RelayStakeRegistry

**Deployed on Robinhood Chain mainnet (4663):** [`0x1429f7BAA41baee9d6C7989DBdDc4C6344c8204B`](https://robinhoodchain.blockscout.com/address/0x1429f7BAA41baee9d6C7989DBdDc4C6344c8204B), block 94808942, tx [`0x032c95c5…8923`](https://robinhoodchain.blockscout.com/tx/0x032c95c5c46a5e7f75407c7676ba31ef707956236b2de6618cb7f0ddaa0c8923), by `lincoln-deployer` on 2026-10-22. Record: [`deployments/robinhood-mainnet/relay-stake-registry.json`](../deployments/robinhood-mainnet/relay-stake-registry.json). Post-deploy checks: the four constructor values read back on chain, and the runtime code matches this build (immutable slots and metadata blanked).

Permissionless registry of relay operators backed by a LINCOLN stake: 5,000,000 LINCOLN minimum, 14-day unbonding, no slashing. The guardian Safe can only suspend a relay (it leaves the active set and can still unbond and withdraw everything). Clients and the points program read it to find relays; it never touches pool funds.

| | |
| --- | --- |
| Source | [`src/RelayStakeRegistry.sol`](src/RelayStakeRegistry.sol), copied verbatim from the backend repo (`protocol/phase2-relay-staking/contracts/RelayStakeRegistry.sol`, sha256 `f99b8d7c5cb840250399b9e983e40b06433e7066611c9129fbe9c072e5de3ccc`) |
| Review | One internal review on 2026-10-20: no critical, high or medium findings, three low ones fixed in this source. No third-party audit yet |
| Build | solc 0.8.28, viaIR, optimizer 10,000 runs, cancun |
| Constructor | stake token LINCOLN `0x2796cdF7328916e0A6c04C296A72C5C6d70B3AEE`, minimum `5000000e18`, unbonding `1209600` s, guardian Safe `0x9CF17a6E3c75D200f58283A165C442a8A3994555` |
| Deployed init code | Exactly the audited build pinned in [`deploy-mainnet-plan.json`](deploy-mainnet-plan.json) (its `initcodeSHA256` field is in fact keccak256: `0x1eff9ad0…49bf7`) |

## Tests

```sh
cd relay-staking && forge test    # 11 passed, including a 512-run accounting fuzz
```

Constructor checks, registration and endpoint rules, add-stake, the unbond rules (no dust listings, one pending unbond), withdrawal timing, full exit with swap-and-pop reordering, restaking during a full unbond, sticky suspension that never traps stake, pre-emptive suspension, and a fuzz that the registry's LINCOLN balance always equals stakes plus pending unbonds. LINCOLN transfers were checked on a mainnet fork to be exact (no transfer fee or burn), which the accounting relies on.

## Deploy

```sh
node relay-staking/script/deploy-mainnet.mjs --plan      # read-only checks
relay-staking/script/deploy-mainnet.sh                   # in your own terminal: asks for DEPLOY, then the keystore password
```

Before the password is used the script checks: plan not yet deployed; init code keccak; the four constructor values decoded from the init code; chain 4663; LINCOLN and the Safe have code; the deployer `0x5559…797e` holds at least 0.003 ETH; the init code matches this project's Foundry build apart from the metadata hash. It then sends the pinned init code from `lincoln-deployer`, reads the four parameters back, compares the runtime code with the build (immutable slots and metadata blanked) and writes `deployments/robinhood-mainnet/relay-stake-registry.json` (address, start block, tx hash).

Rehearsed on a mainnet fork on 2026-10-22: deployed with 1.89M gas; all post-deploy checks passed. `node relay-staking/script/deploy-mainnet.mjs --verify <address>` re-runs them (`RPC_URL` overrides the RPC).

After deploying, the backend sets `relayRegistry {address, startBlock}` in its points season config; the app reads the registry directly.
