// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Base, MockJoinSplitVerifier, MockExitVerifier, MockToken} from 'rc3-test/Base.sol';
import {Phase2ASPPool} from 'rc3/Phase2ASPPool.sol';
import {Phase2ASPRegistry} from 'rc3/Phase2ASPRegistry.sol';
import {IPhase2RouteSourcePool} from 'rc3/Phase2RouteAdapter.sol';
import {ScreeningList} from '../src/ScreeningList.sol';
import {AutoApproveProvider} from '../src/AutoApproveProvider.sol';
import {PoolDeployer, ProviderDeployer, V3RouteDeployer, V4RouteDeployer} from '../src/Deployers.sol';
import {Phase2FeeV4Adapter} from '../src/Phase2FeeV4Adapter.sol';
import {LincolnMemeFactory, V4PoolKey} from '../src/LincolnMemeFactory.sol';
import {MockV4PoolManager} from './mocks/V4Mocks.sol';

interface VmStore {
    function store(address target, bytes32 slot, bytes32 value) external;
}

contract FixMockV3Factory {
    function getPool(address, address, uint24) external view returns (address) { return address(this); }
}

contract FixMockRouter02 {
    address public immutable factory;
    address public immutable WETH9;
    constructor(address factory_, address weth) { factory = factory_; WETH9 = weth; }
}

/// @dev Regressions for the 2026-10-21 audit of c76f4c2 (privacy-f2's independent review). Each test
/// starts from the auditor's proof of concept and asserts the fixed behaviour.
contract AuditFixesTest is Base {
    uint64 internal constant DELAY = 1 hours;
    address internal constant SAFE = address(0x5AFE);
    address internal constant TREASURY = address(0x7EA5);
    address internal constant MALLORY = address(0xBAD);
    address internal constant HOOK = address(0x4B00C);
    /// @dev Phase2ASPPool storage slot of nextLeafIndex (forge inspect storageLayout).
    bytes32 internal constant NEXT_LEAF_SLOT = bytes32(uint256(7));

    MockJoinSplitVerifier internal verifier;
    MockExitVerifier internal exitVerifier;
    MockToken internal meme;
    MockToken internal weth;
    Phase2ASPRegistry internal liveRegistry;
    Phase2ASPPool internal baseEth;
    ScreeningList internal screening;
    MockV4PoolManager internal manager;
    LincolnMemeFactory internal factory;
    uint256 internal nonce = 1000;

    receive() external payable {}

    function setUp() public {
        liveRegistry = deployRegistry();
        verifier = new MockJoinSplitVerifier();
        exitVerifier = new MockExitVerifier();
        meme = new MockToken('MEME');
        weth = new MockToken('WETH');
        baseEth = new Phase2ASPPool(address(verifier), address(exitVerifier), address(liveRegistry), address(0), 10 ether, 200 ether);
        screening = new ScreeningList(SAFE);
        PoolDeployer poolDeployer = new PoolDeployer(address(verifier), address(exitVerifier));
        ProviderDeployer providerDeployer = new ProviderDeployer(SAFE, address(screening), DELAY);
        V3RouteDeployer v3Routes = new V3RouteDeployer(address(new FixMockRouter02(address(new FixMockV3Factory()), address(weth))), address(weth), 30, TREASURY);
        manager = new MockV4PoolManager();
        V4RouteDeployer v4Routes = new V4RouteDeployer(address(manager), 30, TREASURY);
        address[] memory bases = new address[](1);
        bases[0] = address(baseEth);
        factory = new LincolnMemeFactory(address(poolDeployer), address(providerDeployer), address(v3Routes), address(v4Routes), bases);
        poolDeployer.setFactory(address(factory));
        providerDeployer.setFactory(address(factory));
        v3Routes.setFactory(address(factory));
        v4Routes.setFactory(address(factory));
        publish(liveRegistry, 1, 7 days);
    }

    function open() internal returns (Phase2ASPPool pool, AutoApproveProvider provider) {
        pool = Phase2ASPPool(payable(factory.createPool(address(meme))));
        provider = AutoApproveProvider(factory.providerOf(address(pool)));
    }

    function one(uint256 c) internal pure returns (uint256[] memory list) {
        list = new uint256[](1);
        list[0] = c;
    }

    /// @dev A spend in `pool` whose single output `out` becomes an instantly approvable leaf.
    function spend(Phase2ASPPool pool, uint256 out) internal {
        bytes[2] memory pair = outputs(out);
        Phase2ASPPool.ExtData memory data = selfData(0, address(0));
        pool.transact([uint256(0), 0], [[uint256(0), 0], [uint256(0), 0]], [uint256(0), 0],
            signals(pool, pool.hashContext(data, pair), out + 1, out + 2, out, 0, 0), data, pair);
    }

    // ---------- F-1: denied funds through an attacker-controlled venue ----------

    function testF1_attackerVenueOutputWaitsAndCanBeExcluded() public {
        (Phase2ASPPool memePool, AutoApproveProvider provider) = open();
        address[] memory who = new address[](1);
        who[0] = MALLORY;
        vm.prank(SAFE);
        screening.setDenied(who, true);

        // Mallory's own V4 venue, loaded with her tokens and priced so 1000 wei buys all of it.
        meme.mint(MALLORY, 1e27);
        V4PoolKey memory key = V4PoolKey(address(0), address(meme), 0, 1, HOOK);
        manager.initialize(MockV4PoolManager.PoolKey(key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks), 2 ** 96);
        vm.prank(MALLORY);
        meme.transfer(address(manager), 1e27);
        manager.configure(0, 999e39);
        Phase2FeeV4Adapter buy = Phase2FeeV4Adapter(payable(factory.createV4Route(address(baseEth), address(memePool), key)));

        uint128 amountIn = 1000;
        baseEth.depositDynamic{value: amountIn}(amountIn, ++nonce, cipher(nonce));
        Phase2FeeV4Adapter.Action memory action = Phase2FeeV4Adapter.Action({processor: address(this), amountIn: amountIn,
            minAmountOut: 1, deadline: now_() + 1 hours, targetPrecommitment: ++nonce, encryptedTemplate: cipher(nonce),
            maxServiceFee: type(uint128).max});
        bytes[2] memory out;
        out[0] = cipher(++nonce);
        out[1] = buy.actionEnvelope(action);
        IPhase2RouteSourcePool.ExtData memory data = IPhase2RouteSourcePool.ExtData({recipient: address(buy),
            feeRecipient: address(0), processor: address(buy), publicIn: 0, publicOut: amountIn, fee: 0});
        Phase2ASPPool.ExtData memory poolData = Phase2ASPPool.ExtData({recipient: address(buy), feeRecipient: address(0),
            processor: address(buy), publicIn: 0, publicOut: amountIn, fee: 0});
        Phase2FeeV4Adapter.Proof memory proof;
        proof.pubSignals = [baseEth.currentRoot(), 0, uint256(amountIn), baseEth.hashContext(poolData, out), baseEth.SCOPE(),
            ++nonce, ++nonce, 0, 0];
        (uint256 net, uint256 commitment) = buy.swap(action, proof, data, out);
        check(net > 9e26, 'the venue paid out the denied funds');

        // Fixed: not approved in the same transaction; the Safe has the screening window.
        eq(provider.sync(one(commitment)), 0, 'waits');
        vm.prank(SAFE);
        screening.setExcluded(one(commitment), true);
        skip(DELAY);
        eq(provider.sync(one(commitment)), 0, 'excluded');
        check(!provider.approved(commitment), 'never approved');
    }

    // ---------- F-2: epoch churn against in-flight proofs ----------

    function testF2_publishCannotBeRepeated() public {
        (, AutoApproveProvider provider) = open();
        (, uint64 before,) = Phase2ASPRegistry(address(provider.REGISTRY())).latestPolicy();
        for (uint256 i; i < 16; i++) provider.publish();
        skip(provider.MIN_PUBLISH_INTERVAL());
        for (uint256 i; i < 16; i++) provider.publish();
        (, uint64 latest,) = Phase2ASPRegistry(address(provider.REGISTRY())).latestPolicy();
        eq(latest, before, 'nothing pending and not near expiry: no new epoch');
    }

    /// An attacker who publishes as fast as the provider allows, with a fresh leaf every time, still
    /// cannot invalidate a proof within the hour after it was made.
    function testF2_inFlightProofSurvivesMaxRateChurn() public {
        (Phase2ASPPool pool, AutoApproveProvider provider) = open();
        bytes[2] memory pair = outputs(31);
        Phase2ASPPool.ExtData memory data = selfData(0, address(0));
        uint256 context = pool.hashContext(data, pair);
        uint256[9] memory victim = signals(pool, context, 101, 102, 7001, 7002, 0);

        uint256 interval = provider.MIN_PUBLISH_INTERVAL();
        uint256 published;
        for (uint256 t = interval; t < 59 minutes; t += interval) {
            vm.warp(START + t);
            spend(pool, 50_000 + t);
            vm.prank(MALLORY);
            provider.sync(one(50_000 + t));
            published++;
        }
        check(published >= 14, 'attacker published at the maximum rate');
        vm.warp(START + 59 minutes);
        pool.transact([uint256(0), 0], [[uint256(0), 0], [uint256(0), 0]], [uint256(0), 0], victim, data, pair);
    }

    function testF2_policyRenewsOnlyNearExpiry() public {
        (, AutoApproveProvider provider) = open();
        skip(provider.POLICY_LIFETIME() - provider.RENEW_MARGIN() - 1);
        check(!provider.publish(), 'too early to renew');
        skip(1);
        check(provider.publish(), 'renewed near expiry');
        check(!provider.publish(), 'once per interval');
    }

    // ---------- F-3: a token's pool reopens when its tree is nearly full ----------

    function testF3_tokenReopensWhenTreeNearlyFull() public {
        (Phase2ASPPool first,) = open();
        vm.expectRevert(LincolnMemeFactory.PoolExists.selector);
        factory.createPool(address(meme));
        VmStore(address(vm)).store(address(first), NEXT_LEAF_SLOT, bytes32(factory.REOPEN_AT_LEAVES()));
        address second = factory.createPool(address(meme));
        check(second != address(first) && factory.poolOf(address(meme)) == second, 'new generation is current');
        address[] memory generations = factory.generationsOf(address(meme));
        eq(generations.length, 2, 'both generations listed');
        check(factory.isFactoryPool(address(first)), 'the old generation stays a factory pool');
    }

    // ---------- Info: a zero screening delay is rejected ----------

    function testScreeningDelayHasAFloor() public {
        vm.expectRevert(AutoApproveProvider.InvalidScreening.selector);
        new AutoApproveProvider(SAFE, address(screening), 0, address(this));
        new AutoApproveProvider(SAFE, address(screening), 10 minutes, address(this));
    }
}
