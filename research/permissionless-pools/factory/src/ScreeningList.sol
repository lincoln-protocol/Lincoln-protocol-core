// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

/// @notice Research only. The exclusion lever shared by every factory pool: the guardian Safe
/// can deny depositor addresses (sanctions lists, known exploit proceeds) and exclude single
/// commitments, and providers withhold approval from both. Nothing is frozen: a withheld
/// deposit can still ragequit to its own depositor, and holder exits never consult this list.
contract ScreeningList {
    address public immutable ADMIN;

    mapping(address => bool) public isDenied;
    mapping(uint256 => bool) public isExcluded;

    error OnlyAdmin();
    error InvalidAdmin();

    event DepositorDenied(address indexed depositor, bool denied);
    event CommitmentExcluded(uint256 indexed commitment, bool excluded);

    modifier onlyAdmin() {
        if (msg.sender != ADMIN) revert OnlyAdmin();
        _;
    }

    constructor(address admin) {
        if (admin == address(0)) revert InvalidAdmin();
        ADMIN = admin;
    }

    function setDenied(address[] calldata depositors, bool denied) external onlyAdmin {
        for (uint256 i; i < depositors.length; i++) {
            isDenied[depositors[i]] = denied;
            emit DepositorDenied(depositors[i], denied);
        }
    }

    function setExcluded(uint256[] calldata commitments, bool excluded) external onlyAdmin {
        for (uint256 i; i < commitments.length; i++) {
            isExcluded[commitments[i]] = excluded;
            emit CommitmentExcluded(commitments[i], excluded);
        }
    }
}
