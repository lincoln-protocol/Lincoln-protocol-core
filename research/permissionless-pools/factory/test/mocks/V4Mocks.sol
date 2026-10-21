// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

interface IV4UnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

contract V4MockToken is ERC20 {
    constructor(string memory name) ERC20(name, name) {}
    function mint(address receiver, uint256 amount) external { _mint(receiver, amount); }
}

/// @dev Burns 1% (at least 1 wei) of transfers sent to `taxedTo` or sent from `taxedFrom`.
contract V4TaxToken is ERC20 {
    address public taxedTo;
    address public taxedFrom;
    constructor() ERC20('TAX', 'TAX') {}
    function mint(address receiver, uint256 amount) external { _mint(receiver, amount); }
    function setTaxed(address to, address from) external { taxedTo = to; taxedFrom = from; }
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && value != 0 && (to == taxedTo || from == taxedFrom)) {
            uint256 tax = value / 100 == 0 ? 1 : value / 100;
            super._update(from, address(0), tax);
            value -= tax;
        }
        super._update(from, to, value);
    }
}

/// @dev Has no receive/fallback: native transfers to it fail.
contract V4NoReceive {}

/// @notice Minimal Uniswap v4 PoolManager stand-in: unlock/callback, signed caller deltas,
/// sync/settle/take, extsload of slot0, and an end-of-unlock "all deltas settled" check.
/// Injectable misbehaviour tests the adapter's own checks; it never enforces a price or minimum.
contract MockV4PoolManager {
    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }
    struct SwapParams {
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
    }

    uint8 public constant HONEST = 0;
    uint8 public constant PARTIAL = 1;       // spends amountIn - 1
    uint8 public constant OVERSPEND = 2;     // charges amountIn + 1
    uint8 public constant DONATE = 3;        // a "hook" sends 1 extra output unit to the caller mid-swap
    uint8 public constant NESTED = 4;        // re-invokes the caller's unlockCallback mid-swap
    uint8 public constant ZERO_OUT = 5;      // output delta 0
    uint8 public constant SHORT_SETTLE = 6;  // settle() reports 1 less than received
    uint8 public constant TAMPER = 7;        // passes a modified payload to the callback
    uint8 public constant WRONG_SIGN = 8;    // input delta positive (pool pays the caller)

    error AlreadyUnlocked();
    error ManagerLocked();
    error CurrencyNotSettled();

    mapping(bytes32 => bytes32) public slots;
    mapping(address => mapping(address => int256)) public deltas;
    bool public unlocked;
    uint8 public mode;
    uint256 public rate = 1e18;
    address internal synced;
    uint256 internal syncedReserves;
    address internal lastC0;
    address internal lastC1;
    bytes internal lastPayload;

    bool public lastZeroForOne;
    uint160 public lastLimit;
    int256 public lastAmountSpecified;
    uint256 public lastHookDataLength;
    bytes32 public lastPoolId;
    uint256 public swaps;

    receive() external payable {}

    function configure(uint8 nextMode, uint256 nextRate) external { mode = nextMode; rate = nextRate; }

    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external {
        slots[keccak256(abi.encodePacked(keccak256(abi.encode(key)), uint256(6)))] = bytes32(uint256(sqrtPriceX96));
    }

    function extsload(bytes32 slot) external view returns (bytes32) { return slots[slot]; }

    /// @dev Calls a callback as the manager while nothing is armed.
    function poke(address target, bytes calldata data) external returns (bytes memory) {
        return IV4UnlockCallback(target).unlockCallback(data);
    }

    function unlock(bytes calldata data) external returns (bytes memory result) {
        if (unlocked) revert AlreadyUnlocked();
        unlocked = true;
        lastPayload = data;
        bytes memory forwarded = data;
        if (mode == TAMPER) forwarded[forwarded.length - 1] ^= 0x01;
        result = IV4UnlockCallback(msg.sender).unlockCallback(forwarded);
        if (deltas[msg.sender][lastC0] != 0 || deltas[msg.sender][lastC1] != 0) revert CurrencyNotSettled();
        unlocked = false;
    }

    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData) external returns (int256 delta) {
        if (!unlocked) revert ManagerLocked();
        swaps++;
        lastC0 = key.currency0; lastC1 = key.currency1;
        lastZeroForOne = params.zeroForOne; lastLimit = params.sqrtPriceLimitX96;
        lastAmountSpecified = params.amountSpecified; lastHookDataLength = hookData.length;
        lastPoolId = keccak256(abi.encode(key));
        require(params.amountSpecified < 0, 'exact input only');
        uint256 amountIn = uint256(-params.amountSpecified);
        uint256 spent = mode == PARTIAL ? amountIn - 1 : mode == OVERSPEND ? amountIn + 1 : amountIn;
        uint256 out = mode == ZERO_OUT ? 0 : spent * rate / 1e18;
        int128 inDelta = mode == WRONG_SIGN ? int128(int256(spent)) : -int128(int256(spent));
        int128 outDelta = int128(int256(out));
        (address input, address output) = params.zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        deltas[msg.sender][input] += inDelta;
        deltas[msg.sender][output] += outDelta;
        (int128 a0, int128 a1) = params.zeroForOne ? (inDelta, outDelta) : (outDelta, inDelta);
        assembly ('memory-safe') { delta := or(shl(128, a0), and(sub(shl(128, 1), 1), a1)) }
        if (mode == DONATE) _send(output, msg.sender, 1);
        if (mode == NESTED) IV4UnlockCallback(msg.sender).unlockCallback(lastPayload);
    }

    function sync(address currency) external {
        synced = currency;
        syncedReserves = currency == address(0) ? 0 : IERC20(currency).balanceOf(address(this));
    }

    function settle() external payable returns (uint256 paid) {
        address currency = synced;
        if (currency == address(0)) {
            paid = msg.value;
        } else {
            require(msg.value == 0, 'native with token');
            paid = IERC20(currency).balanceOf(address(this)) - syncedReserves;
        }
        synced = address(0);
        deltas[msg.sender][currency] += int256(paid);
        if (mode == SHORT_SETTLE && paid != 0) paid -= 1;
    }

    function take(address currency, address to, uint256 amount) external {
        deltas[msg.sender][currency] -= int256(amount);
        _send(currency, to, amount);
    }

    function _send(address currency, address to, uint256 amount) internal {
        if (currency == address(0)) {
            (bool ok,) = to.call{value: amount}('');
            require(ok, 'native send');
        } else {
            IERC20(currency).transfer(to, amount);
        }
    }
}
