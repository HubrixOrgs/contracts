// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Hook callback interface for the singleton pool manager (v4-style).
interface IPoolHook {
    struct SwapContext {
        bytes32 poolId; // pool identifier
        bool zeroForOne; // true: token0 in, token1 out
        uint256 amountIn; // exact input amount (before fee)
        uint160 sqrtPriceX96; // pool price before the swap
        uint128 liquidity; // pool liquidity before the swap
    }

    /// @notice Called when a pool that references this hook is initialized.
    function onPoolInit(bytes32 poolId, address token0, address token1, uint24 feeSeed, uint160 sqrtPriceX96)
        external;

    /// @notice Returns the swap fee (bps) for this swap and validates guard rails.
    /// Reverts for oracle-guarded pools when the feed is stale or the trade would
    /// trip the circuit breaker.
    function getSwapFeeBefore(SwapContext memory ctx) external view returns (uint24 feeBps);

    /// @notice Called after a swap completes; updates the volatility accumulator.
    function afterSwap(bytes32 poolId, uint160 sqrtPriceAfterX96, uint256 amountIn, uint24 feeBps) external;
}
