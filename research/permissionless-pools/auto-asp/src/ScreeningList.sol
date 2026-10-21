// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

/// @notice Research only. The exclusion side of automatic approval: the guardian Safe can
/// deny depositor addresses (sanctions lists, known exploit proceeds) and exclude single
/// commitments. Providers withhold approval from both. Funds are never frozen: a denied
/// depositor can still ragequit to its own address, and holder exits never consult this list.
/// @dev Trusted depositors are the route adapters whose deposits come from an already approved
/// note. In the planned factory the factory itself marks the adapters it deploys; here the
/// admin stands in for it.
contract ScreeningList {
    address public immutable ADMIN;

    mapping(address => bool) public isDenied;
    mapping(uint256 => bool) public isExcluded;
    mapping(address => bool) public isTrustedDepositor;

    error OnlyAdmin();
    error InvalidAdmin();

    event DepositorDenied(address indexed depositor, bool denied);
    event CommitmentExcluded(uint256 indexed commitment, bool excluded);
    event TrustedDepositorSet(address indexed depositor, bool trusted);

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

    function setTrustedDepositor(address depositor, bool trusted) external onlyAdmin {
        isTrustedDepositor[depositor] = trusted;
        emit TrustedDepositorSet(depositor, trusted);
    }
}
