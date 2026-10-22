// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {ReentrancyGuard} from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';

/// @title RelayStakeRegistry
/// @notice Permissionless registry of relay operators backed by a LINCOLN stake.
/// @dev The privacy pools already accept any `processor`; this contract only
///      publishes who has stake at risk, so clients and the points program can
///      pick relays. It never touches pool funds, proofs or notes.
///      Trust boundary: GUARDIAN (the protocol Safe) can suspend a relay, which
///      only removes it from the active set. Stake is never confiscated: relay
///      misbehaviour is not provable on-chain, so a slash would mostly hit honest
///      operators with RPC outages. A suspended relay can still unbond and leave.
contract RelayStakeRegistry is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Relay {
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

    mapping(address => Relay) private _relays;
    /// @dev Sticky per-address flag: survives exit and blocks re-registration until `resume`.
    mapping(address => bool) public suspended;
    address[] private _list;

    event RelayRegistered(address indexed relay, uint128 stake, string endpoint);
    event StakeAdded(address indexed relay, uint128 amount, uint128 stake);
    event EndpointUpdated(address indexed relay, string endpoint);
    event UnbondStarted(address indexed relay, uint128 amount, uint128 stake, uint64 availableAt);
    event Withdrawn(address indexed relay, uint128 amount);
    event Suspended(address indexed relay, bytes32 indexed reason);
    event Resumed(address indexed relay);
    event RelayRemoved(address indexed relay);
    /// @dev Emitted on every change of the active flag; indexers replay only this.
    event RelayStatus(address indexed relay, bool active);

    error ZeroAddress();
    error InvalidParameters();
    error InvalidAmount();
    error BelowMinimumStake();
    error EndpointInvalid();
    error AlreadyRegistered();
    error NotRelay();
    error UnbondPending();
    error NothingToWithdraw();
    error UnbondNotReady();
    error NotGuardian();
    error AlreadySuspended();
    error NotSuspended();
    error RelaySuspended();

    constructor(address stakeToken, uint128 minStake, uint64 unbondingSeconds, address guardian) {
        if (stakeToken == address(0) || guardian == address(0)) revert ZeroAddress();
        if (minStake == 0 || unbondingSeconds == 0 || unbondingSeconds > 90 days) revert InvalidParameters();
        STAKE_TOKEN = IERC20(stakeToken);
        MIN_STAKE = minStake;
        UNBONDING_SECONDS = unbondingSeconds;
        GUARDIAN = guardian;
    }

    // ---------------------------------------------------------------- views

    function isActive(address relay) public view returns (bool) {
        Relay storage r = _relays[relay];
        return r.listed && !suspended[relay] && r.stake >= MIN_STAKE;
    }

    function relayInfo(address relay) external view returns (
        bool listed, bool active, bool isSuspended, uint128 stake, uint128 unbonding, uint64 unbondAvailableAt, uint64 registeredAt, string memory endpoint
    ) {
        Relay storage r = _relays[relay];
        return (r.listed, isActive(relay), suspended[relay], r.stake, r.unbonding, r.unbondAvailableAt, r.registeredAt, r.endpoint);
    }

    function relayCount() external view returns (uint256) { return _list.length; }
    function relayAt(uint256 index) external view returns (address) { return _list[index]; }

    /// @notice Every listed relay whose stake currently meets MIN_STAKE.
    function activeRelays() external view returns (address[] memory relays) {
        uint256 n;
        for (uint256 i = 0; i < _list.length; i++) if (isActive(_list[i])) n++;
        relays = new address[](n);
        uint256 j;
        for (uint256 i = 0; i < _list.length; i++) if (isActive(_list[i])) relays[j++] = _list[i];
    }

    // ------------------------------------------------------------ operator

    function register(string calldata endpoint, uint128 amount) external nonReentrant {
        Relay storage r = _relays[msg.sender];
        if (r.listed) revert AlreadyRegistered();
        if (suspended[msg.sender]) revert RelaySuspended();
        if (amount < MIN_STAKE) revert BelowMinimumStake();
        _checkEndpoint(endpoint);
        r.stake = amount;
        r.registeredAt = uint64(block.timestamp);
        r.index = uint32(_list.length);
        r.listed = true;
        r.endpoint = endpoint;
        _list.push(msg.sender);
        STAKE_TOKEN.safeTransferFrom(msg.sender, address(this), amount);
        emit RelayRegistered(msg.sender, amount, endpoint);
        emit RelayStatus(msg.sender, true);
    }

    function addStake(uint128 amount) external nonReentrant {
        Relay storage r = _relays[msg.sender];
        if (!r.listed) revert NotRelay();
        if (amount == 0) revert InvalidAmount();
        // A listed relay is either fully exiting (stake 0) or holds at least MIN_STAKE.
        if (r.stake + amount < MIN_STAKE) revert BelowMinimumStake();
        bool wasActive = isActive(msg.sender);
        r.stake += amount;
        STAKE_TOKEN.safeTransferFrom(msg.sender, address(this), amount);
        emit StakeAdded(msg.sender, amount, r.stake);
        if (!wasActive && isActive(msg.sender)) emit RelayStatus(msg.sender, true);
    }

    function setEndpoint(string calldata endpoint) external {
        Relay storage r = _relays[msg.sender];
        if (!r.listed) revert NotRelay();
        _checkEndpoint(endpoint);
        r.endpoint = endpoint;
        emit EndpointUpdated(msg.sender, endpoint);
    }

    /// @notice Move `amount` of active stake into the unbonding queue. One
    ///         pending unbond at a time; withdraw it before starting another.
    function beginUnbond(uint128 amount) external {
        Relay storage r = _relays[msg.sender];
        if (!r.listed) revert NotRelay();
        if (r.unbonding != 0) revert UnbondPending();
        if (amount == 0 || amount > r.stake) revert InvalidAmount();
        // No dust listings: unbond everything, or keep at least MIN_STAKE active.
        if (r.stake - amount != 0 && r.stake - amount < MIN_STAKE) revert BelowMinimumStake();
        bool wasActive = isActive(msg.sender);
        r.stake -= amount;
        r.unbonding = amount;
        r.unbondAvailableAt = uint64(block.timestamp) + UNBONDING_SECONDS;
        emit UnbondStarted(msg.sender, amount, r.stake, r.unbondAvailableAt);
        if (wasActive && !isActive(msg.sender)) emit RelayStatus(msg.sender, false);
    }

    function withdraw() external nonReentrant {
        Relay storage r = _relays[msg.sender];
        if (!r.listed) revert NotRelay();
        uint128 amount = r.unbonding;
        if (amount == 0) revert NothingToWithdraw();
        if (block.timestamp < r.unbondAvailableAt) revert UnbondNotReady();
        r.unbonding = 0;
        r.unbondAvailableAt = 0;
        if (r.stake == 0) _remove(msg.sender);
        STAKE_TOKEN.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    // ------------------------------------------------------------ guardian

    /// @notice Governance suspension: the relay leaves the active set and stops
    ///         earning relay points. Its stake stays its own; it may unbond and leave.
    ///         The flag is per address and sticky: it survives exit and blocks
    ///         re-registration, and may be set ahead of time on an unlisted address.
    function suspend(address relay, bytes32 reason) external {
        if (msg.sender != GUARDIAN) revert NotGuardian();
        if (relay == address(0)) revert ZeroAddress();
        if (suspended[relay]) revert AlreadySuspended();
        bool wasActive = isActive(relay);
        suspended[relay] = true;
        emit Suspended(relay, reason);
        if (wasActive) emit RelayStatus(relay, false);
    }

    function resume(address relay) external {
        if (msg.sender != GUARDIAN) revert NotGuardian();
        if (!suspended[relay]) revert NotSuspended();
        suspended[relay] = false;
        emit Resumed(relay);
        if (isActive(relay)) emit RelayStatus(relay, true);
    }

    // ------------------------------------------------------------ internal

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
