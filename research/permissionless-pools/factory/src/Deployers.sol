// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Phase2ASPPool} from 'rc3/Phase2ASPPool.sol';
import {Phase2FeeRouter02Adapter} from 'rc3-fees/Phase2FeeRouteAdapter.sol';
import {AutoApproveProvider} from './AutoApproveProvider.sol';
import {Phase2FeeV4Adapter} from './Phase2FeeV4Adapter.sol';
import {V4PoolKey} from './LincolnMemeFactory.sol';

/// @notice Research only. Holds one creation code for the factory, which would otherwise exceed
/// the 24 KB contract limit. Only the factory can deploy through it; the factory is set once by
/// whoever deployed this contract, in the same rollout that deploys the factory.
abstract contract FactoryOnly {
    address public immutable SETTER;
    address public factory;

    error OnlyFactory();
    error OnlySetter();
    error FactoryAlreadySet();
    error InvalidFactory();

    event FactorySet(address indexed factory);

    constructor() {
        SETTER = msg.sender;
    }

    function setFactory(address next) external {
        if (msg.sender != SETTER) revert OnlySetter();
        if (factory != address(0)) revert FactoryAlreadySet();
        if (next.code.length == 0) revert InvalidFactory();
        factory = next;
        emit FactorySet(next);
    }

    modifier onlyFactory() {
        if (msg.sender != factory || factory == address(0)) revert OnlyFactory();
        _;
    }
}

/// @notice Deploys the unchanged RC.3 pool with no deposit caps. The guardian Safe can still
/// lower caps or pause deposits on any factory pool, and raise caps after the 12-hour delay.
contract PoolDeployer is FactoryOnly {
    uint128 public constant NO_CAP = type(uint128).max;
    address public immutable VERIFIER;
    address public immutable EXIT_VERIFIER;

    constructor(address verifier, address exitVerifier) {
        VERIFIER = verifier;
        EXIT_VERIFIER = exitVerifier;
    }

    function deploy(address registry, address token) external onlyFactory returns (address) {
        return address(new Phase2ASPPool(VERIFIER, EXIT_VERIFIER, registry, token, NO_CAP, NO_CAP));
    }
}

/// @notice Deploys an AutoApproveProvider (and with it the pool's own registry) bound to the factory.
contract ProviderDeployer is FactoryOnly {
    address public immutable GUARDIAN;
    address public immutable SCREENING;
    uint64 public immutable SCREENING_DELAY;

    constructor(address guardian, address screening, uint64 screeningDelay) {
        GUARDIAN = guardian;
        SCREENING = screening;
        SCREENING_DELAY = screeningDelay;
    }

    function deploy() external onlyFactory returns (address) {
        return address(new AutoApproveProvider(GUARDIAN, SCREENING, SCREENING_DELAY, factory));
    }
}

/// @notice Deploys the unchanged RC.3 Uniswap V3 fee adapter with the fixed fee and treasury.
/// The adapter constructor rejects a path without a V3 pool for every hop.
contract V3RouteDeployer is FactoryOnly {
    address public immutable ROUTER;
    address public immutable WRAPPED_NATIVE;
    uint16 public immutable FEE_BPS;
    address public immutable TREASURY;

    constructor(address router, address wrappedNative, uint16 feeBps, address treasury) {
        ROUTER = router;
        WRAPPED_NATIVE = wrappedNative;
        FEE_BPS = feeBps;
        TREASURY = treasury;
    }

    function deploy(address sourcePool, address targetPool, bytes calldata path) external onlyFactory returns (address) {
        return address(new Phase2FeeRouter02Adapter(sourcePool, targetPool, ROUTER, WRAPPED_NATIVE, 0, path, FEE_BPS, TREASURY));
    }
}

/// @notice Deploys a single-pool Uniswap V4 fee adapter with the fixed fee and treasury. The adapter
/// constructor rejects a key whose currencies do not match the two pools or whose pool is uninitialized.
contract V4RouteDeployer is FactoryOnly {
    address public immutable POOL_MANAGER;
    uint16 public immutable FEE_BPS;
    address public immutable TREASURY;

    constructor(address poolManager, uint16 feeBps, address treasury) {
        POOL_MANAGER = poolManager;
        FEE_BPS = feeBps;
        TREASURY = treasury;
    }

    function deploy(address sourcePool, address targetPool, V4PoolKey calldata key) external onlyFactory returns (address) {
        Phase2FeeV4Adapter.PoolKey memory adapterKey =
            Phase2FeeV4Adapter.PoolKey(key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks);
        return address(new Phase2FeeV4Adapter(sourcePool, targetPool, POOL_MANAGER, adapterKey, FEE_BPS, TREASURY));
    }
}
