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
    function addr(uint256) external pure returns (address);
    function sign(uint256, bytes32) external pure returns (uint8, bytes32, bytes32);
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
    // Owners hold the stake (cold); relayers are the servers' signing keys (hot) and sign consent.
    address internal constant OWNER = address(0x0C01D);
    address internal constant OWNER2 = address(0x0C02D);
    address internal constant TYPO = address(0x7140);
    address internal constant THIEF = address(0xBAD);
    uint256 internal constant PK1 = 0xA0;
    uint256 internal constant PK2 = 0xA1;
    uint256 internal constant PK3 = 0xA2;
    uint256 internal constant PK4 = 0xA3;
    address internal KEY = vm.addr(PK1);
    address internal KEY2 = vm.addr(PK2);
    address internal KEY3 = vm.addr(PK3);
    address internal KEY4 = vm.addr(PK4);
    string internal constant URL = 'https://relay.example.com';

    StakeTokenV2 internal token;
    RelayStakeRegistryV2 internal registry;
    mapping(address => uint256) internal pkOf;

    error AssertionFailed(string message);
    function check(bool ok, string memory message) internal pure { if (!ok) revert AssertionFailed(message); }
    function eq(uint256 a, uint256 b, string memory message) internal pure { if (a != b) revert AssertionFailed(message); }
    function now_() internal view returns (uint256) { return vm.getBlockTimestamp(); }

    function setUp() public {
        vm.warp(1_800_000_000);
        token = new StakeTokenV2();
        registry = new RelayStakeRegistryV2(address(token), MIN, UNBOND, SAFE);
        pkOf[KEY] = PK1; pkOf[KEY2] = PK2; pkOf[KEY3] = PK3; pkOf[KEY4] = PK4;
        address[4] memory funded = [OWNER, OWNER2, KEY, THIEF];
        for (uint256 i; i < 4; i++) {
            token.mint(funded[i], 100 * uint256(MIN));
            vm.prank(funded[i]);
            token.approve(address(registry), type(uint256).max);
        }
    }

    /// The relay key's consent to be listed under `owner`, at its current nonce. Call before vm.prank.
    function consent(address key, address owner) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pkOf[key], registry.consentDigest(key, owner));
        return abi.encodePacked(r, s, v);
    }

    function register(address owner, address key, uint128 amount) internal {
        bytes memory c = consent(key, owner);
        vm.prank(owner);
        registry.register(key, URL, amount, c);
    }

    function rotate(address owner, address key, address newKey) internal {
        bytes memory c = consent(newKey, owner);
        vm.prank(owner);
        registry.rotateRelayer(key, newKey, c);
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
        eq(registry.nonces(KEY), 1, 'consent consumed');
        (bool ownerListed,,,,) = info(OWNER);
        check(!ownerListed, 'the owner is not a relay');
    }

    /// The case V2 exists for: a stolen server key cannot touch the stake.
    function testStolenRelayerKeyHasNoPowers() public {
        register(OWNER, KEY, MIN);
        bytes memory c = consent(KEY2, KEY);
        vm.startPrank(KEY);
        vm.expectRevert(RelayStakeRegistryV2.NotOwner.selector);
        registry.beginUnbond(KEY, MIN);
        vm.expectRevert(RelayStakeRegistryV2.NotOwner.selector);
        registry.withdraw(KEY);
        vm.expectRevert(RelayStakeRegistryV2.NotOwner.selector);
        registry.rotateRelayer(KEY, KEY2, c);
        vm.expectRevert(RelayStakeRegistryV2.NotOwner.selector);
        registry.transferOwnership(KEY, THIEF);
        vm.expectRevert(RelayStakeRegistryV2.NotOwner.selector);
        registry.setEndpoint(KEY, 'https://evil.example.com');
        vm.expectRevert(RelayStakeRegistryV2.NotOwner.selector);
        registry.addStake(KEY, 1);
        vm.stopPrank();
        // The owner answers by rotating to a fresh key; the stake follows.
        rotate(OWNER, KEY, KEY2);
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

    // ---------- relay-key consent (review M-1) and owner != relay (I-3) ----------

    function testNobodyCanListOrRotateOntoAKeyTheyDoNotControl() public {
        // Squatting: THIEF has the stake but no consent from KEY.
        vm.prank(THIEF);
        vm.expectRevert(RelayStakeRegistryV2.InvalidConsent.selector);
        registry.register(KEY, 'https://evil.example.com', MIN, '');
        // KEY's consent for OWNER is useless to anyone else.
        bytes memory forOwner = consent(KEY, OWNER);
        vm.prank(THIEF);
        vm.expectRevert(RelayStakeRegistryV2.InvalidConsent.selector);
        registry.register(KEY, URL, MIN, forOwner);
        // A signature from another key does not count.
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PK2, registry.consentDigest(KEY, THIEF));
        vm.prank(THIEF);
        vm.expectRevert(RelayStakeRegistryV2.InvalidConsent.selector);
        registry.register(KEY, URL, MIN, abi.encodePacked(r, s, v));
        // Rotating onto someone else's key needs that key's consent for this owner.
        register(OWNER2, KEY3, MIN);
        bytes memory thiefOwn = consent(KEY, THIEF);
        vm.prank(OWNER2);
        vm.expectRevert(RelayStakeRegistryV2.InvalidConsent.selector);
        registry.rotateRelayer(KEY3, KEY, thiefOwn);
        vm.prank(OWNER2);
        vm.expectRevert(RelayStakeRegistryV2.InvalidConsent.selector);
        registry.rotateRelayer(KEY3, KEY, forOwner);
        // The rightful owner still lists KEY with its consent.
        vm.prank(OWNER);
        registry.register(KEY, URL, MIN, forOwner);
        check(registry.relayOwner(KEY) == OWNER, 'operator listed its own key');
    }

    function testConsentIsSingleUse() public {
        bytes memory c = consent(KEY, OWNER);
        vm.prank(OWNER);
        registry.register(KEY, URL, MIN, c);
        stakeAll(OWNER, KEY);
        vm.prank(OWNER);
        registry.withdraw(KEY);
        // The freed key cannot be re-listed with the old signature, even by the same owner.
        vm.prank(OWNER);
        vm.expectRevert(RelayStakeRegistryV2.InvalidConsent.selector);
        registry.register(KEY, URL, MIN, c);
        register(OWNER, KEY, MIN);
        eq(registry.nonces(KEY), 2, 'fresh consent at nonce 1');
    }

    function testOwnerCannotBeItsOwnRelay() public {
        vm.prank(KEY);
        vm.expectRevert(RelayStakeRegistryV2.OwnerIsRelay.selector);
        registry.register(KEY, URL, MIN, '');
        register(OWNER, KEY2, MIN);
        vm.prank(OWNER);
        vm.expectRevert(RelayStakeRegistryV2.OwnerIsRelay.selector);
        registry.rotateRelayer(KEY2, OWNER, '');
        vm.prank(OWNER);
        vm.expectRevert(RelayStakeRegistryV2.OwnerIsRelay.selector);
        registry.transferOwnership(KEY2, KEY2);
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
        bytes memory c = consent(KEY3, OWNER);
        vm.prank(OWNER);
        vm.expectRevert(RelayStakeRegistryV2.AlreadyRegistered.selector);
        registry.register(KEY3, URL, MIN, c);
    }

    // ---------- rotation ----------

    function testRotationMovesEverythingAndKeepsTheListPosition() public {
        register(OWNER, KEY, MIN + 10e18);
        register(OWNER2, KEY3, MIN);
        vm.prank(OWNER);
        registry.beginUnbond(KEY, 10e18);
        vm.prank(OWNER);
        registry.transferOwnership(KEY, OWNER2); // a pending offer moves with the listing
        rotate(OWNER, KEY, KEY2);
        (bool oldListed,,,,) = info(KEY);
        (bool listed, bool active, uint128 stake, uint128 unbonding, string memory endpoint) = info(KEY2);
        check(!oldListed && registry.relayOwner(KEY) == address(0) && registry.pendingOwner(KEY) == address(0), 'old key forgotten');
        check(listed && active && stake == MIN && unbonding == 10e18 && keccak256(bytes(endpoint)) == keccak256(bytes(URL)), 'everything moved');
        check(registry.pendingOwner(KEY2) == OWNER2, 'pending offer moved');
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
        bytes memory c2 = consent(KEY2, OWNER);
        bytes memory c1 = consent(KEY, OWNER);
        vm.startPrank(OWNER);
        vm.expectRevert(RelayStakeRegistryV2.AlreadyRegistered.selector);
        registry.rotateRelayer(KEY, KEY2, c2); // another owner's live relay
        vm.expectRevert(RelayStakeRegistryV2.AlreadyRegistered.selector);
        registry.rotateRelayer(KEY, KEY, c1); // itself
        vm.expectRevert(RelayStakeRegistryV2.ZeroAddress.selector);
        registry.rotateRelayer(KEY, address(0), '');
        vm.stopPrank();
        // KEY2 fully unbonding (stake 0, record still present) is still taken.
        vm.prank(OWNER2);
        registry.beginUnbond(KEY2, MIN);
        vm.prank(OWNER);
        vm.expectRevert(RelayStakeRegistryV2.AlreadyRegistered.selector);
        registry.rotateRelayer(KEY, KEY2, c2);
        // Once KEY2 has withdrawn and its record is gone, the address is free again (with its consent).
        vm.warp(now_() + UNBOND);
        vm.prank(OWNER2);
        registry.withdraw(KEY2);
        rotate(OWNER, KEY, KEY2);
        check(registry.relayOwner(KEY2) == OWNER, 'rotated onto a freed address');
    }

    // ---------- suspension ----------

    function testSuspensionSticksAcrossRotationAndExit() public {
        register(OWNER, KEY, MIN);
        vm.prank(SAFE);
        registry.suspend(KEY, 'downtime');
        (, bool active,,,) = info(KEY);
        check(!active, 'suspended relay inactive');
        bytes memory c2 = consent(KEY2, OWNER);
        vm.prank(OWNER);
        vm.expectRevert(RelayStakeRegistryV2.RelaySuspended.selector);
        registry.rotateRelayer(KEY, KEY2, c2); // cannot shed a suspension by changing keys
        // Rotating onto a suspended key (here suspended pre-emptively, with no listing) is refused too.
        register(OWNER, KEY3, MIN);
        vm.prank(SAFE);
        registry.suspend(KEY4, 'known bad');
        bytes memory c4 = consent(KEY4, OWNER);
        vm.prank(OWNER);
        vm.expectRevert(RelayStakeRegistryV2.RelaySuspended.selector);
        registry.rotateRelayer(KEY3, KEY4, c4);
        // The stake is never trapped: unbond and withdraw still work for the owner.
        stakeAll(OWNER, KEY);
        uint256 before = token.balanceOf(OWNER);
        vm.prank(OWNER);
        registry.withdraw(KEY);
        eq(token.balanceOf(OWNER) - before, MIN, 'suspended stake returned to the owner');
        // The flag outlives the record: the key cannot come back until resumed.
        bytes memory c = consent(KEY, OWNER2);
        vm.prank(OWNER2);
        vm.expectRevert(RelayStakeRegistryV2.RelaySuspended.selector);
        registry.register(KEY, URL, MIN, c);
        vm.prank(SAFE);
        registry.resume(KEY);
        vm.prank(OWNER2);
        registry.register(KEY, URL, MIN, c);
        check(registry.relayOwner(KEY) == OWNER2, 're-registered after resume');
    }

    function testSuspendedOwnerCannotSpawnOrHandOverButCanExit() public {
        register(OWNER, KEY, MIN);
        vm.prank(SAFE);
        registry.suspend(OWNER, 'sybil');
        bytes memory c2 = consent(KEY2, OWNER);
        vm.startPrank(OWNER);
        vm.expectRevert(RelayStakeRegistryV2.RelaySuspended.selector);
        registry.register(KEY2, URL, MIN, c2);
        vm.expectRevert(RelayStakeRegistryV2.RelaySuspended.selector);
        registry.rotateRelayer(KEY, KEY2, c2);
        vm.expectRevert(RelayStakeRegistryV2.RelaySuspended.selector);
        registry.transferOwnership(KEY, OWNER2);
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

    /// Review L-1: a hand-over takes effect only when the new owner accepts, so a typo strands nothing.
    function testOwnershipMovesInTwoSteps() public {
        register(OWNER, KEY, MIN);
        vm.prank(OWNER);
        registry.transferOwnership(KEY, TYPO);
        check(registry.relayOwner(KEY) == OWNER && registry.pendingOwner(KEY) == TYPO, 'only offered');
        vm.prank(OWNER);
        registry.transferOwnership(KEY, OWNER2); // correct the typo
        vm.prank(TYPO);
        vm.expectRevert(RelayStakeRegistryV2.NotOwner.selector);
        registry.acceptOwnership(KEY);
        vm.prank(OWNER2);
        registry.acceptOwnership(KEY);
        check(registry.relayOwner(KEY) == OWNER2 && registry.pendingOwner(KEY) == address(0), 'accepted');
        vm.prank(OWNER);
        vm.expectRevert(RelayStakeRegistryV2.NotOwner.selector);
        registry.beginUnbond(KEY, MIN);
        stakeAll(OWNER2, KEY);
        uint256 before = token.balanceOf(OWNER2);
        vm.prank(OWNER2);
        registry.withdraw(KEY);
        eq(token.balanceOf(OWNER2) - before, MIN, 'paid to the new owner');
        // Cancelling: an offer to zero clears it.
        register(OWNER, KEY2, MIN);
        vm.prank(OWNER);
        registry.transferOwnership(KEY2, OWNER2);
        vm.prank(OWNER);
        registry.transferOwnership(KEY2, address(0));
        vm.prank(OWNER2);
        vm.expectRevert(RelayStakeRegistryV2.NotOwner.selector);
        registry.acceptOwnership(KEY2);
        // A suspended pending owner cannot accept.
        vm.prank(OWNER);
        registry.transferOwnership(KEY2, OWNER2);
        vm.prank(SAFE);
        registry.suspend(OWNER2, 'sybil');
        vm.prank(OWNER2);
        vm.expectRevert(RelayStakeRegistryV2.RelaySuspended.selector);
        registry.acceptOwnership(KEY2);
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
        bytes memory c = consent(KEY2, OWNER);
        vm.prank(OWNER);
        vm.expectRevert(RelayStakeRegistryV2.EndpointInvalid.selector);
        registry.register(KEY2, 'https://a"b.com', MIN, c);
        vm.prank(OWNER);
        vm.expectRevert(RelayStakeRegistryV2.BelowMinimumStake.selector);
        registry.register(KEY2, URL, MIN - 1, c);
    }

    // ---------- accounting fuzz ----------

    /// Random register / add / unbond / withdraw / rotate / hand-over sequences keep the registry's balance equal to
    /// the stakes plus pending unbonds of every listing.
    function testFuzz_balanceMatchesLiabilities(uint256 seed) public {
        address[2] memory owners = [OWNER, OWNER2];
        address[4] memory keys = [KEY, KEY2, KEY3, KEY4];
        for (uint256 step; step < 28; step++) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            address owner = owners[seed % 2];
            address key = keys[(seed >> 8) % 4];
            address other = keys[(seed >> 16) % 4];
            uint256 op = (seed >> 24) % 7;
            uint128 amount = uint128(MIN + (seed >> 32) % (5 * uint256(MIN)));
            address current = registry.relayOwner(key);
            (bool listed,, uint128 stake, uint128 unbonding,) = info(key);
            address sender = current == address(0) ? owner : current;
            bytes memory c = op == 4 ? consent(other, sender) : consent(key, sender);
            address pending = registry.pendingOwner(key);
            vm.startPrank(sender);
            if (op == 0 && current == address(0)) registry.register(key, URL, amount, c);
            else if (op == 1 && listed) registry.addStake(key, amount);
            else if (op == 2 && listed && unbonding == 0 && stake > 0) registry.beginUnbond(key, stake);
            else if (op == 3 && listed && unbonding != 0) { vm.warp(now_() + UNBOND); registry.withdraw(key); }
            else if (op == 4 && listed && registry.relayOwner(other) == address(0) && other != key) registry.rotateRelayer(key, other, c);
            else if (op == 5 && listed) registry.transferOwnership(key, owner);
            else if (op == 6 && listed && pending != address(0)) { vm.stopPrank(); vm.startPrank(pending); registry.acceptOwnership(key); }
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
