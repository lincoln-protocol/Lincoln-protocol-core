// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {RelayStakeRegistryV2} from '../src/RelayStakeRegistryV2.sol';

/// @dev Minimal cheatcode surface; forge-std is not vendored in this repository.
interface VmV2 {
    function warp(uint256) external;
    function getBlockTimestamp() external view returns (uint256);
    function prank(address) external;
    function startPrank(address) external;
    function stopPrank() external;
    function expectRevert(bytes4) external;
}

contract StakeTokenV2 is ERC20 {
    constructor() ERC20('LINCOLN', 'LINCOLN') {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract RelayStakeRegistryV2Test {
    VmV2 internal constant vm = VmV2(address(uint160(uint256(keccak256('hevm cheat code')))));
    uint128 internal constant MIN = 5_000_000e18;
    uint64 internal constant UNBOND = 14 days;
    address internal constant SAFE = address(0x5AFE);
    // Owners hold the stake (cold); relayers are the servers' signing keys (hot).
    address internal constant OWNER = address(0x0C01D);
    address internal constant OWNER2 = address(0x0C02D);
    address internal constant KEY = address(0xA0);
    address internal constant KEY2 = address(0xA1);
    address internal constant KEY3 = address(0xA2);
    address internal constant THIEF = address(0xBAD);
    string internal constant URL = 'https://relay.example.com';

    StakeTokenV2 internal token;
    RelayStakeRegistryV2 internal registry;

    error AssertionFailed(string message);
    function check(bool ok, string memory message) internal pure { if (!ok) revert AssertionFailed(message); }
    function eq(uint256 a, uint256 b, string memory message) internal pure { if (a != b) revert AssertionFailed(message); }
    function now_() internal view returns (uint256) { return vm.getBlockTimestamp(); }

    function setUp() public {
        vm.warp(1_800_000_000);
        token = new StakeTokenV2();
        registry = new RelayStakeRegistryV2(address(token), MIN, UNBOND, SAFE);
        address[3] memory funded = [OWNER, OWNER2, KEY];
        for (uint256 i; i < 3; i++) {
            token.mint(funded[i], 100 * uint256(MIN));
            vm.prank(funded[i]);
            token.approve(address(registry), type(uint256).max);
        }
    }

    function register(address owner, address key, uint128 amount) internal {
        vm.prank(owner);
        registry.register(key, URL, amount);
    }

    function info(address key) internal view returns (bool listed, bool active, uint128 stake, uint128 unbonding, string memory endpoint) {
        bool s; uint64 a; uint64 reg;
        (listed, active, s, stake, unbonding, a, reg, endpoint) = registry.relayInfo(key);
    }

    function stakeAll(address owner, address key) internal {
        vm.prank(owner);
        registry.beginUnbond(key, MIN);
        vm.warp(now_() + UNBOND);
    }

    // ---------- constructor ----------

    function testConstructorRejectsBadParameters() public {
        vm.expectRevert(RelayStakeRegistryV2.ZeroAddress.selector);
        new RelayStakeRegistryV2(address(0), MIN, UNBOND, SAFE);
        vm.expectRevert(RelayStakeRegistryV2.ZeroAddress.selector);
        new RelayStakeRegistryV2(address(token), MIN, UNBOND, address(0));
        vm.expectRevert(RelayStakeRegistryV2.InvalidParameters.selector);
        new RelayStakeRegistryV2(address(token), 0, UNBOND, SAFE);
        vm.expectRevert(RelayStakeRegistryV2.InvalidParameters.selector);
        new RelayStakeRegistryV2(address(token), MIN, 90 days + 1, SAFE);
    }

    // ---------- owner and relayer are separate ----------

    function testOwnerStakesForARelayerKey() public {
        uint256 before = token.balanceOf(OWNER);
        register(OWNER, KEY, MIN);
        (bool listed, bool active, uint128 stake,,) = info(KEY);
        check(listed && active && stake == MIN, 'keyed by the relayer');
        check(registry.relayOwner(KEY) == OWNER, 'owner recorded');
        eq(before - token.balanceOf(OWNER), MIN, 'pulled from the owner');
        eq(token.balanceOf(KEY), 100 * uint256(MIN), 'nothing taken from the relayer key');
        check(registry.relayAt(0) == KEY && registry.activeRelays()[0] == KEY, 'lists the relayer');
        (bool ownerListed,,,,) = info(OWNER);
        check(!ownerListed, 'the owner is not a relay');
    }

    /// The case V2 exists for: a stolen server key cannot touch the stake.
    function testStolenRelayerKeyHasNoPowers() public {
        register(OWNER, KEY, MIN);
        vm.startPrank(KEY);
        vm.expectRevert(RelayStakeRegistryV2.NotOwner.selector);
        registry.beginUnbond(KEY, MIN);
        vm.expectRevert(RelayStakeRegistryV2.NotOwner.selector);
        registry.withdraw(KEY);
        vm.expectRevert(RelayStakeRegistryV2.NotOwner.selector);
        registry.rotateRelayer(KEY, THIEF);
        vm.expectRevert(RelayStakeRegistryV2.NotOwner.selector);
        registry.setOwner(KEY, THIEF);
        vm.expectRevert(RelayStakeRegistryV2.NotOwner.selector);
        registry.setEndpoint(KEY, 'https://evil.example.com');
        vm.expectRevert(RelayStakeRegistryV2.NotOwner.selector);
        registry.addStake(KEY, 1);
        vm.stopPrank();
        // The owner answers by rotating to a fresh key; the stake follows.
        vm.prank(OWNER);
        registry.rotateRelayer(KEY, KEY2);
        (,, uint128 stake,,) = info(KEY2);
        eq(stake, MIN, 'stake moved to the new key');
    }

    function testWithdrawPaysTheOwnerOnly() public {
        register(OWNER, KEY, MIN);
        stakeAll(OWNER, KEY);
        uint256 ownerBefore = token.balanceOf(OWNER);
        uint256 keyBefore = token.balanceOf(KEY);
        vm.prank(OWNER);
        registry.withdraw(KEY);
        eq(token.balanceOf(OWNER) - ownerBefore, MIN, 'owner paid');
        eq(token.balanceOf(KEY), keyBefore, 'relayer key paid nothing');
        eq(registry.relayCount(), 0, 'removed after a full exit');
        check(registry.relayOwner(KEY) == address(0), 'record deleted');
    }

    // ---------- several relayers per owner ----------

    function testOwnerWithSeveralRelayers() public {
        register(OWNER, KEY, MIN);
        register(OWNER, KEY2, 2 * MIN);
        register(OWNER2, KEY3, MIN);
        eq(registry.relayCount(), 3, 'three listings');
        eq(registry.activeRelays().length, 3, 'all active');
        vm.prank(OWNER);
        registry.beginUnbond(KEY2, MIN);
        (,, uint128 s1,,) = info(KEY);
        (,, uint128 s2, uint128 u2,) = info(KEY2);
        check(s1 == MIN && s2 == MIN && u2 == MIN, 'listings are independent');
        vm.prank(OWNER2);
        vm.expectRevert(RelayStakeRegistryV2.NotOwner.selector);
        registry.beginUnbond(KEY, MIN);
        vm.prank(OWNER);
        vm.expectRevert(RelayStakeRegistryV2.AlreadyRegistered.selector);
        registry.register(KEY3, URL, MIN);
    }

    // ---------- rotation ----------

    function testRotationMovesEverythingAndKeepsTheListPosition() public {
        register(OWNER, KEY, MIN + 10e18);
        register(OWNER2, KEY3, MIN);
        vm.prank(OWNER);
        registry.beginUnbond(KEY, 10e18);
        vm.prank(OWNER);
        registry.rotateRelayer(KEY, KEY2);
        (bool oldListed,,,,) = info(KEY);
        (bool listed, bool active, uint128 stake, uint128 unbonding, string memory endpoint) = info(KEY2);
        check(!oldListed && registry.relayOwner(KEY) == address(0), 'old key forgotten');
        check(listed && active && stake == MIN && unbonding == 10e18 && keccak256(bytes(endpoint)) == keccak256(bytes(URL)), 'everything moved');
        check(registry.relayAt(0) == KEY2 && registry.relayAt(1) == KEY3, 'same list position');
        vm.warp(now_() + UNBOND);
        uint256 before = token.balanceOf(OWNER);
        vm.prank(OWNER);
        registry.withdraw(KEY2);
        eq(token.balanceOf(OWNER) - before, 10e18, 'pending unbond withdraws under the new key');
        // The moved index stays correct for a later swap-and-pop.
        stakeAll(OWNER2, KEY3);
        vm.prank(OWNER2);
        registry.withdraw(KEY3);
        check(registry.relayCount() == 1 && registry.relayAt(0) == KEY2, 'index intact');
    }

    function testRotationOntoTakenOrUnbondingAddressesFails() public {
        register(OWNER, KEY, MIN);
        register(OWNER2, KEY2, MIN);
        vm.startPrank(OWNER);
        vm.expectRevert(RelayStakeRegistryV2.AlreadyRegistered.selector);
        registry.rotateRelayer(KEY, KEY2); // another owner's live relay
        vm.expectRevert(RelayStakeRegistryV2.AlreadyRegistered.selector);
        registry.rotateRelayer(KEY, KEY); // itself
        vm.expectRevert(RelayStakeRegistryV2.ZeroAddress.selector);
        registry.rotateRelayer(KEY, address(0));
        vm.stopPrank();
        // KEY2 fully unbonding (stake 0, record still present) is still taken.
        vm.prank(OWNER2);
        registry.beginUnbond(KEY2, MIN);
        vm.prank(OWNER);
        vm.expectRevert(RelayStakeRegistryV2.AlreadyRegistered.selector);
        registry.rotateRelayer(KEY, KEY2);
        // Once KEY2 has withdrawn and its record is gone, the address is free again.
        vm.warp(now_() + UNBOND);
        vm.prank(OWNER2);
        registry.withdraw(KEY2);
        vm.prank(OWNER);
        registry.rotateRelayer(KEY, KEY2);
        check(registry.relayOwner(KEY2) == OWNER, 'rotated onto a freed address');
    }

    // ---------- suspension ----------

    function testSuspensionSticksAcrossRotationAndExit() public {
        register(OWNER, KEY, MIN);
        vm.prank(SAFE);
        registry.suspend(KEY, 'downtime');
        (, bool active,,,) = info(KEY);
        check(!active, 'suspended relay inactive');
        vm.prank(OWNER);
        vm.expectRevert(RelayStakeRegistryV2.RelaySuspended.selector);
        registry.rotateRelayer(KEY, KEY2); // cannot shed a suspension by changing keys
        // Rotating onto a suspended key (here suspended pre-emptively, with no listing) is refused too.
        register(OWNER, KEY3, MIN);
        vm.prank(SAFE);
        registry.suspend(THIEF, 'known bad');
        vm.prank(OWNER);
        vm.expectRevert(RelayStakeRegistryV2.RelaySuspended.selector);
        registry.rotateRelayer(KEY3, THIEF);
        // The stake is never trapped: unbond and withdraw still work for the owner.
        stakeAll(OWNER, KEY);
        uint256 before = token.balanceOf(OWNER);
        vm.prank(OWNER);
        registry.withdraw(KEY);
        eq(token.balanceOf(OWNER) - before, MIN, 'suspended stake returned to the owner');
        // The flag outlives the record: the key cannot come back until resumed.
        vm.prank(OWNER2);
        vm.expectRevert(RelayStakeRegistryV2.RelaySuspended.selector);
        registry.register(KEY, URL, MIN);
        vm.prank(SAFE);
        registry.resume(KEY);
        register(OWNER2, KEY, MIN);
        check(registry.relayOwner(KEY) == OWNER2, 're-registered after resume');
    }

    function testSuspendedOwnerCannotSpawnOrHandOverButCanExit() public {
        register(OWNER, KEY, MIN);
        vm.prank(SAFE);
        registry.suspend(OWNER, 'sybil');
        vm.startPrank(OWNER);
        vm.expectRevert(RelayStakeRegistryV2.RelaySuspended.selector);
        registry.register(KEY2, URL, MIN);
        vm.expectRevert(RelayStakeRegistryV2.RelaySuspended.selector);
        registry.rotateRelayer(KEY, KEY2);
        vm.expectRevert(RelayStakeRegistryV2.RelaySuspended.selector);
        registry.setOwner(KEY, OWNER2);
        registry.beginUnbond(KEY, MIN);
        vm.warp(now_() + UNBOND);
        registry.withdraw(KEY);
        vm.stopPrank();
        eq(registry.relayCount(), 0, 'exited');
    }

    // ---------- re-registration and ownership ----------

    function testRelayerAddressReusableAfterFullExit() public {
        register(OWNER, KEY, MIN);
        stakeAll(OWNER, KEY);
        vm.prank(OWNER);
        registry.withdraw(KEY);
        register(OWNER2, KEY, MIN);
        check(registry.relayOwner(KEY) == OWNER2, 'a new owner can list the freed key');
        (,, uint128 stake, uint128 unbonding,) = info(KEY);
        check(stake == MIN && unbonding == 0, 'fresh record, nothing carried over');
    }

    function testSetOwnerHandsOverWithdrawalRights() public {
        register(OWNER, KEY, MIN);
        vm.prank(OWNER);
        registry.setOwner(KEY, OWNER2);
        check(registry.relayOwner(KEY) == OWNER2, 'new owner');
        vm.prank(OWNER);
        vm.expectRevert(RelayStakeRegistryV2.NotOwner.selector);
        registry.beginUnbond(KEY, MIN);
        stakeAll(OWNER2, KEY);
        uint256 before = token.balanceOf(OWNER2);
        vm.prank(OWNER2);
        registry.withdraw(KEY);
        eq(token.balanceOf(OWNER2) - before, MIN, 'paid to the new owner');
    }

    function testUnbondAndEndpointRules() public {
        register(OWNER, KEY, MIN + 10e18);
        vm.startPrank(OWNER);
        vm.expectRevert(RelayStakeRegistryV2.BelowMinimumStake.selector);
        registry.beginUnbond(KEY, 11e18);
        registry.beginUnbond(KEY, 10e18);
        vm.expectRevert(RelayStakeRegistryV2.UnbondPending.selector);
        registry.beginUnbond(KEY, 1e18);
        vm.expectRevert(RelayStakeRegistryV2.UnbondNotReady.selector);
        registry.withdraw(KEY);
        vm.expectRevert(RelayStakeRegistryV2.EndpointInvalid.selector);
        registry.setEndpoint(KEY, 'http://relay.example.com');
        registry.setEndpoint(KEY, 'https://new.example.com');
        vm.stopPrank();
        vm.prank(OWNER);
        vm.expectRevert(RelayStakeRegistryV2.EndpointInvalid.selector);
        registry.register(KEY2, 'https://a"b.com', MIN);
        vm.prank(OWNER);
        vm.expectRevert(RelayStakeRegistryV2.BelowMinimumStake.selector);
        registry.register(KEY2, URL, MIN - 1);
    }

    // ---------- accounting fuzz ----------

    /// Random register / add / unbond / withdraw / rotate / hand-over sequences keep the registry's balance equal to
    /// the stakes plus pending unbonds of every listing.
    function testFuzz_balanceMatchesLiabilities(uint256 seed) public {
        address[2] memory owners = [OWNER, OWNER2];
        address[4] memory keys = [KEY, KEY2, KEY3, address(0xA3)];
        for (uint256 step; step < 28; step++) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            address owner = owners[seed % 2];
            address key = keys[(seed >> 8) % 4];
            address other = keys[(seed >> 16) % 4];
            uint256 op = (seed >> 24) % 7;
            uint128 amount = uint128(MIN + (seed >> 32) % (5 * uint256(MIN)));
            address current = registry.relayOwner(key);
            (bool listed,, uint128 stake, uint128 unbonding,) = info(key);
            vm.startPrank(current == address(0) ? owner : current);
            if (op == 0 && current == address(0)) registry.register(key, URL, amount);
            else if (op == 1 && listed) registry.addStake(key, amount);
            else if (op == 2 && listed && unbonding == 0 && stake > 0) registry.beginUnbond(key, stake);
            else if (op == 3 && listed && unbonding != 0) { vm.warp(now_() + UNBOND); registry.withdraw(key); }
            else if (op == 4 && listed && registry.relayOwner(other) == address(0) && other != key) registry.rotateRelayer(key, other);
            else if (op == 5 && listed) registry.setOwner(key, owner);
            else vm.warp(now_() + 1 days);
            vm.stopPrank();
            uint256 owed;
            for (uint256 i; i < 4; i++) { (,, uint128 s, uint128 u,) = info(keys[i]); owed += s + u; }
            eq(token.balanceOf(address(registry)), owed, 'balance equals stakes plus unbonding');
            uint256 listedCount;
            for (uint256 i; i < 4; i++) { (bool l,,,,) = info(keys[i]); if (l) listedCount++; }
            eq(registry.relayCount(), listedCount, 'list matches records');
        }
    }
}
