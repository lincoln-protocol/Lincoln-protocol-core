// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {ReentrancyGuard} from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import {EIP712} from '@openzeppelin/contracts/utils/cryptography/EIP712.sol';
import {ECDSA} from '@openzeppelin/contracts/utils/cryptography/ECDSA.sol';

/// @title RelayStakeRegistryV2
/// @notice Permissionless registry of relay operators backed by a LINCOLN stake, with the stake owned by a
///         separate wallet from the relay's signing key.
/// @dev V1 made the relay's hot signing key (the pools' `processor`, which must live on the relay server) also
///      the staker, so a stolen server key could unbond and withdraw the stake. Here each relay has:
///        - an `owner`: the wallet that staked (cold; may be a Safe). Only it can add stake, change the endpoint,
///          rotate the relayer key, transfer ownership, unbond and withdraw, and withdrawals always pay it;
///        - a `relayer`: the hot key the relay signs with. It has no powers in this contract beyond consenting, once,
///          to be listed under a given owner (an EIP-712 `RelayConsent` signature, no gas), so nobody can list or
///          rotate onto a key they do not control. The owner and the relayer must be different addresses.
///      Ownership moves in two steps (offer, then accept by the new owner).
///      Everything clients and indexers read is keyed by the relayer address, exactly as in V1: `relayInfo`,
///      `RelayStatus`, `relayAt`, `activeRelays`.
///      Trust boundary: GUARDIAN (the protocol Safe) can suspend an address, which removes a relayer from the
///      active set, blocks it from being rotated away or re-registered, and stops a suspended owner from
///      registering or rotating to new relayers. Stake is never confiscated; a suspended relay can still unbond
///      and its owner withdraw. Owner suspension does not deactivate that owner's existing relayers: the guardian
///      suspends those relayer addresses directly, so `RelayStatus` alone describes the active set.
contract RelayStakeRegistryV2 is ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;

    struct Relay {
        address owner;            // wallet that staked and controls this listing; zero = no record
        address pendingOwner;     // offered by `transferOwnership`, takes over on `acceptOwnership`
        uint128 stake;            // active stake counted toward MIN_STAKE
        uint128 unbonding;        // amount waiting out UNBONDING_SECONDS
        uint64 unbondAvailableAt; // when `unbonding` can be withdrawn
        uint64 registeredAt;
        uint32 index;             // position in _list while listed
        bool listed;
        string endpoint;          // public HTTPS base URL of the relay API
    }

    IERC20 public immutable STAKE_TOKEN;
    uint128 public immutable MIN_STAKE;
    uint64 public immutable UNBONDING_SECONDS;
    address public immutable GUARDIAN;
    uint256 public constant MAX_ENDPOINT_BYTES = 200;
    bytes32 public constant RELAY_CONSENT_TYPEHASH = keccak256('RelayConsent(address relay,address owner,uint256 nonce)');

    /// @dev Keyed by relayer address. A record exists exactly while `owner != 0`, which is also while `listed`.
    mapping(address => Relay) private _relays;
    /// @dev Sticky per-address flag for relayers and owners alike; survives exit until `resume`.
    mapping(address => bool) public suspended;
    address[] private _list;
    /// @dev Per relayer key; each consent signature is good for one listing or rotation.
    mapping(address => uint256) public nonces;

    event RelayRegistered(address indexed relay, address indexed owner, uint128 stake, string endpoint);
    event StakeAdded(address indexed relay, uint128 amount, uint128 stake);
    event EndpointUpdated(address indexed relay, string endpoint);
    event UnbondStarted(address indexed relay, uint128 amount, uint128 stake, uint64 availableAt);
    event Withdrawn(address indexed relay, address indexed owner, uint128 amount);
    event RelayerRotated(address indexed previousRelay, address indexed relay, address indexed owner);
    event ConsentCancelled(address indexed relay, uint256 nonce);
    event OwnershipOffered(address indexed relay, address indexed owner, address indexed pendingOwner);
    event OwnerSet(address indexed relay, address indexed previousOwner, address indexed owner);
    event Suspended(address indexed account, bytes32 indexed reason);
    event Resumed(address indexed account);
    event RelayRemoved(address indexed relay);
    /// @dev Emitted on every change of a relayer's active flag; indexers replay only this.
    event RelayStatus(address indexed relay, bool active);

    error ZeroAddress();
    error InvalidParameters();
    error InvalidAmount();
    error BelowMinimumStake();
    error EndpointInvalid();
    error AlreadyRegistered();
    error NotRelay();
    error NotOwner();
    error UnbondPending();
    error NothingToWithdraw();
    error UnbondNotReady();
    error NotGuardian();
    error AlreadySuspended();
    error NotSuspended();
    error RelaySuspended();
    error InvalidConsent();
    error OwnerIsRelay();

    constructor(address stakeToken, uint128 minStake, uint64 unbondingSeconds, address guardian) EIP712('Lincoln Relay Stake Registry', '2') {
        if (stakeToken == address(0) || guardian == address(0)) revert ZeroAddress();
        if (minStake == 0 || unbondingSeconds == 0 || unbondingSeconds > 90 days) revert InvalidParameters();
        STAKE_TOKEN = IERC20(stakeToken);
        MIN_STAKE = minStake;
        UNBONDING_SECONDS = unbondingSeconds;
        GUARDIAN = guardian;
    }

    modifier onlyOwnerOf(address relay) {
        Relay storage r = _relays[relay];
        if (!r.listed) revert NotRelay();
        if (msg.sender != r.owner) revert NotOwner();
        _;
    }

    // ---------------------------------------------------------------- views

    function isActive(address relay) public view returns (bool) {
        Relay storage r = _relays[relay];
        return r.listed && !suspended[relay] && r.stake >= MIN_STAKE;
    }

    /// @notice Same eight fields as V1, keyed by the relayer (processor) address.
    function relayInfo(address relay) external view returns (
        bool listed, bool active, bool isSuspended, uint128 stake, uint128 unbonding, uint64 unbondAvailableAt, uint64 registeredAt, string memory endpoint
    ) {
        Relay storage r = _relays[relay];
        return (r.listed, isActive(relay), suspended[relay], r.stake, r.unbonding, r.unbondAvailableAt, r.registeredAt, r.endpoint);
    }

    function relayOwner(address relay) external view returns (address) { return _relays[relay].owner; }
    function pendingOwner(address relay) external view returns (address) { return _relays[relay].pendingOwner; }

    /// @notice The EIP-712 digest `relay` signs to consent to being listed (or rotated onto) under `owner`.
    function consentDigest(address relay, address owner) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(RELAY_CONSENT_TYPEHASH, relay, owner, nonces[relay])));
    }
    function relayCount() external view returns (uint256) { return _list.length; }
    function relayAt(uint256 index) external view returns (address) { return _list[index]; }

    /// @notice Every listed relayer whose stake currently meets MIN_STAKE and is not suspended.
    function activeRelays() external view returns (address[] memory relays) {
        uint256 n;
        for (uint256 i = 0; i < _list.length; i++) if (isActive(_list[i])) n++;
        relays = new address[](n);
        uint256 j;
        for (uint256 i = 0; i < _list.length; i++) if (isActive(_list[i])) relays[j++] = _list[i];
    }

    // ------------------------------------------------------------ owner

    /// @notice List `relay` (the relay's signing key) with a stake paid and owned by the caller. `consent` is the
    ///         relay key's signature over `consentDigest(relay, msg.sender)`.
    function register(address relay, string calldata endpoint, uint128 amount, bytes calldata consent) external nonReentrant {
        if (relay == address(0)) revert ZeroAddress();
        if (relay == msg.sender) revert OwnerIsRelay();
        Relay storage r = _relays[relay];
        if (r.owner != address(0)) revert AlreadyRegistered();
        if (suspended[relay] || suspended[msg.sender]) revert RelaySuspended();
        if (amount < MIN_STAKE) revert BelowMinimumStake();
        _checkEndpoint(endpoint);
        _consume(relay, msg.sender, consent);
        r.owner = msg.sender;
        r.stake = amount;
        r.registeredAt = uint64(block.timestamp);
        r.index = uint32(_list.length);
        r.listed = true;
        r.endpoint = endpoint;
        _list.push(relay);
        STAKE_TOKEN.safeTransferFrom(msg.sender, address(this), amount);
        emit RelayRegistered(relay, msg.sender, amount, endpoint);
        emit RelayStatus(relay, true);
    }

    function addStake(address relay, uint128 amount) external nonReentrant onlyOwnerOf(relay) {
        Relay storage r = _relays[relay];
        if (amount == 0) revert InvalidAmount();
        // A listed relay is either fully exiting (stake 0) or holds at least MIN_STAKE.
        if (r.stake + amount < MIN_STAKE) revert BelowMinimumStake();
        bool wasActive = isActive(relay);
        r.stake += amount;
        STAKE_TOKEN.safeTransferFrom(msg.sender, address(this), amount);
        emit StakeAdded(relay, amount, r.stake);
        if (!wasActive && isActive(relay)) emit RelayStatus(relay, true);
    }

    function setEndpoint(address relay, string calldata endpoint) external nonReentrant onlyOwnerOf(relay) {
        _checkEndpoint(endpoint);
        _relays[relay].endpoint = endpoint;
        emit EndpointUpdated(relay, endpoint);
    }

    /// @notice Move the listing, stake and any pending unbond to a new signing key, e.g. after a server compromise.
    /// @dev The new key must have no record and neither key nor the owner may be suspended, so rotation can never
    ///      shed a suspension or merge into another listing.
    function rotateRelayer(address relay, address newRelay, bytes calldata consent) external nonReentrant onlyOwnerOf(relay) {
        if (newRelay == address(0)) revert ZeroAddress();
        if (newRelay == msg.sender) revert OwnerIsRelay();
        if (newRelay == relay || _relays[newRelay].owner != address(0)) revert AlreadyRegistered();
        if (suspended[relay] || suspended[newRelay] || suspended[msg.sender]) revert RelaySuspended();
        _consume(newRelay, msg.sender, consent);
        bool wasActive = isActive(relay);
        Relay memory moved = _relays[relay];
        _relays[newRelay] = moved;
        _list[moved.index] = newRelay;
        delete _relays[relay];
        emit RelayerRotated(relay, newRelay, msg.sender);
        if (wasActive) emit RelayStatus(relay, false);
        if (isActive(newRelay)) emit RelayStatus(newRelay, true);
    }

    /// @notice Offer the listing (stake, pending unbond, withdrawal rights) to another owner, e.g. a Safe. It takes
    ///         over only when it calls `acceptOwnership`, so a mistyped address strands nothing. Zero cancels an offer.
    /// @dev A suspended owner cannot hand over, so a transfer can never shed an owner suspension.
    function transferOwnership(address relay, address newOwner) external nonReentrant onlyOwnerOf(relay) {
        if (newOwner == relay) revert OwnerIsRelay();
        // Cancelling (zero) is always allowed; offering is not while either side is suspended.
        if (newOwner != address(0) && (suspended[newOwner] || suspended[msg.sender])) revert RelaySuspended();
        _relays[relay].pendingOwner = newOwner;
        emit OwnershipOffered(relay, msg.sender, newOwner);
    }

    function acceptOwnership(address relay) external nonReentrant {
        Relay storage r = _relays[relay];
        if (!r.listed) revert NotRelay();
        if (msg.sender != r.pendingOwner || msg.sender == address(0)) revert NotOwner();
        if (msg.sender == relay) revert OwnerIsRelay(); // offered before a rotation onto the pending owner
        if (suspended[msg.sender] || suspended[r.owner]) revert RelaySuspended();
        emit OwnerSet(relay, r.owner, msg.sender);
        r.owner = msg.sender;
        r.pendingOwner = address(0);
    }

    /// @notice Move `amount` of active stake into the unbonding queue. One pending unbond at a time.
    function beginUnbond(address relay, uint128 amount) external nonReentrant onlyOwnerOf(relay) {
        Relay storage r = _relays[relay];
        if (r.unbonding != 0) revert UnbondPending();
        if (amount == 0 || amount > r.stake) revert InvalidAmount();
        // No dust listings: unbond everything, or keep at least MIN_STAKE active.
        if (r.stake - amount != 0 && r.stake - amount < MIN_STAKE) revert BelowMinimumStake();
        bool wasActive = isActive(relay);
        r.stake -= amount;
        r.unbonding = amount;
        r.unbondAvailableAt = uint64(block.timestamp) + UNBONDING_SECONDS;
        emit UnbondStarted(relay, amount, r.stake, r.unbondAvailableAt);
        if (wasActive && !isActive(relay)) emit RelayStatus(relay, false);
    }

    /// @notice Pay a matured unbond to the owner. A relay with no stake left is removed.
    function withdraw(address relay) external nonReentrant onlyOwnerOf(relay) {
        Relay storage r = _relays[relay];
        uint128 amount = r.unbonding;
        if (amount == 0) revert NothingToWithdraw();
        if (block.timestamp < r.unbondAvailableAt) revert UnbondNotReady();
        address owner = r.owner;
        r.unbonding = 0;
        r.unbondAvailableAt = 0;
        if (r.stake == 0) _remove(relay);
        STAKE_TOKEN.safeTransfer(owner, amount);
        emit Withdrawn(relay, owner, amount);
    }

    /// @notice Called by a relay key to void every consent it has signed and not yet had used.
    function cancelConsent() external {
        emit ConsentCancelled(msg.sender, nonces[msg.sender]++);
    }

    // ------------------------------------------------------------ guardian

    /// @notice Suspend a relayer (it leaves the active set) or an owner (it cannot register or rotate to new
    ///         relayers). Sticky per address; stake is never touched.
    function suspend(address account, bytes32 reason) external nonReentrant {
        if (msg.sender != GUARDIAN) revert NotGuardian();
        if (account == address(0)) revert ZeroAddress();
        if (suspended[account]) revert AlreadySuspended();
        bool wasActive = isActive(account);
        suspended[account] = true;
        emit Suspended(account, reason);
        if (wasActive) emit RelayStatus(account, false);
    }

    function resume(address account) external nonReentrant {
        if (msg.sender != GUARDIAN) revert NotGuardian();
        if (!suspended[account]) revert NotSuspended();
        suspended[account] = false;
        emit Resumed(account);
        if (isActive(account)) emit RelayStatus(account, true);
    }

    // ------------------------------------------------------------ internal

    function _consume(address relay, address owner, bytes calldata consent) private {
        (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(consentDigest(relay, owner), consent);
        if (err != ECDSA.RecoverError.NoError || signer != relay) revert InvalidConsent();
        nonces[relay]++;
    }

    function _checkEndpoint(string calldata endpoint) private pure {
        bytes calldata b = bytes(endpoint);
        if (b.length < 9 || b.length > MAX_ENDPOINT_BYTES) revert EndpointInvalid();
        if (b[0] != 'h' || b[1] != 't' || b[2] != 't' || b[3] != 'p' || b[4] != 's' || b[5] != ':' || b[6] != '/' || b[7] != '/') revert EndpointInvalid();
        for (uint256 i = 0; i < b.length; i++) {
            bytes1 c = b[i];
            if (c < 0x21 || c > 0x7e) revert EndpointInvalid(); // printable ASCII, no spaces
            // No quoting or markup bytes: endpoints are rendered by dashboards and embedded in JSON.
            if (c == '"' || c == 0x27 || c == '<' || c == '>' || c == '`' || c == 0x5c) revert EndpointInvalid();
        }
    }

    function _remove(address relay) private {
        Relay storage r = _relays[relay];
        uint256 last = _list.length - 1;
        if (r.index != last) {
            address moved = _list[last];
            _list[r.index] = moved;
            _relays[moved].index = r.index;
        }
        _list.pop();
        delete _relays[relay];
        emit RelayRemoved(relay);
    }
}
