// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

interface IMemePoolDeployer {
    function deploy(address registry, address token) external returns (address);
}

interface IMemeProviderDeployer {
    function deploy() external returns (address);
}

interface IMemeProvider {
    function REGISTRY() external view returns (address);
    function bind(address pool) external;
}

interface IV3RouteDeployer {
    function deploy(address sourcePool, address targetPool, bytes calldata path) external returns (address);
}

/// @dev Same field order as Uniswap V4's PoolKey, with currencies as plain addresses (0 = native ETH).
struct V4PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

interface IV4RouteDeployer {
    function deploy(address sourcePool, address targetPool, V4PoolKey calldata key) external returns (address);
}

interface IAssetPool {
    function ASSET() external view returns (address);
    function nextLeafIndex() external view returns (uint256);
}

/// @notice Research only. Anyone opens a private pool for any token and adds in-pool trade routes;
/// Lincoln approves neither. No owner, no setters, no fee or treasury choice by the caller.
/// @dev Each pool is the unchanged RC.3 pool with no deposit caps, bound in the same transaction to
/// its own AutoApproveProvider, so no operator runs its association set. Base pools (the live ETH
/// and USDG pools) are fixed at construction; every route has at least one factory pool. Adapters
/// deployed here are the trusted depositors the providers approve at once, because each adapter
/// deposit comes from a note already approved in the source pool.
contract LincolnMemeFactory {
    uint8 public constant ROUTE_V3 = 0;
    uint8 public constant ROUTE_V4 = 1;
    /// @dev A token's pool can be reopened as a new generation once its 2^20-leaf tree is this full,
    /// so filling a tree with dust deposits cannot retire a token for good (audit 2026-10-21, F-3).
    uint256 public constant REOPEN_AT_LEAVES = (1 << 20) - 16;

    IMemePoolDeployer public immutable POOL_DEPLOYER;
    IMemeProviderDeployer public immutable PROVIDER_DEPLOYER;
    IV3RouteDeployer public immutable V3_ROUTES;
    IV4RouteDeployer public immutable V4_ROUTES;

    mapping(address => bool) public isBasePool;
    mapping(address => bool) public isBaseAsset;
    /// @dev The current generation for a token; older generations keep working for exits and routes.
    mapping(address => address) public poolOf;
    mapping(address => address[]) private _generations;
    mapping(address => address) public providerOf;
    mapping(address => bool) public isFactoryPool;
    mapping(address => bool) public isRouteAdapter;
    mapping(bytes32 => address) public routeOf;
    address[] public pools;
    address[] public routes;

    error InvalidToken();
    error PoolExists();
    error InvalidRoute();
    error RouteExists();
    error InvalidBasePool();

    event PoolCreated(address indexed token, address indexed pool, address provider, address registry, address indexed creator);
    event RouteCreated(bytes32 indexed routeId, uint8 kind, address indexed sourcePool, address indexed targetPool,
        address adapter, bytes route, address creator);

    constructor(address poolDeployer, address providerDeployer, address v3Routes, address v4Routes, address[] memory basePools) {
        POOL_DEPLOYER = IMemePoolDeployer(poolDeployer);
        PROVIDER_DEPLOYER = IMemeProviderDeployer(providerDeployer);
        V3_ROUTES = IV3RouteDeployer(v3Routes);
        V4_ROUTES = IV4RouteDeployer(v4Routes);
        for (uint256 i; i < basePools.length; i++) {
            address base = basePools[i];
            if (base.code.length == 0 || isBasePool[base]) revert InvalidBasePool();
            isBasePool[base] = true;
            isBaseAsset[IAssetPool(base).ASSET()] = true;
        }
    }

    function generationsOf(address token) external view returns (address[] memory) {
        return _generations[token];
    }

    function poolCount() external view returns (uint256) {
        return pools.length;
    }

    function routeCount() external view returns (uint256) {
        return routes.length;
    }

    /// @notice Open the private pool for `token`. One open pool per token, until its tree is nearly full;
    /// base assets keep their live pools.
    function createPool(address token) external returns (address pool) {
        if (token == address(0) || token.code.length == 0 || isBaseAsset[token]) revert InvalidToken();
        address current = poolOf[token];
        if (current != address(0) && IAssetPool(current).nextLeafIndex() < REOPEN_AT_LEAVES) revert PoolExists();
        // ERC20 shape only. Exact-transfer is enforced by the pool on every deposit.
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSignature('totalSupply()'));
        if (!ok || data.length < 32) revert InvalidToken();
        (ok, data) = token.staticcall(abi.encodeWithSignature('decimals()'));
        if (!ok || data.length < 32 || abi.decode(data, (uint256)) > 36) revert InvalidToken();

        address provider = PROVIDER_DEPLOYER.deploy();
        address registry = IMemeProvider(provider).REGISTRY();
        pool = POOL_DEPLOYER.deploy(registry, token);
        IMemeProvider(provider).bind(pool);
        poolOf[token] = pool;
        _generations[token].push(pool);
        providerOf[pool] = provider;
        isFactoryPool[pool] = true;
        pools.push(pool);
        emit PoolCreated(token, pool, provider, registry, msg.sender);
    }

    /// @notice Add a Uniswap V3 route (exact-input path, any hops) from one pool to another.
    function createV3Route(address sourcePool, address targetPool, bytes calldata path) external returns (address adapter) {
        bytes32 id = _routeId(ROUTE_V3, sourcePool, targetPool, path);
        adapter = V3_ROUTES.deploy(sourcePool, targetPool, path);
        _record(id, ROUTE_V3, sourcePool, targetPool, adapter, path);
    }

    /// @notice Add a single-pool Uniswap V4 route, for any key including native ETH and hooks.
    function createV4Route(address sourcePool, address targetPool, V4PoolKey calldata key) external returns (address adapter) {
        bytes memory encoded = abi.encode(key);
        bytes32 id = _routeId(ROUTE_V4, sourcePool, targetPool, encoded);
        adapter = V4_ROUTES.deploy(sourcePool, targetPool, key);
        _record(id, ROUTE_V4, sourcePool, targetPool, adapter, encoded);
    }

    function _routeId(uint8 kind, address sourcePool, address targetPool, bytes memory route) internal view returns (bytes32 id) {
        if (sourcePool == targetPool) revert InvalidRoute();
        bool sourceKnown = isFactoryPool[sourcePool] || isBasePool[sourcePool];
        bool targetKnown = isFactoryPool[targetPool] || isBasePool[targetPool];
        if (!sourceKnown || !targetKnown || !(isFactoryPool[sourcePool] || isFactoryPool[targetPool])) revert InvalidRoute();
        id = keccak256(abi.encode(kind, sourcePool, targetPool, keccak256(route)));
        if (routeOf[id] != address(0)) revert RouteExists();
    }

    function _record(bytes32 id, uint8 kind, address sourcePool, address targetPool, address adapter, bytes memory route) internal {
        routeOf[id] = adapter;
        isRouteAdapter[adapter] = true;
        routes.push(adapter);
        emit RouteCreated(id, kind, sourcePool, targetPool, adapter, route, msg.sender);
    }
}
