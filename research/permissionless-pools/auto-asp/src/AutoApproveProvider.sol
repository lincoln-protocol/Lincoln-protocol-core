// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {PoseidonT3} from 'poseidon-solidity/PoseidonT3.sol';
import {Phase2ASPRegistry} from 'rc3/Phase2ASPRegistry.sol';
// Compiled alongside so the fork run deploys the unchanged RC.3 pool and fee adapter.
import {Phase2ASPPool} from 'rc3/Phase2ASPPool.sol';
import {Phase2FeeRouter02Adapter} from 'rc3-fees/Phase2FeeRouteAdapter.sol';
import {ScreeningList} from './ScreeningList.sol';

interface IScreenedPool {
    function ASP_REGISTRY() external view returns (address);
    function SCOPE() external view returns (uint256);
    function commitments(uint256 commitment) external view returns (bool);
    function originalDepositor(uint256 commitment) external view returns (address);
}

/// @notice Research only. The single ASP provider of its own registry: it approves the bound
/// pool's notes by rule, so no operator publishes association sets, while the guardian Safe
/// keeps the exclusion lever through a ScreeningList.
/// @dev The RC.3 pool, registry and join-split circuit stay unchanged: the circuit still checks
/// H(commitment, SCOPE) against the registry root; this contract builds that tree on chain.
/// Rules, applied when anyone calls sync:
/// - excluded commitments are withheld;
/// - notes made by a spend (no original depositor) or deposited by a trusted route adapter
///   come from approved notes and are approved at once;
/// - any other deposit waits SCREENING_DELAY from when sync first saw it, then is approved
///   unless its depositor was denied in the meantime.
/// The registry guardian (the Safe) can still suspend this provider, which halts normal
/// spending but never holder exits or ragequits.
contract AutoApproveProvider {
    uint256 public constant TREE_DEPTH = 20;
    uint64 public constant POLICY_LIFETIME = 30 days;

    uint8 public constant WITHHELD_EXCLUDED = 1;
    uint8 public constant WITHHELD_DENIED = 2;
    uint8 public constant WITHHELD_WAITING = 3;

    Phase2ASPRegistry public immutable REGISTRY;
    ScreeningList public immutable SCREENING;
    uint64 public immutable SCREENING_DELAY;
    address public immutable BINDER;
    IScreenedPool public pool;
    uint256 public scope;

    uint256 public root;
    uint256 public nextIndex;
    uint256[TREE_DEPTH] public zeros;
    uint256[TREE_DEPTH] public filledSubtrees;
    mapping(uint256 => bool) public approved;
    mapping(uint256 => uint64) public firstSeen;

    error AlreadyBound();
    error NotBinder();
    error WrongRegistry();
    error Unbound();
    error UnknownCommitment();
    error TreeFull();
    error InvalidScreening();

    event DepositSeen(uint256 indexed commitment, address indexed depositor, uint64 approvableAt);
    event LeafApproved(uint256 indexed commitment, uint256 leaf, uint256 index);
    event ApprovalWithheld(uint256 indexed commitment, uint8 reason);

    constructor(address guardian, address screening, uint64 screeningDelay) {
        if (screening.code.length == 0) revert InvalidScreening();
        REGISTRY = new Phase2ASPRegistry(address(this), guardian);
        SCREENING = ScreeningList(screening);
        SCREENING_DELAY = screeningDelay;
        BINDER = msg.sender;
        uint256 zero;
        for (uint256 level; level < TREE_DEPTH; level++) {
            zeros[level] = zero;
            filledSubtrees[level] = zero;
            zero = PoseidonT3.hash([zero, zero]);
        }
        root = zero;
    }

    function bind(address target) external {
        if (msg.sender != BINDER) revert NotBinder();
        if (address(pool) != address(0)) revert AlreadyBound();
        if (IScreenedPool(target).ASP_REGISTRY() != address(REGISTRY)) revert WrongRegistry();
        pool = IScreenedPool(target);
        scope = IScreenedPool(target).SCOPE();
        _publish();
    }

    /// @notice Apply the rules to pool commitments and publish a new root if any was approved.
    /// Anyone may call it; already approved commitments are skipped.
    function sync(uint256[] calldata candidates) external returns (uint256 added) {
        if (address(pool) == address(0)) revert Unbound();
        for (uint256 i; i < candidates.length; i++) {
            uint256 commitment = candidates[i];
            if (approved[commitment]) continue;
            if (!pool.commitments(commitment)) revert UnknownCommitment();
            uint8 withheld = _withheld(commitment);
            if (withheld != 0) {
                emit ApprovalWithheld(commitment, withheld);
                continue;
            }
            approved[commitment] = true;
            _insert(commitment, PoseidonT3.hash([commitment, scope]));
            added++;
        }
        if (added != 0) _publish();
    }

    /// @notice Republish the current root before the policy expires.
    function refresh() external {
        if (address(pool) == address(0)) revert Unbound();
        _publish();
    }

    function _withheld(uint256 commitment) internal returns (uint8) {
        if (SCREENING.isExcluded(commitment)) return WITHHELD_EXCLUDED;
        address depositor = pool.originalDepositor(commitment);
        if (depositor == address(0) || SCREENING.isTrustedDepositor(depositor)) return 0;
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
        // The digest only has to be nonzero; clients rebuild leaves from LeafApproved.
        REGISTRY.updateRoot(root, bytes32(root), uint64(block.timestamp) + POLICY_LIFETIME);
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
        root = node;
        emit LeafApproved(commitment, leaf, index);
    }
}
