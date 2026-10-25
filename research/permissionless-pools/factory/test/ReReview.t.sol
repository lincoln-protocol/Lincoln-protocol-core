// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Base, MockJoinSplitVerifier, MockExitVerifier, MockToken} from 'rc3-test/Base.sol';
import {Phase2ASPPool} from 'rc3/Phase2ASPPool.sol';
import {Phase2ASPRegistry} from 'rc3/Phase2ASPRegistry.sol';
import {Phase2FeeRouteBase} from 'rc3-fees/Phase2FeeRouteAdapter.sol';
import {ScreeningList} from '../src/ScreeningList.sol';
import {AutoApproveProvider} from '../src/AutoApproveProvider.sol';
import {PoolDeployer, ProviderDeployer, V3RouteDeployer, V4RouteDeployer} from '../src/Deployers.sol';
import {Phase2FeeV4Adapter} from '../src/Phase2FeeV4Adapter.sol';
import {LincolnMemeFactory, V4PoolKey} from '../src/LincolnMemeFactory.sol';
import {MockV4PoolManager, V4TaxToken} from './mocks/V4Mocks.sol';

interface VmX {
    function store(address target, bytes32 slot, bytes32 value) external;
    function prank(address) external;
}

contract RRMockV3Factory {
    function getPool(address, address, uint24) external view returns (address) { return address(this); }
}

contract RRMockRouter02 {
    address public immutable factory;
    address public immutable WETH9;
    constructor(address factory_, address weth) { factory = factory_; WETH9 = weth; }
}

/// @dev Re-review PoCs for 6b68094/b4a3bdb.
contract ReReviewTest is Base {
    uint64 internal constant DELAY = 1 hours;
    address internal constant SAFE = address(0x5AFE);
    address internal constant TREASURY = address(0x7EA5);
    address internal constant ALICE = address(0xA11CE);
    address internal constant MALLORY = address(0xBAD);
    address internal constant BOB = address(0xB0B);
    bytes32 internal constant NEXT_LEAF_SLOT = bytes32(uint256(7));
    VmX internal constant vmx = VmX(address(uint160(uint256(keccak256('hevm cheat code')))));

    MockJoinSplitVerifier internal verifier;
    MockExitVerifier internal exitVerifier;
    MockToken internal meme;
    MockToken internal weth;
    MockToken internal usd;
    Phase2ASPRegistry internal liveRegistry;
    Phase2ASPPool internal baseEth;
    Phase2ASPPool internal baseUsd;
    ScreeningList internal screening;
    MockV4PoolManager internal manager;
    LincolnMemeFactory internal factory;
    uint256 internal nonce = 5000;

    receive() external payable {}

    function setUp() public {
        liveRegistry = deployRegistry();
        verifier = new MockJoinSplitVerifier();
        exitVerifier = new MockExitVerifier();
        meme = new MockToken('MEME');
        weth = new MockToken('WETH');
        usd = new MockToken('USD');
        baseEth = new Phase2ASPPool(address(verifier), address(exitVerifier), address(liveRegistry), address(0), 10 ether, 200 ether);
        baseUsd = new Phase2ASPPool(address(verifier), address(exitVerifier), address(liveRegistry), address(usd), 25_000e6, 500_000e6);
        screening = new ScreeningList(SAFE);
        PoolDeployer poolDeployer = new PoolDeployer(address(verifier), address(exitVerifier));
        ProviderDeployer providerDeployer = new ProviderDeployer(SAFE, address(screening), DELAY);
        V3RouteDeployer v3Routes = new V3RouteDeployer(address(new RRMockRouter02(address(new RRMockV3Factory()), address(weth))), address(weth), 30, TREASURY);
        manager = new MockV4PoolManager();
        V4RouteDeployer v4Routes = new V4RouteDeployer(address(manager), 30, TREASURY);
        address[] memory bases = new address[](2);
        bases[0] = address(baseEth);
        bases[1] = address(baseUsd);
        factory = new LincolnMemeFactory(address(poolDeployer), address(providerDeployer), address(v3Routes), address(v4Routes), bases);
        poolDeployer.setFactory(address(factory));
        providerDeployer.setFactory(address(factory));
        v3Routes.setFactory(address(factory));
        v4Routes.setFactory(address(factory));
        publish(liveRegistry, 1, 7 days);
    }

    // ---------------- helpers ----------------

    function open(address token) internal returns (Phase2ASPPool pool, AutoApproveProvider provider) {
        pool = Phase2ASPPool(payable(factory.createPool(token)));
        provider = AutoApproveProvider(factory.providerOf(address(pool)));
    }

    function one(uint256 c) internal pure returns (uint256[] memory list) {
        list = new uint256[](1);
        list[0] = c;
    }

    function deposit(Phase2ASPPool pool, address from, uint128 value) internal returns (uint256 commitment) {
        MockToken t = MockToken(pool.ASSET());
        t.mint(from, value);
        vm.startPrank(from);
        t.approve(address(pool), value);
        commitment = pool.depositDynamic(value, ++nonce, cipher(nonce));
        vm.stopPrank();
    }

    function spend(Phase2ASPPool pool, uint256 out) internal {
        bytes[2] memory pair = outputs(out);
        Phase2ASPPool.ExtData memory data = selfData(0, address(0));
        pool.transact([uint256(0), 0], [[uint256(0), 0], [uint256(0), 0]], [uint256(0), 0],
            signals(pool, pool.hashContext(data, pair), out + 1, out + 2, out, 0, 0), data, pair);
    }

    function exitData(address recipient) internal view returns (Phase2ASPPool.HolderExitData memory) {
        return Phase2ASPPool.HolderExitData({processor: address(this), recipient: recipient, feeRecipient: address(0), fee: 0});
    }

    function exitProof(Phase2ASPPool pool, uint256 commitment, uint256 value, address recipient)
        internal view returns (Phase2ASPPool.HolderExitProof memory p)
    {
        p.pubSignals = [commitment, ++commitment, value, pool.SCOPE(), pool.holderExitContext(exitData(recipient))];
    }

    // ================= F-1: no deposit is approved before the delay =================

    /// Any depositor kind (EOA, V3 adapter, V4 adapter, the base pool itself, the factory), any number of
    /// syncs by anyone at any time before seen+DELAY: never approved. Approved exactly at seen+DELAY.
    function testFuzz_F1_noDepositApprovedBeforeDelay(uint8 kind, uint32 firstSyncLag, uint32 probe) public {
        (Phase2ASPPool pool, AutoApproveProvider provider) = open(address(meme));
        address depositor;
        kind = kind % 5;
        if (kind == 0) depositor = ALICE;
        else if (kind == 1) depositor = factory.createV3Route(address(baseUsd), address(pool), abi.encodePacked(address(usd), uint24(500), address(meme)));
        else if (kind == 2) {
            V4PoolKey memory key = V4PoolKey(address(0), address(meme), 3000, 60, address(0));
            manager.initialize(MockV4PoolManager.PoolKey(key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks), 2 ** 96);
            depositor = factory.createV4Route(address(baseEth), address(pool), key);
        } else if (kind == 3) depositor = address(baseEth);
        else depositor = address(factory);
        uint256 c = deposit(pool, depositor, 1);
        skip(bound(firstSyncLag, 0, 30 days));
        vm.prank(MALLORY);
        provider.sync(one(c));
        uint256 seen = provider.firstSeen(c);
        eq(seen, now_(), 'clock starts at first sync');
        vm.warp(seen + bound(probe, 0, DELAY - 1));
        vm.prank(MALLORY);
        eq(provider.sync(one(c)), 0, 'never before the delay');
        check(!provider.approved(c), 'not approved');
        vm.warp(seen + DELAY);
        eq(provider.sync(one(c)), 1, 'approved at the delay');
    }

    /// The commitment cannot be pre-registered (sync before the deposit reverts), so firstSeen can never
    /// predate the deposit.
    function testF1_cannotPreSeeACommitment() public {
        (Phase2ASPPool pool, AutoApproveProvider provider) = open(address(meme));
        // commitment the attacker will produce: H(1, nonce+1) -- unknown to the pool yet
        vm.expectRevert(AutoApproveProvider.UnknownCommitment.selector);
        provider.sync(one(uint256(keccak256('future'))));
        skip(DELAY);
        uint256 c = deposit(pool, MALLORY, 1);
        provider.sync(one(c));
        eq(provider.firstSeen(c), now_(), 'seen only when it exists');
    }

    /// Generations: a deposit into the old generation at the reopen boundary is still screened by
    /// the old provider; the new generation's provider has no state for it.
    function testF1_oldGenerationStillScreens() public {
        (Phase2ASPPool first, AutoApproveProvider p1) = open(address(meme));
        vmx.store(address(first), NEXT_LEAF_SLOT, bytes32(factory.REOPEN_AT_LEAVES()));
        (, AutoApproveProvider p2) = open(address(meme));
        uint256 c = deposit(first, MALLORY, 1);
        eq(p1.sync(one(c)), 0, 'old gen waits');
        vm.expectRevert(AutoApproveProvider.UnknownCommitment.selector);
        p2.sync(one(c));
        skip(DELAY - 1);
        eq(p1.sync(one(c)), 0, 'still waiting');
    }

    // ================= F-2 =================

    /// Worst case: a proof made against epoch E just before E+1 lands; the attacker then publishes at
    /// exactly the maximum rate. The proof still lands at t1+3599; E+16 cannot exist before t1+3600,
    /// which is also when the registry grace ends.
    function testF2_maxRateChurnOutlastsGrace() public {
        (Phase2ASPPool pool, AutoApproveProvider provider) = open(address(meme));
        Phase2ASPRegistry registry = Phase2ASPRegistry(address(provider.REGISTRY()));
        uint256 interval = provider.MIN_PUBLISH_INTERVAL();
        skip(interval);
        bytes[2] memory pair = outputs(77);
        Phase2ASPPool.ExtData memory data = selfData(0, address(0));
        uint256 context = pool.hashContext(data, pair); // epoch E = 1
        context;
        uint256 t1 = now_();
        uint256 n;
        for (uint256 t = t1; ; t += interval) {
            vm.warp(t);
            spend(pool, 60_000 + t);
            provider.sync(one(60_000 + t));
            n++;
            (, uint64 latest,) = registry.latestPolicy();
            if (latest >= 17) break;
            check(provider.canPublish() == false, 'cannot publish twice in an interval');
        }
        (, uint64 l,) = registry.latestPolicy();
        eq(l, 17, 'E+16');
        eq(now_(), t1 + 15 * interval, 'E+16 at t1 + 15 intervals at the earliest');
        check(15 * interval >= registry.SUPERSEDED_POLICY_GRACE() + 15 minutes, 'E+16 lands 15+ minutes after the grace ends (I-3 margin)');
    }

    function testF2_renewNotRepeatableInsideMargin() public {
        (, AutoApproveProvider provider) = open(address(meme));
        Phase2ASPRegistry registry = Phase2ASPRegistry(address(provider.REGISTRY()));
        skip(provider.POLICY_LIFETIME() - provider.RENEW_MARGIN());
        check(provider.publish(), 'renewed');
        for (uint256 i; i < 30; i++) {
            skip(provider.MIN_PUBLISH_INTERVAL());
            check(!provider.publish(), 'no further renewals: validUntil moved 30 days out');
        }
        (, uint64 epoch,) = registry.latestPolicy();
        eq(epoch, 2, 'exactly one renewal');
    }

    /// LOW: after the Safe suspends and resumes the provider, every epoch stays revoked and the provider
    /// has nothing "pending", so publish() refuses: normal spending stays halted until a new deposit
    /// clears the screening delay (or for ~29 days if deposits are paused).
    /// Fixed L-1: after the Safe suspends and resumes, spending recovers at the next interval (not at the renewal
    /// margin ~29 days later), even with deposits paused so nothing new is pending.
    function testL1_resumeRestoresSpending() public {
        (Phase2ASPPool pool, AutoApproveProvider provider) = open(address(meme));
        Phase2ASPRegistry registry = Phase2ASPRegistry(address(provider.REGISTRY()));
        uint256 c = deposit(pool, ALICE, 10);
        provider.sync(one(c));
        skip(DELAY);
        eq(provider.sync(one(c)), 1, 'approved and published');
        check(provider.usable(c), 'usable');

        vm.prank(SAFE);
        pool.pauseDeposits();
        vm.prank(SAFE);
        registry.suspendProvider();
        skip(1 hours);
        bytes[2] memory pair = outputs(55);
        Phase2ASPPool.ExtData memory data = selfData(0, address(0));
        vm.expectRevert(Phase2ASPPool.UnavailableASPPolicy.selector);
        pool.hashContext(data, pair);
        check(!provider.publish(), 'no publish while suspended');

        vm.prank(SAFE);
        registry.resumeProvider();
        check(provider.publish(), 'the revoked latest epoch is republished at once');
        pool.hashContext(data, pair);
        check(!provider.publish(), 'once, then rate-limited again');
    }

    /// Fixed I-1: a sync during a suspension still records new deposits (their screening clock starts) and
    /// approves spend outputs; it just doesn't publish until the resume.
    function testI1_syncRecordsDepositsWhileSuspended() public {
        (Phase2ASPPool pool, AutoApproveProvider provider) = open(address(meme));
        Phase2ASPRegistry registry = Phase2ASPRegistry(address(provider.REGISTRY()));
        spend(pool, 4242);
        provider.sync(one(4242)); // approved, publish pending (interval)
        vm.prank(SAFE);
        registry.suspendProvider();
        skip(provider.MIN_PUBLISH_INTERVAL());
        uint256 c = deposit(pool, ALICE, 1);
        provider.sync(one(c));
        check(provider.firstSeen(c) != 0, 'clock started during the suspension');
        check(!provider.usable(4242), 'not published while suspended');
        vm.prank(SAFE);
        registry.resumeProvider();
        check(provider.publish(), 'published after the resume');
        check(provider.usable(4242), 'spend output usable');
    }

    // ================= F-3 =================

    /// Old generation, once completely full: change outputs and adapter deposits revert, full withdrawals
    /// and holderExit still work. No same-token route can migrate notes privately to the new generation.
    function testF3_fullOldGenerationExitsOnly() public {
        (Phase2ASPPool first,) = open(address(meme));
        uint256 c = deposit(first, ALICE, 100);
        vmx.store(address(first), NEXT_LEAF_SLOT, bytes32(uint256(1 << 20)));
        (Phase2ASPPool second,) = open(address(meme));
        vm.expectRevert(LincolnMemeFactory.PoolExists.selector);
        factory.createPool(address(meme)); // gen3 blocked while gen2 is open

        bytes[2] memory pair = outputs(88);
        Phase2ASPPool.ExtData memory data = selfData(0, address(0));
        uint256 ctx = first.hashContext(data, pair);
        uint256[9] memory sig = signals(first, ctx, 701, 702, 7101, 0, 0);
        vm.expectRevert(Phase2ASPPool.TreeFull.selector);
        first.transact([uint256(0), 0], [[uint256(0), 0], [uint256(0), 0]], [uint256(0), 0], sig, data, pair);
        // a full withdrawal with no change output still works
        Phase2ASPPool.ExtData memory w = selfData(40, BOB);
        uint256[9] memory sigW = signals(first, first.hashContext(w, pair), 703, 704, 0, 0, 40);
        first.transact([uint256(0), 0], [[uint256(0), 0], [uint256(0), 0]], [uint256(0), 0], sigW, w, pair);
        eq(meme.balanceOf(BOB), 40, 'full withdrawal works');

        first.holderExit(exitData(ALICE), exitProof(first, c, 60, ALICE));
        eq(meme.balanceOf(ALICE), 60, 'holder exit works on a full generation');

        // routes into the old generation can still be created
        factory.createV3Route(address(baseUsd), address(first), abi.encodePacked(address(usd), uint24(500), address(meme)));
        // a same-token route between generations is impossible
        bytes memory same = abi.encodePacked(address(meme), uint24(500), address(meme));
        vm.expectRevert(Phase2FeeRouteBase.InvalidRoute.selector);
        factory.createV3Route(address(first), address(second), same);
        V4PoolKey memory k = V4PoolKey(address(meme), address(meme), 3000, 60, address(0));
        vm.expectRevert(Phase2FeeV4Adapter.InvalidRoute.selector);
        factory.createV4Route(address(first), address(second), k);
        if (false) factory.createV3Route(address(first), address(second), abi.encodePacked(address(meme), uint24(500), address(meme)));
    }

    // ================= token risks (permissionless listing) =================

    /// INFO: a token whose owner turns on a transfer tax after listing freezes every exit (including
    /// holderExit and ragequit) because the pool requires exact transfers.
    function testPoC_tokenOwnerCanFreezePoolByTogglingTax() public {
        V4TaxToken tax = new V4TaxToken();
        Phase2ASPPool pool = Phase2ASPPool(payable(factory.createPool(address(tax))));
        tax.mint(ALICE, 1000);
        vm.startPrank(ALICE);
        tax.approve(address(pool), 1000);
        uint256 c = pool.depositDynamic(1000, ++nonce, cipher(nonce));
        vm.stopPrank();
        tax.setTaxed(address(0), address(pool));
        Phase2ASPPool.HolderExitProof memory p = exitProof(pool, c, 1000, ALICE);
        Phase2ASPPool.HolderExitData memory d = exitData(ALICE);
        vm.expectRevert(Phase2ASPPool.AssetAmountMismatch.selector);
        pool.holderExit(d, p);
    }

    /// INFO (known): ragequit of an adapter-deposited ERC20 note pays the adapter, where it is stuck.
    function testPoC_ragequitOfAdapterNoteStrandsFunds() public {
        (Phase2ASPPool pool,) = open(address(meme));
        address adapter = factory.createV3Route(address(baseUsd), address(pool), abi.encodePacked(address(usd), uint24(500), address(meme)));
        uint256 c = deposit(pool, adapter, 500);
        Phase2ASPPool.HolderExitData memory d = Phase2ASPPool.HolderExitData({processor: address(this), recipient: adapter,
            feeRecipient: address(0), fee: 0});
        Phase2ASPPool.HolderExitProof memory p;
        p.pubSignals = [c, c + 1, 500, pool.SCOPE(), pool.holderExitContext(d)];
        pool.ragequit(d, p);
        eq(meme.balanceOf(adapter), 500, 'stuck in the adapter (no sweep)');
    }
}
