// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Base, MockJoinSplitVerifier, MockExitVerifier, MockToken} from 'rc3-test/Base.sol';
import {Phase2ASPPool} from 'rc3/Phase2ASPPool.sol';
import {Phase2ASPRegistry} from 'rc3/Phase2ASPRegistry.sol';
import {Phase2FeeRouteBase} from 'rc3-fees/Phase2FeeRouteAdapter.sol';
import {ScreeningList} from '../src/ScreeningList.sol';
import {AutoApproveProvider} from '../src/AutoApproveProvider.sol';
import {FactoryOnly, PoolDeployer, ProviderDeployer, V3RouteDeployer} from '../src/Deployers.sol';
import {LincolnMemeFactory, V4PoolKey} from '../src/LincolnMemeFactory.sol';

/// @dev Every V3 pair exists at fee 500 unless switched off; returns its own address as the pool.
contract MockV3Factory {
    bool public missing;
    function setMissing(bool next) external { missing = next; }
    function getPool(address, address, uint24) external view returns (address) { return missing ? address(0) : address(this); }
}

contract MockRouter02 {
    address public immutable factory;
    address public immutable WETH9;
    constructor(address factory_, address weth) { factory = factory_; WETH9 = weth; }
}

contract MockV4Adapter {}

contract MockV4RouteDeployer is FactoryOnly {
    function deploy(address, address, V4PoolKey calldata) external onlyFactory returns (address) {
        return address(new MockV4Adapter());
    }
}

/// @dev Has code but no ERC20 surface.
contract NotAToken {}

contract FactoryTest is Base {
    uint64 internal constant DELAY = 1 hours;
    address internal constant SAFE = address(0x5AFE);
    address internal constant TREASURY = address(0x7EA5);
    address internal constant ALICE = address(0xA11CE);
    address internal constant MALLORY = address(0xBAD);

    MockJoinSplitVerifier internal verifier;
    MockExitVerifier internal exitVerifier;
    MockToken internal usd;
    MockToken internal meme;
    MockToken internal weth;
    MockV3Factory internal v3Factory;
    Phase2ASPPool internal baseEth;
    Phase2ASPPool internal baseUsd;
    ScreeningList internal screening;
    PoolDeployer internal poolDeployer;
    ProviderDeployer internal providerDeployer;
    V3RouteDeployer internal v3Routes;
    MockV4RouteDeployer internal v4Routes;
    LincolnMemeFactory internal factory;

    function setUp() public {
        Phase2ASPRegistry liveRegistry = deployRegistry();
        verifier = new MockJoinSplitVerifier();
        exitVerifier = new MockExitVerifier();
        usd = new MockToken('USD');
        meme = new MockToken('MEME');
        weth = new MockToken('WETH');
        v3Factory = new MockV3Factory();
        baseEth = new Phase2ASPPool(address(verifier), address(exitVerifier), address(liveRegistry), address(0), 10 ether, 200 ether);
        baseUsd = new Phase2ASPPool(address(verifier), address(exitVerifier), address(liveRegistry), address(usd), 25_000e6, 500_000e6);

        screening = new ScreeningList(SAFE);
        poolDeployer = new PoolDeployer(address(verifier), address(exitVerifier));
        providerDeployer = new ProviderDeployer(SAFE, address(screening), DELAY);
        v3Routes = new V3RouteDeployer(address(new MockRouter02(address(v3Factory), address(weth))), address(weth), 30, TREASURY);
        v4Routes = new MockV4RouteDeployer();
        address[] memory bases = new address[](2);
        bases[0] = address(baseEth);
        bases[1] = address(baseUsd);
        factory = new LincolnMemeFactory(address(poolDeployer), address(providerDeployer), address(v3Routes), address(v4Routes), bases);
        poolDeployer.setFactory(address(factory));
        providerDeployer.setFactory(address(factory));
        v3Routes.setFactory(address(factory));
        v4Routes.setFactory(address(factory));
    }

    // ---------- helpers ----------

    function open() internal returns (Phase2ASPPool pool, AutoApproveProvider provider) {
        vm.prank(ALICE);
        pool = Phase2ASPPool(payable(factory.createPool(address(meme))));
        provider = AutoApproveProvider(factory.providerOf(address(pool)));
    }

    function deposit(Phase2ASPPool pool, address from, uint128 value, uint256 seed) internal returns (uint256 commitment) {
        meme.mint(from, value);
        vm.startPrank(from);
        meme.approve(address(pool), value);
        commitment = pool.depositDynamic(value, seed, cipher(seed));
        vm.stopPrank();
    }

    function one(uint256 c) internal pure returns (uint256[] memory list) {
        list = new uint256[](1);
        list[0] = c;
    }

    function usdToMeme() internal view returns (bytes memory) {
        return abi.encodePacked(address(usd), uint24(500), address(meme));
    }

    // ---------- pools ----------

    function testCreatePoolIsUncappedBoundAndRecorded() public {
        (Phase2ASPPool pool, AutoApproveProvider provider) = open();
        Phase2ASPRegistry registry = Phase2ASPRegistry(address(provider.REGISTRY()));
        check(pool.ASSET() == address(meme), 'asset');
        eq(pool.maxDeposit(), type(uint128).max, 'no per-deposit cap');
        eq(pool.maxTotal(), type(uint128).max, 'no total cap');
        check(address(pool.ASP_REGISTRY()) == address(registry), 'pool uses the provider registry');
        check(registry.PROVIDER() == address(provider), 'provider is the registry provider');
        check(registry.GUARDIAN() == SAFE, 'Safe guards the registry');
        check(address(provider.pool()) == address(pool), 'bound');
        eq(provider.scope(), pool.SCOPE(), 'scope');
        (, uint64 epoch,) = registry.latestPolicy();
        eq(epoch, 1, 'bind publishes a policy');
        check(factory.poolOf(address(meme)) == address(pool) && factory.isFactoryPool(address(pool)), 'recorded');
        eq(factory.poolCount(), 1, 'listed');
    }

    function testCreatePoolRejects() public {
        open();
        vm.expectRevert(LincolnMemeFactory.PoolExists.selector);
        factory.createPool(address(meme));
        vm.expectRevert(LincolnMemeFactory.InvalidToken.selector);
        factory.createPool(address(0));
        vm.expectRevert(LincolnMemeFactory.InvalidToken.selector);
        factory.createPool(ALICE);
        vm.expectRevert(LincolnMemeFactory.InvalidToken.selector);
        factory.createPool(address(usd));
        address notAToken = address(new NotAToken());
        vm.expectRevert(LincolnMemeFactory.InvalidToken.selector);
        factory.createPool(notAToken);
    }

    function testOnlyTheFactoryBindsAndDeploys() public {
        (Phase2ASPPool pool, AutoApproveProvider provider) = open();
        vm.prank(MALLORY);
        vm.expectRevert(AutoApproveProvider.NotBinder.selector);
        provider.bind(address(pool));
        address registry = address(provider.REGISTRY());
        vm.prank(MALLORY);
        vm.expectRevert(FactoryOnly.OnlyFactory.selector);
        poolDeployer.deploy(registry, address(meme));
        vm.prank(MALLORY);
        vm.expectRevert(FactoryOnly.OnlyFactory.selector);
        providerDeployer.deploy();
        vm.expectRevert(FactoryOnly.FactoryAlreadySet.selector);
        poolDeployer.setFactory(address(factory));
        PoolDeployer fresh = new PoolDeployer(address(verifier), address(exitVerifier));
        vm.prank(MALLORY);
        vm.expectRevert(FactoryOnly.OnlySetter.selector);
        fresh.setFactory(address(factory));
    }

    // ---------- approval rules ----------

    function testDirectDepositWaitsForTheScreeningDelay() public {
        (Phase2ASPPool pool, AutoApproveProvider provider) = open();
        uint256 c = deposit(pool, ALICE, 100e18, 11);
        eq(provider.sync(one(c)), 0, 'first sync only records');
        eq(provider.firstSeen(c), now_(), 'seen now');
        skip(DELAY - 1);
        eq(provider.sync(one(c)), 0, 'still waiting');
        skip(1);
        eq(provider.sync(one(c)), 1, 'approved after the delay');
        check(provider.approved(c), 'approved');
        eq(provider.sync(one(c)), 0, 'idempotent');
        (uint256 root, uint64 epoch,) = Phase2ASPRegistry(address(provider.REGISTRY())).latestPolicy();
        eq(root, provider.root(), 'published root');
        eq(epoch, 2, 'one new epoch per approving sync');
    }

    function testDeniedDepositorAndExcludedCommitmentAreWithheld() public {
        (Phase2ASPPool pool, AutoApproveProvider provider) = open();
        uint256 denied = deposit(pool, MALLORY, 100e18, 21);
        uint256 excluded = deposit(pool, ALICE, 100e18, 22);
        uint256[] memory both = new uint256[](2);
        both[0] = denied;
        both[1] = excluded;
        provider.sync(both);
        address[] memory who = new address[](1);
        who[0] = MALLORY;
        vm.prank(SAFE);
        screening.setDenied(who, true);
        vm.prank(SAFE);
        screening.setExcluded(one(excluded), true);
        skip(DELAY);
        eq(provider.sync(both), 0, 'both withheld');
        check(!provider.approved(denied) && !provider.approved(excluded), 'neither approved');
        check(pool.originalDepositor(denied) == MALLORY, 'ragequit stays open to the depositor');
        vm.prank(MALLORY);
        vm.expectRevert(ScreeningList.OnlyAdmin.selector);
        screening.setDenied(who, false);
    }

    function testSpendOutputsAreApprovedAtOnce() public {
        (Phase2ASPPool pool, AutoApproveProvider provider) = open();
        bytes[2] memory pair = outputs(31);
        Phase2ASPPool.ExtData memory data = selfData(0, address(0));
        uint256 context = pool.hashContext(data, pair);
        pool.transact([uint256(0), 0], [[uint256(0), 0], [uint256(0), 0]], [uint256(0), 0],
            signals(pool, context, 101, 102, 7001, 7002, 0), data, pair);
        check(pool.originalDepositor(7001) == address(0), 'spend output has no depositor');
        uint256[] memory both = new uint256[](2);
        both[0] = 7001;
        both[1] = 7002;
        eq(provider.sync(both), 2, 'approved without a delay');
    }

    function testRouteAdapterDepositsAreApprovedAtOnce() public {
        (Phase2ASPPool pool, AutoApproveProvider provider) = open();
        address adapter = factory.createV3Route(address(baseUsd), address(pool), usdToMeme());
        check(factory.isRouteAdapter(adapter), 'trusted');
        uint256 c = deposit(pool, adapter, 5e18, 41);
        eq(provider.sync(one(c)), 1, 'approved at once');
        uint256 other = deposit(pool, ALICE, 5e18, 42);
        eq(provider.sync(one(other)), 0, 'a plain depositor still waits');
    }

    function testUnknownCommitmentReverts() public {
        (, AutoApproveProvider provider) = open();
        vm.expectRevert(AutoApproveProvider.UnknownCommitment.selector);
        provider.sync(one(12345));
    }

    // ---------- guardian levers ----------

    function testSafeKeepsCapsPauseAndSuspension() public {
        (Phase2ASPPool pool, AutoApproveProvider provider) = open();
        Phase2ASPRegistry registry = Phase2ASPRegistry(address(provider.REGISTRY()));
        vm.prank(MALLORY);
        vm.expectRevert(Phase2ASPPool.UnauthorizedGuardian.selector);
        pool.pauseDeposits();
        vm.prank(SAFE);
        pool.setCaps(1_000e18, 10_000e18);
        eq(pool.maxDeposit(), 1_000e18, 'Safe lowered the cap');
        vm.prank(SAFE);
        pool.pauseDeposits();
        check(pool.depositsPaused(), 'paused');
        vm.prank(SAFE);
        registry.suspendProvider();
        check(registry.providerSuspended(), 'suspended');
        vm.expectRevert(Phase2ASPRegistry.ProviderIsSuspended.selector);
        provider.refresh();
    }

    // ---------- routes ----------

    function testRoutesNeedAFactoryPoolAndAreUnique() public {
        (Phase2ASPPool pool,) = open();
        bytes memory memeToUsd = abi.encodePacked(address(meme), uint24(500), address(usd));
        address buy = factory.createV3Route(address(baseUsd), address(pool), usdToMeme());
        address sell = factory.createV3Route(address(pool), address(baseUsd), memeToUsd);
        check(buy != sell && factory.isRouteAdapter(sell), 'both directions');
        check(Phase2FeeRouteBase(payable(buy)).TREASURY() == TREASURY && Phase2FeeRouteBase(payable(buy)).FEE_BPS() == 30, 'fixed fee and treasury');
        eq(factory.routeCount(), 2, 'listed');

        vm.expectRevert(LincolnMemeFactory.RouteExists.selector);
        factory.createV3Route(address(baseUsd), address(pool), usdToMeme());
        vm.expectRevert(LincolnMemeFactory.InvalidRoute.selector);
        factory.createV3Route(address(baseUsd), address(baseEth), abi.encodePacked(address(usd), uint24(500), address(weth)));
        vm.expectRevert(LincolnMemeFactory.InvalidRoute.selector);
        factory.createV3Route(address(pool), address(pool), usdToMeme());
        vm.expectRevert(LincolnMemeFactory.InvalidRoute.selector);
        factory.createV3Route(ALICE, address(pool), usdToMeme());

        v3Factory.setMissing(true);
        vm.expectRevert(Phase2FeeRouteBase.InvalidRoute.selector);
        factory.createV3Route(address(baseEth), address(pool), abi.encodePacked(address(weth), uint24(3000), address(meme)));
    }

    function testV4RoutesAreRecordedAndTrusted() public {
        (Phase2ASPPool pool,) = open();
        V4PoolKey memory key = V4PoolKey(address(0), address(meme), 10_000, 200, address(0));
        address adapter = factory.createV4Route(address(baseEth), address(pool), key);
        check(factory.isRouteAdapter(adapter), 'trusted');
        vm.expectRevert(LincolnMemeFactory.RouteExists.selector);
        factory.createV4Route(address(baseEth), address(pool), key);
        key.fee = 3000;
        factory.createV4Route(address(baseEth), address(pool), key);
        eq(factory.routeCount(), 2, 'another key is another route');
    }
}
