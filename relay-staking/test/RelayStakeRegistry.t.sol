// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {RelayStakeRegistry} from '../src/RelayStakeRegistry.sol';

/// @dev Minimal cheatcode surface; forge-std is not vendored in this repository.
interface Vm {
    function warp(uint256) external;
    function getBlockTimestamp() external view returns (uint256);
    function prank(address) external;
    function startPrank(address) external;
    function stopPrank() external;
    function expectRevert(bytes4) external;
    function assume(bool) external;
}

contract StakeToken is ERC20 {
    constructor() ERC20('LINCOLN', 'LINCOLN') {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract RelayStakeRegistryTest {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256('hevm cheat code')))));
    uint128 internal constant MIN = 5_000_000e18;
    uint64 internal constant UNBOND = 14 days;
    address internal constant SAFE = address(0x5AFE);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA201);
    string internal constant URL = 'https://relay.example.com';

    StakeToken internal token;
    RelayStakeRegistry internal registry;

    error AssertionFailed(string message);

    function check(bool ok, string memory message) internal pure { if (!ok) revert AssertionFailed(message); }
    function eq(uint256 a, uint256 b, string memory message) internal pure { if (a != b) revert AssertionFailed(message); }
    function now_() internal view returns (uint256) { return vm.getBlockTimestamp(); }

    function setUp() public {
        vm.warp(1_800_000_000);
        token = new StakeToken();
        registry = new RelayStakeRegistry(address(token), MIN, UNBOND, SAFE);
        for (uint256 i; i < 3; i++) {
            address who = [ALICE, BOB, CAROL][i];
            token.mint(who, 100 * uint256(MIN));
            vm.prank(who);
            token.approve(address(registry), type(uint256).max);
        }
    }

    function register(address who, uint128 amount) internal {
        vm.prank(who);
        registry.register(URL, amount);
    }

    function stakeOf(address who) internal view returns (uint128 stake, uint128 unbonding, bool listed, bool active) {
        bool suspended; uint64 at; uint64 reg; string memory endpoint;
        (listed, active, suspended, stake, unbonding, at, reg, endpoint) = registry.relayInfo(who);
    }

    // ---------- constructor ----------

    function testConstructorRejectsBadParameters() public {
        vm.expectRevert(RelayStakeRegistry.ZeroAddress.selector);
        new RelayStakeRegistry(address(0), MIN, UNBOND, SAFE);
        vm.expectRevert(RelayStakeRegistry.ZeroAddress.selector);
        new RelayStakeRegistry(address(token), MIN, UNBOND, address(0));
        vm.expectRevert(RelayStakeRegistry.InvalidParameters.selector);
        new RelayStakeRegistry(address(token), 0, UNBOND, SAFE);
        vm.expectRevert(RelayStakeRegistry.InvalidParameters.selector);
        new RelayStakeRegistry(address(token), MIN, 0, SAFE);
        vm.expectRevert(RelayStakeRegistry.InvalidParameters.selector);
        new RelayStakeRegistry(address(token), MIN, 90 days + 1, SAFE);
        RelayStakeRegistry ok = new RelayStakeRegistry(address(token), MIN, 90 days, SAFE);
        check(address(ok.STAKE_TOKEN()) == address(token) && ok.MIN_STAKE() == MIN && ok.GUARDIAN() == SAFE, 'immutables');
    }

    // ---------- register ----------

    function testRegisterTakesStakeAndLists() public {
        uint256 before = token.balanceOf(ALICE);
        register(ALICE, MIN);
        (uint128 stake,, bool listed, bool active) = stakeOf(ALICE);
        check(listed && active && stake == MIN, 'listed and active');
        eq(token.balanceOf(address(registry)), MIN, 'registry holds the stake');
        eq(before - token.balanceOf(ALICE), MIN, 'pulled exactly');
        eq(registry.relayCount(), 1, 'count');
        check(registry.relayAt(0) == ALICE, 'listed at 0');
        vm.prank(ALICE);
        vm.expectRevert(RelayStakeRegistry.AlreadyRegistered.selector);
        registry.register(URL, MIN);
    }

    function testRegisterRejectsLowStakeAndBadEndpoints() public {
        vm.prank(ALICE);
        vm.expectRevert(RelayStakeRegistry.BelowMinimumStake.selector);
        registry.register(URL, MIN - 1);
        string[9] memory bad = ['http://relay.example.com', 'https://', 'ftp://x.example', 'https://a b.com', 'https://a"b.com',
            "https://a'b.com", 'https://a<b>.com', 'https://a`b.com', 'https://a\\b.com'];
        for (uint256 i; i < bad.length; i++) {
            vm.prank(ALICE);
            vm.expectRevert(RelayStakeRegistry.EndpointInvalid.selector);
            registry.register(bad[i], MIN);
        }
        bytes memory long = new bytes(201);
        for (uint256 i; i < long.length; i++) long[i] = 'a';
        bytes memory prefix = 'https://';
        for (uint256 i; i < prefix.length; i++) long[i] = prefix[i];
        vm.prank(ALICE);
        vm.expectRevert(RelayStakeRegistry.EndpointInvalid.selector);
        registry.register(string(long), MIN);
        vm.prank(ALICE);
        registry.register('https://a.b', MIN);
    }

    // ---------- stake changes ----------

    function testAddStakeAndSetEndpoint() public {
        vm.prank(ALICE);
        vm.expectRevert(RelayStakeRegistry.NotRelay.selector);
        registry.addStake(1);
        register(ALICE, MIN);
        vm.prank(ALICE);
        vm.expectRevert(RelayStakeRegistry.InvalidAmount.selector);
        registry.addStake(0);
        vm.prank(ALICE);
        registry.addStake(1e18);
        (uint128 stake,,,) = stakeOf(ALICE);
        eq(stake, MIN + 1e18, 'added');
        vm.prank(ALICE);
        registry.setEndpoint('https://new.example.com');
        vm.prank(BOB);
        vm.expectRevert(RelayStakeRegistry.NotRelay.selector);
        registry.setEndpoint('https://bob.example.com');
    }

    function testUnbondRules() public {
        register(ALICE, MIN + 10e18);
        vm.startPrank(ALICE);
        vm.expectRevert(RelayStakeRegistry.InvalidAmount.selector);
        registry.beginUnbond(0);
        vm.expectRevert(RelayStakeRegistry.InvalidAmount.selector);
        registry.beginUnbond(MIN + 11e18);
        vm.expectRevert(RelayStakeRegistry.BelowMinimumStake.selector);
        registry.beginUnbond(11e18); // would leave dust below MIN
        registry.beginUnbond(10e18); // leaves exactly MIN
        vm.expectRevert(RelayStakeRegistry.UnbondPending.selector);
        registry.beginUnbond(1e18);
        vm.stopPrank();
        (uint128 stake, uint128 unbonding,, bool active) = stakeOf(ALICE);
        check(stake == MIN && unbonding == 10e18 && active, 'partial unbond keeps the relay active');
    }

    function testWithdrawAfterUnbondingAndPartialKeepsListing() public {
        register(ALICE, MIN + 10e18);
        vm.prank(ALICE);
        registry.beginUnbond(10e18);
        vm.prank(ALICE);
        vm.expectRevert(RelayStakeRegistry.UnbondNotReady.selector);
        registry.withdraw();
        vm.warp(now_() + UNBOND - 1);
        vm.prank(ALICE);
        vm.expectRevert(RelayStakeRegistry.UnbondNotReady.selector);
        registry.withdraw();
        vm.warp(now_() + 1);
        uint256 before = token.balanceOf(ALICE);
        vm.prank(ALICE);
        registry.withdraw();
        eq(token.balanceOf(ALICE) - before, 10e18, 'withdrawn');
        (, , bool listed, bool active) = stakeOf(ALICE);
        check(listed && active, 'still listed with MIN');
        vm.prank(ALICE);
        vm.expectRevert(RelayStakeRegistry.NothingToWithdraw.selector);
        registry.withdraw();
    }

    function testFullExitRemovesAndReorders() public {
        register(ALICE, MIN);
        register(BOB, MIN);
        register(CAROL, MIN);
        vm.prank(ALICE);
        registry.beginUnbond(MIN);
        (,,, bool active) = stakeOf(ALICE);
        check(!active, 'inactive while fully unbonding');
        eq(registry.activeRelays().length, 2, 'two active');
        vm.warp(now_() + UNBOND);
        vm.prank(ALICE);
        registry.withdraw();
        eq(registry.relayCount(), 2, 'removed');
        check(registry.relayAt(0) == CAROL && registry.relayAt(1) == BOB, 'last moved into the gap');
        (,, bool listed,) = stakeOf(ALICE);
        check(!listed, 'record deleted');
        // The moved relay's index was updated: it can still exit cleanly.
        vm.prank(CAROL);
        registry.beginUnbond(MIN);
        vm.warp(now_() + UNBOND);
        vm.prank(CAROL);
        registry.withdraw();
        eq(registry.relayCount(), 1, 'one left');
        check(registry.relayAt(0) == BOB, 'bob remains');
        register(ALICE, MIN);
        eq(registry.relayCount(), 2, 'a clean address can re-register');
        eq(token.balanceOf(address(registry)), 2 * uint256(MIN), 'balance matches the two stakes');
    }

    function testRestakeWhileFullyUnbonding() public {
        register(ALICE, MIN);
        vm.prank(ALICE);
        registry.beginUnbond(MIN);
        vm.prank(ALICE);
        vm.expectRevert(RelayStakeRegistry.BelowMinimumStake.selector);
        registry.addStake(MIN - 1);
        vm.prank(ALICE);
        registry.addStake(MIN);
        (,,, bool active) = stakeOf(ALICE);
        check(active, 'active again');
        vm.warp(now_() + UNBOND);
        vm.prank(ALICE);
        registry.withdraw();
        (uint128 stake, uint128 unbonding, bool listed,) = stakeOf(ALICE);
        check(listed && stake == MIN && unbonding == 0, 'withdrawing the old unbond keeps the new stake listed');
    }

    // ---------- guardian ----------

    function testSuspensionIsStickyButNeverTrapsStake() public {
        register(ALICE, MIN);
        vm.prank(BOB);
        vm.expectRevert(RelayStakeRegistry.NotGuardian.selector);
        registry.suspend(ALICE, 'x');
        vm.prank(SAFE);
        registry.suspend(ALICE, 'downtime');
        (,,, bool active) = stakeOf(ALICE);
        check(!active && registry.activeRelays().length == 0, 'suspended relays are inactive');
        vm.prank(SAFE);
        vm.expectRevert(RelayStakeRegistry.AlreadySuspended.selector);
        registry.suspend(ALICE, 'again');
        // A suspended relay can still leave with all of its stake.
        uint256 before = token.balanceOf(ALICE);
        vm.prank(ALICE);
        registry.beginUnbond(MIN);
        vm.warp(now_() + UNBOND);
        vm.prank(ALICE);
        registry.withdraw();
        eq(token.balanceOf(ALICE) - before, MIN, 'full stake returned');
        // The flag survives the exit and blocks re-registration until the Safe resumes it.
        vm.prank(ALICE);
        vm.expectRevert(RelayStakeRegistry.RelaySuspended.selector);
        registry.register(URL, MIN);
        vm.prank(SAFE);
        registry.resume(ALICE);
        register(ALICE, MIN);
        (,,, active) = stakeOf(ALICE);
        check(active, 'active after resume');
        vm.prank(SAFE);
        vm.expectRevert(RelayStakeRegistry.NotSuspended.selector);
        registry.resume(ALICE);
    }

    function testPreemptiveSuspension() public {
        vm.prank(SAFE);
        registry.suspend(BOB, 'known bad');
        vm.prank(BOB);
        vm.expectRevert(RelayStakeRegistry.RelaySuspended.selector);
        registry.register(URL, MIN);
        vm.prank(SAFE);
        vm.expectRevert(RelayStakeRegistry.ZeroAddress.selector);
        registry.suspend(address(0), 'zero');
    }

    // ---------- accounting fuzz ----------

    /// Random register / add / unbond / withdraw sequences keep the registry's token balance
    /// equal to the sum of stakes and pending unbonds.
    function testFuzz_balanceMatchesLiabilities(uint256 seed) public {
        address[3] memory who = [ALICE, BOB, CAROL];
        for (uint256 step; step < 24; step++) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            address a = who[seed % 3];
            uint256 op = (seed >> 8) % 5;
            uint128 amount = uint128(MIN + (seed >> 16) % (10 * uint256(MIN)));
            (uint128 stake, uint128 unbonding, bool listed,) = stakeOf(a);
            vm.startPrank(a);
            if (op == 0 && !listed) registry.register(URL, amount);
            else if (op == 1 && listed) registry.addStake(amount);
            else if (op == 2 && listed && unbonding == 0 && stake > 0) registry.beginUnbond(stake);
            else if (op == 3 && listed && unbonding != 0) { vm.warp(now_() + UNBOND); registry.withdraw(); }
            else if (op == 4) vm.warp(now_() + 1 days);
            vm.stopPrank();
            uint256 owed;
            for (uint256 i; i < 3; i++) { (uint128 s, uint128 u,,) = stakeOf(who[i]); owed += s + u; }
            eq(token.balanceOf(address(registry)), owed, 'balance equals stakes plus unbonding');
        }
    }
}
