// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {PoseidonT3} from 'poseidon-solidity/PoseidonT3.sol';
import {Phase2ASPRegistry} from 'rc3/Phase2ASPRegistry.sol';
import {ScreeningList} from './ScreeningList.sol';

interface IScreenedPool {
    function ASP_REGISTRY() external view returns (address);
    function SCOPE() external view returns (uint256);
    function commitments(uint256 commitment) external view returns (bool);
    function originalDepositor(uint256 commitment) external view returns (address);
}

/// @notice Research only. The single ASP provider of its own registry: it approves the bound
/// pool's notes by rule, so no operator publishes association sets, while the guardian Safe
/// keeps the exclusion lever through the shared ScreeningList.
/// @dev The RC.3 pool, registry and join-split circuit stay unchanged: the circuit still checks
/// H(commitment, SCOPE) against the registry root; this contract builds that tree on chain.
/// Rules, applied when anyone calls sync:
/// - excluded commitments are withheld;
/// - notes made by a spend (no original depositor) come from approved notes and are approved at once;
/// - every deposit, including a route adapter's, waits SCREENING_DELAY from when sync first saw it,
///   then is approved unless its depositor was denied in the meantime. Adapter deposits are not
///   trusted at once: their value comes from whatever venue the route trades through, which anyone
///   can create (audit 2026-10-21, F-1). The Safe can exclude the commitment, or deny the adapter.
/// Approved leaves are published as a new registry policy at most once per MIN_PUBLISH_INTERVAL, so
/// sixteen epochs take longer than the registry's one-hour grace and no caller can push in-flight
/// proofs out of the accepted window (audit F-2). Clients prove against the first
/// publishedLeafCount leaves. The registry guardian (the Safe) can still suspend this provider,
/// which halts normal spending but never holder exits or ragequits.
contract AutoApproveProvider {
    uint256 public constant TREE_DEPTH = 20;
    uint64 public constant POLICY_LIFETIME = 30 days;
    /// @dev >= 1 hour / ACCEPTED_POLICY_WINDOW (16) = 225 s.
    uint64 public constant MIN_PUBLISH_INTERVAL = 4 minutes;
    /// @dev Within this margin of expiry the unchanged root may be republished.
    uint64 public constant RENEW_MARGIN = 1 days;
    uint64 public constant MIN_SCREENING_DELAY = 10 minutes;

    uint8 public constant WITHHELD_EXCLUDED = 1;
    uint8 public constant WITHHELD_DENIED = 2;
    uint8 public constant WITHHELD_WAITING = 3;

    Phase2ASPRegistry public immutable REGISTRY;
    ScreeningList public immutable SCREENING;
    uint64 public immutable SCREENING_DELAY;
    /// @dev The factory: the only address that may bind.
    address public immutable BINDER;
    IScreenedPool public pool;
    uint256 public scope;

    uint256 public root;
    uint256 public nextIndex;
    uint256[TREE_DEPTH] public zeros;
    uint256[TREE_DEPTH] public filledSubtrees;
    /// @dev Leaf index + 1 for approved commitments, 0 otherwise.
    mapping(uint256 => uint256) public leafIndexPlusOne;
    mapping(uint256 => uint64) public firstSeen;

    uint256 public publishedLeafCount;
    uint64 public lastPublishedAt;
    uint64 public policyValidUntil;

    error AlreadyBound();
    error NotBinder();
    error WrongRegistry();
    error Unbound();
    error UnknownCommitment();
    error TreeFull();
    error InvalidScreening();
    error InvalidBinder();

    event DepositSeen(uint256 indexed commitment, address indexed depositor, uint64 approvableAt);
    event LeafApproved(uint256 indexed commitment, uint256 leaf, uint256 index);
    event ApprovalWithheld(uint256 indexed commitment, uint8 reason);
    /// @notice A registry policy over the first `leafCount` approved leaves.
    event PolicyPublished(uint256 indexed root, uint256 leafCount, uint64 validUntil);

    constructor(address guardian, address screening, uint64 screeningDelay, address binder) {
        if (screening.code.length == 0 || screeningDelay < MIN_SCREENING_DELAY) revert InvalidScreening();
        if (binder == address(0)) revert InvalidBinder();
        REGISTRY = new Phase2ASPRegistry(address(this), guardian);
        SCREENING = ScreeningList(screening);
        SCREENING_DELAY = screeningDelay;
        BINDER = binder;
        uint256 zero;
        for (uint256 level; level < TREE_DEPTH; level++) {
            zeros[level] = zero;
            filledSubtrees[level] = zero;
            zero = PoseidonT3.hash([zero, zero]);
        }
        root = zero;
    }

    function approved(uint256 commitment) external view returns (bool) {
        return leafIndexPlusOne[commitment] != 0;
    }

    /// @notice Approved and inside the published policy, so a proof can use it now.
    function usable(uint256 commitment) external view returns (bool) {
        uint256 indexPlusOne = leafIndexPlusOne[commitment];
        return indexPlusOne != 0 && indexPlusOne <= publishedLeafCount;
    }

    /// @notice Whether publish() would publish now.
    function canPublish() public view returns (bool) {
        if (address(pool) == address(0) || block.timestamp < uint256(lastPublishedAt) + MIN_PUBLISH_INTERVAL) return false;
        return nextIndex != publishedLeafCount || block.timestamp + RENEW_MARGIN >= policyValidUntil;
    }

    function bind(address target) external {
        if (msg.sender != BINDER) revert NotBinder();
        if (address(pool) != address(0)) revert AlreadyBound();
        if (IScreenedPool(target).ASP_REGISTRY() != address(REGISTRY)) revert WrongRegistry();
        pool = IScreenedPool(target);
        scope = IScreenedPool(target).SCOPE();
        _publish();
    }

    /// @notice Apply the rules to pool commitments, then publish if the interval allows.
    /// Anyone may call it; already approved commitments are skipped.
    function sync(uint256[] calldata candidates) external returns (uint256 added) {
        if (address(pool) == address(0)) revert Unbound();
        for (uint256 i; i < candidates.length; i++) {
            uint256 commitment = candidates[i];
            if (leafIndexPlusOne[commitment] != 0) continue;
            if (!pool.commitments(commitment)) revert UnknownCommitment();
            uint8 withheld = _withheld(commitment);
            if (withheld != 0) {
                emit ApprovalWithheld(commitment, withheld);
                continue;
            }
            _insert(commitment, PoseidonT3.hash([commitment, scope]));
            added++;
        }
        if (canPublish()) _publish();
    }

    /// @notice Publish pending leaves, or renew the policy near expiry. Rate-limited for everyone.
    function publish() external returns (bool published) {
        if (address(pool) == address(0)) revert Unbound();
        published = canPublish();
        if (published) _publish();
    }

    function _withheld(uint256 commitment) internal returns (uint8) {
        if (SCREENING.isExcluded(commitment)) return WITHHELD_EXCLUDED;
        address depositor = pool.originalDepositor(commitment);
        if (depositor == address(0)) return 0;
        uint64 seen = firstSeen[commitment];
        if (seen == 0) {
            seen = uint64(block.timestamp);
            firstSeen[commitment] = seen;
            emit DepositSeen(commitment, depositor, seen + SCREENING_DELAY);
        }
        if (block.timestamp < uint256(seen) + SCREENING_DELAY) return WITHHELD_WAITING;
        if (SCREENING.isDenied(depositor)) return WITHHELD_DENIED;
        return 0;
    }

    function _publish() internal {
        uint64 validUntil = uint64(block.timestamp) + POLICY_LIFETIME;
        publishedLeafCount = nextIndex;
        lastPublishedAt = uint64(block.timestamp);
        policyValidUntil = validUntil;
        // The digest only has to be nonzero; clients rebuild leaves from LeafApproved.
        REGISTRY.updateRoot(root, bytes32(root), validUntil);
        emit PolicyPublished(root, nextIndex, validUntil);
    }

    function _insert(uint256 commitment, uint256 leaf) internal {
        uint256 index = nextIndex;
        if (index >= 1 << TREE_DEPTH) revert TreeFull();
        uint256 node = leaf;
        uint256 cursor = index;
        for (uint256 level; level < TREE_DEPTH; level++) {
            if (cursor & 1 == 0) {
                filledSubtrees[level] = node;
                node = PoseidonT3.hash([node, zeros[level]]);
            } else {
                node = PoseidonT3.hash([filledSubtrees[level], node]);
            }
            cursor >>= 1;
        }
        nextIndex = index + 1;
        leafIndexPlusOne[commitment] = index + 1;
        root = node;
        emit LeafApproved(commitment, leaf, index);
    }
}
