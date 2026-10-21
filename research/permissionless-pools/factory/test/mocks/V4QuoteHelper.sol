// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {IV4PoolManager} from '../../src/Phase2FeeV4Adapter.sol';

/// @notice Fork-only exact-input quote: swaps inside unlock and reverts with the caller delta,
/// so nothing settles. Call it with eth_call. Same key, amount, extreme price limit and empty
/// hook data as Phase2FeeV4Adapter; a sender-dependent hook could quote differently.
contract V4QuoteHelper {
    IV4PoolManager public immutable POOL_MANAGER;

    error Quote(int256 amount0, int256 amount1);

    constructor(IV4PoolManager manager) { POOL_MANAGER = manager; }

    function quote(IV4PoolManager.PoolKey calldata key, bool zeroForOne, uint128 amountIn)
        external returns (int256 amount0, int256 amount1)
    {
        try POOL_MANAGER.unlock(abi.encode(key, zeroForOne, amountIn)) {
            revert('no quote');
        } catch (bytes memory reason) {
            if (reason.length != 68 || bytes4(reason) != Quote.selector) {
                assembly ('memory-safe') { revert(add(reason, 0x20), mload(reason)) }
            }
            assembly ('memory-safe') {
                amount0 := mload(add(reason, 0x24))
                amount1 := mload(add(reason, 0x44))
            }
        }
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(POOL_MANAGER), 'manager only');
        (IV4PoolManager.PoolKey memory key, bool zeroForOne, uint128 amountIn) =
            abi.decode(data, (IV4PoolManager.PoolKey, bool, uint128));
        int256 delta = POOL_MANAGER.swap(key, IV4PoolManager.SwapParams({zeroForOne: zeroForOne,
            amountSpecified: -int256(uint256(amountIn)),
            sqrtPriceLimitX96: zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341}), '');
        revert Quote(int256(int128(delta >> 128)), int256(int128(delta)));
    }
}
