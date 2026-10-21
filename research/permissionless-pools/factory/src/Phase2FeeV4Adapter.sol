// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {ReentrancyGuard} from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import {IERC20, SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {IPhase2RouteSourcePool, IPhase2RouteTargetPool} from 'rc3/Phase2RouteAdapter.sol';

/// @dev The subset of Uniswap v4-core's IPoolManager this adapter calls. Currency and IHooks are
/// plain addresses and BalanceDelta is an int256, so the ABI is identical to v4-core's.
interface IV4PoolManager {
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
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData) external returns (int256 delta);
    function sync(address currency) external;
    function settle() external payable returns (uint256 paid);
    function take(address currency, address to, uint256 amount) external;
    function extsload(bytes32 slot) external view returns (bytes32);
}

/// @notice Immutable exact-input fee route through ONE Uniswap v4 pool, from a Phase2 note into a
/// new note in another Phase2 pool. Deploy once per direction. Any PoolKey, including native ETH
/// (currency 0x0, which is also the ETH privacy pool's ASSET), any fee tier and any hook.
/// @dev Same Action/Proof/ExtData/envelope scheme as Phase2FeeRouteAdapter (RC.3) with a distinct
/// domain. No owner, setters, sweep, arbitrary calldata, hook data or multi-hop path. Exact-balance
/// checks make fee-on-transfer and rebasing tokens revert. Public DEX activity remains visible.
/// RESEARCH BUILD: unaudited, never deployed to a public chain.
contract Phase2FeeV4Adapter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    struct Action {
        address processor;
        uint128 amountIn;
        uint128 minAmountOut; // Minimum NET amount deposited into the target privacy pool.
        uint256 deadline;
        uint256 targetPrecommitment;
        bytes encryptedTemplate;
        uint128 maxServiceFee; // Absolute maximum fee, denominated in output base units.
    }

    struct Proof {
        uint256[2] pA;
        uint256[2][2] pB;
        uint256[2] pC;
        uint256[9] pubSignals;
    }

    struct Balances {
        uint256 nativeBalance;
        uint256 inputBalance;
        uint256 outputBalance;
        uint256 targetBalance;
        uint256 treasuryBalance;
    }

    uint256 public constant FIELD = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
    bytes32 public constant SWAP_DOMAIN = keccak256('LINCOLN_PHASE2_FEE_V4_ROUTES_V1');
    uint256 public constant CIPHERTEXT_BYTES = 256;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint16 public constant MAX_SERVICE_FEE_BPS = 100;
    /// @dev v4-core TickMath bounds; the swap uses the extreme limit for its direction.
    uint160 public constant MIN_SQRT_PRICE = 4295128739;
    uint160 public constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;
    /// @dev v4-core StateLibrary.POOLS_SLOT: pools mapping slot in PoolManager storage.
    uint256 internal constant POOLS_SLOT = 6;

    IPhase2RouteSourcePool public immutable SOURCE_POOL;
    IPhase2RouteTargetPool public immutable TARGET_POOL;
    IV4PoolManager public immutable POOL_MANAGER;
    address public immutable CURRENCY0;
    address public immutable CURRENCY1;
    uint24 public immutable LP_FEE;
    int24 public immutable TICK_SPACING;
    address public immutable HOOKS;
    bytes32 public immutable POOL_ID;
    address public immutable INPUT; // SOURCE_POOL.ASSET(); address(0) is native ETH.
    address public immutable OUTPUT; // TARGET_POOL.ASSET(); address(0) is native ETH.
    bool public immutable ZERO_FOR_ONE;
    uint160 public immutable SQRT_PRICE_LIMIT_X96;
    uint16 public immutable FEE_BPS;
    address public immutable TREASURY;

    /// @dev One-shot unlock context: keccak256 of the exact callback payload while armed, else 0.
    bytes32 private transient _pendingUnlock;

    error UnsupportedChainId();
    error InvalidRoute();
    error PoolNotInitialized();
    error InvalidServiceFee();
    error InvalidProcessor();
    error InvalidSwapAmount();
    error InvalidPrecommitment();
    error InvalidTemplate();
    error InvalidSourceAuthorization();
    error ActionMismatch();
    error ExpiredSwap();
    error InvalidCallback();
    error PartialFill();
    error InvalidSwapDelta();
    error SettlementMismatch();
    error UnexpectedBalanceDelta();
    error NonzeroAllowance();
    error UnexpectedNativeSender();
    error ServiceFeeAboveLimit();
    error NativeTransferFailed();

    // amountOut is NET, matching the new target note's value.
    event SwapReshielded(address indexed processor, address indexed sourcePool, address indexed targetPool,
        uint256 inputNullifier0, uint256 inputNullifier1, uint256 amountIn, uint256 amountOut,
        uint256 targetCommitment, uint256 targetPrecommitment);
    event ServiceFeePaid(address indexed treasury, address indexed token, uint256 grossAmountOut,
        uint256 serviceFee, uint256 netAmountOut);

    constructor(address sourcePool, address targetPool, address poolManager, PoolKey memory key,
        uint16 feeBps, address treasury)
    {
        if (block.chainid != 4663) revert UnsupportedChainId();
        if (sourcePool == targetPool || sourcePool.code.length == 0 || targetPool.code.length == 0
            || poolManager.code.length == 0) revert InvalidRoute();
        // v4 requires currency0 < currency1; only currency0 may be native.
        if (key.currency0 >= key.currency1 || key.currency1.code.length == 0
            || (key.currency0 != address(0) && key.currency0.code.length == 0)) revert InvalidRoute();
        address input = IPhase2RouteSourcePool(sourcePool).ASSET();
        address output = IPhase2RouteTargetPool(targetPool).ASSET();
        bool zeroForOne = input == key.currency0;
        if (!(zeroForOne ? output == key.currency1 : (input == key.currency1 && output == key.currency0))) revert InvalidRoute();
        if (feeBps == 0 || feeBps > MAX_SERVICE_FEE_BPS || treasury == address(0) || treasury == address(this)
            || treasury == sourcePool || treasury == targetPool || treasury == poolManager
            || treasury == key.currency0 || treasury == key.currency1 || treasury == key.hooks) revert InvalidServiceFee();
        bytes32 poolId = keccak256(abi.encode(key));
        bytes32 slot0 = IV4PoolManager(poolManager).extsload(keccak256(abi.encodePacked(poolId, POOLS_SLOT)));
        if (uint160(uint256(slot0)) == 0) revert PoolNotInitialized();
        SOURCE_POOL = IPhase2RouteSourcePool(sourcePool);
        TARGET_POOL = IPhase2RouteTargetPool(targetPool);
        POOL_MANAGER = IV4PoolManager(poolManager);
        CURRENCY0 = key.currency0;
        CURRENCY1 = key.currency1;
        LP_FEE = key.fee;
        TICK_SPACING = key.tickSpacing;
        HOOKS = key.hooks;
        POOL_ID = poolId;
        INPUT = input;
        OUTPUT = output;
        ZERO_FOR_ONE = zeroForOne;
        SQRT_PRICE_LIMIT_X96 = zeroForOne ? MIN_SQRT_PRICE + 1 : MAX_SQRT_PRICE - 1;
        FEE_BPS = feeBps;
        TREASURY = treasury;
    }

    /// @dev Native ETH arrives only from the source pool's withdrawal and the PoolManager's take.
    receive() external payable {
        if (msg.sender != address(SOURCE_POOL) && msg.sender != address(POOL_MANAGER)) revert UnexpectedNativeSender();
    }

    function poolKey() public view returns (PoolKey memory) {
        return PoolKey(CURRENCY0, CURRENCY1, LP_FEE, TICK_SPACING, HOOKS);
    }

    function actionHash(Action calldata action) public view returns (bytes32) {
        return keccak256(abi.encode(SWAP_DOMAIN, block.chainid, address(this), address(SOURCE_POOL),
            address(TARGET_POOL), address(POOL_MANAGER), POOL_ID, CURRENCY0, CURRENCY1, LP_FEE, TICK_SPACING, HOOKS,
            ZERO_FOR_ONE, FEE_BPS, TREASURY, action.processor, action.amountIn, action.minAmountOut,
            action.deadline, action.targetPrecommitment, keccak256(action.encryptedTemplate), action.maxServiceFee));
    }

    /// @dev Existing source proof binds this envelope in its second zero-value output slot.
    function actionEnvelope(Action calldata action) public view returns (bytes memory envelope) {
        envelope = new bytes(CIPHERTEXT_BYTES);
        bytes32 digest = actionHash(action);
        assembly ('memory-safe') { mstore(add(envelope, 0x20), digest) }
    }

    /// @notice Minimum gross output that satisfies minNet after a FLOOR-rounded fee.
    function minimumGrossOutput(uint128 minNet) public view returns (uint256) {
        if (minNet == 0) revert InvalidSwapAmount();
        return (uint256(minNet) - 1) * BPS_DENOMINATOR / (BPS_DENOMINATOR - FEE_BPS) + 1;
    }

    function swap(Action calldata action, Proof calldata proof, IPhase2RouteSourcePool.ExtData calldata data,
        bytes[2] calldata encryptedOutputs)
        external nonReentrant returns (uint256 amountOut, uint256 targetCommitment)
    {
        bytes32 digest = _validateAction(action, proof, data, encryptedOutputs);
        Balances memory b = _balances();
        if (OUTPUT != address(0) && IERC20(OUTPUT).allowance(address(this), address(TARGET_POOL)) != 0) revert NonzeroAllowance();

        // 1. Withdraw exactly amountIn from the source pool to this adapter.
        SOURCE_POOL.transact(proof.pA, proof.pB, proof.pC, proof.pubSignals, data, encryptedOutputs);
        if (_balanceOf(INPUT, address(this)) != b.inputBalance + action.amountIn
            || _balanceOf(OUTPUT, address(this)) != b.outputBalance
            || (INPUT != address(0) && OUTPUT != address(0) && address(this).balance != b.nativeBalance)) {
            revert UnexpectedBalanceDelta();
        }

        // 2. One-shot unlock bound to this action; the callback swaps, settles and takes.
        bytes memory payload = abi.encode(digest, action.amountIn);
        _pendingUnlock = keccak256(payload);
        uint256 grossOut = abi.decode(POOL_MANAGER.unlock(payload), (uint256));
        if (_pendingUnlock != bytes32(0)) revert InvalidCallback();

        // 3. Measured, not reported: the input is fully spent and exactly grossOut arrived.
        if (grossOut == 0 || grossOut > type(uint128).max
            || _balanceOf(INPUT, address(this)) != b.inputBalance
            || _balanceOf(OUTPUT, address(this)) != b.outputBalance + grossOut
            || (INPUT != address(0) && OUTPUT != address(0) && address(this).balance != b.nativeBalance)) {
            revert UnexpectedBalanceDelta();
        }
        uint256 serviceFee = grossOut * FEE_BPS / BPS_DENOMINATOR;
        if (serviceFee > action.maxServiceFee) revert ServiceFeeAboveLimit();
        amountOut = grossOut - serviceFee;
        if (amountOut < action.minAmountOut) revert InvalidSwapAmount();

        // 4. Fee to the treasury in the output asset (native ETH for a native output).
        if (serviceFee != 0) {
            if (OUTPUT == address(0)) {
                (bool ok,) = TREASURY.call{value: serviceFee}('');
                if (!ok) revert NativeTransferFailed();
            } else {
                IERC20(OUTPUT).safeTransfer(TREASURY, serviceFee);
            }
        }
        if (_balanceOf(OUTPUT, TREASURY) != b.treasuryBalance + serviceFee
            || _balanceOf(OUTPUT, address(this)) != b.outputBalance + amountOut) revert UnexpectedBalanceDelta();

        // 5. Reshield the net output as a new note in the target pool.
        if (OUTPUT == address(0)) {
            targetCommitment = TARGET_POOL.depositDynamic{value: amountOut}(
                uint128(amountOut), action.targetPrecommitment, action.encryptedTemplate);
        } else {
            IERC20(OUTPUT).forceApprove(address(TARGET_POOL), amountOut);
            targetCommitment = TARGET_POOL.depositDynamic(uint128(amountOut), action.targetPrecommitment, action.encryptedTemplate);
            IERC20(OUTPUT).forceApprove(address(TARGET_POOL), 0);
        }
        _checkFinalBalances(b, amountOut, serviceFee);
        emit ServiceFeePaid(TREASURY, OUTPUT, grossOut, serviceFee, amountOut);
        emit SwapReshielded(action.processor, address(SOURCE_POOL), address(TARGET_POOL),
            proof.pubSignals[5], proof.pubSignals[6], action.amountIn, amountOut,
            targetCommitment, action.targetPrecommitment);
    }

    /// @notice PoolManager callback. Only the pinned manager, only while this adapter's own swap has
    /// armed the exact payload, only once. Returns the gross output taken to this adapter.
    function unlockCallback(bytes calldata payload) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert InvalidCallback();
        bytes32 armed = _pendingUnlock;
        if (armed == bytes32(0) || keccak256(payload) != armed) revert InvalidCallback();
        _pendingUnlock = bytes32(0); // Disarm before the swap, hooks or any token transfer.
        (, uint128 amountIn) = abi.decode(payload, (bytes32, uint128));

        int256 delta = POOL_MANAGER.swap(
            IV4PoolManager.PoolKey(CURRENCY0, CURRENCY1, LP_FEE, TICK_SPACING, HOOKS),
            IV4PoolManager.SwapParams({zeroForOne: ZERO_FOR_ONE, amountSpecified: -int256(uint256(amountIn)),
                sqrtPriceLimitX96: SQRT_PRICE_LIMIT_X96}),
            '');
        // BalanceDelta: amount0 in the upper 128 bits, amount1 in the lower 128 bits (caller's view).
        int256 amount0 = int256(int128(delta >> 128));
        int256 amount1 = int256(int128(delta));
        (int256 inDelta, int256 outDelta) = ZERO_FOR_ONE ? (amount0, amount1) : (amount1, amount0);
        if (inDelta != -int256(uint256(amountIn))) revert PartialFill(); // includes dust and over-spend
        if (outDelta <= 0) revert InvalidSwapDelta();
        uint256 grossOut = uint256(outDelta);

        // Settle the exact input. sync(0) also clears any currency a hook may have synced.
        POOL_MANAGER.sync(INPUT);
        uint256 paid;
        if (INPUT == address(0)) {
            paid = POOL_MANAGER.settle{value: amountIn}();
        } else {
            IERC20(INPUT).safeTransfer(address(POOL_MANAGER), amountIn);
            paid = POOL_MANAGER.settle();
        }
        if (paid != amountIn) revert SettlementMismatch();
        POOL_MANAGER.take(OUTPUT, address(this), grossOut);
        return abi.encode(grossOut);
    }

    function _validateAction(Action calldata action, Proof calldata proof,
        IPhase2RouteSourcePool.ExtData calldata data, bytes[2] calldata encryptedOutputs) internal view returns (bytes32 digest)
    {
        if (action.processor == address(0) || msg.sender != action.processor) revert InvalidProcessor();
        if (block.timestamp > action.deadline) revert ExpiredSwap();
        // v4 caller deltas are int128; the frozen pool uses uint128.
        if (action.amountIn == 0 || action.amountIn > uint128(type(int128).max) || action.minAmountOut == 0) revert InvalidSwapAmount();
        if (action.targetPrecommitment == 0 || action.targetPrecommitment >= FIELD) revert InvalidPrecommitment();
        if (action.encryptedTemplate.length != CIPHERTEXT_BYTES) revert InvalidTemplate();
        if (data.processor != address(this) || data.recipient != address(this) || data.feeRecipient != address(0)
            || data.publicIn != 0 || data.publicOut != action.amountIn || data.fee != 0
            || proof.pubSignals[1] != 0 || proof.pubSignals[2] != action.amountIn || proof.pubSignals[8] != 0) {
            revert InvalidSourceAuthorization();
        }
        digest = actionHash(action);
        bytes memory envelope = new bytes(CIPHERTEXT_BYTES);
        assembly ('memory-safe') { mstore(add(envelope, 0x20), digest) }
        if (encryptedOutputs[0].length != CIPHERTEXT_BYTES || encryptedOutputs[1].length != CIPHERTEXT_BYTES
            || keccak256(encryptedOutputs[1]) != keccak256(envelope)) revert ActionMismatch();
    }

    function _balances() internal view returns (Balances memory b) {
        b.nativeBalance = address(this).balance;
        b.inputBalance = _balanceOf(INPUT, address(this));
        b.outputBalance = _balanceOf(OUTPUT, address(this));
        b.targetBalance = _balanceOf(OUTPUT, address(TARGET_POOL));
        b.treasuryBalance = _balanceOf(OUTPUT, TREASURY);
    }

    function _checkFinalBalances(Balances memory b, uint256 amountOut, uint256 serviceFee) internal view {
        if (address(this).balance != b.nativeBalance
            || _balanceOf(INPUT, address(this)) != b.inputBalance
            || _balanceOf(OUTPUT, address(this)) != b.outputBalance
            || _balanceOf(OUTPUT, address(TARGET_POOL)) != b.targetBalance + amountOut
            || _balanceOf(OUTPUT, TREASURY) != b.treasuryBalance + serviceFee) revert UnexpectedBalanceDelta();
        if (OUTPUT != address(0) && IERC20(OUTPUT).allowance(address(this), address(TARGET_POOL)) != 0) revert NonzeroAllowance();
        if (INPUT != address(0) && IERC20(INPUT).allowance(address(this), address(POOL_MANAGER)) != 0) revert NonzeroAllowance();
        if (_pendingUnlock != bytes32(0)) revert InvalidCallback();
    }

    function _balanceOf(address currency, address account) internal view returns (uint256) {
        return currency == address(0) ? account.balance : IERC20(currency).balanceOf(account);
    }
}
