// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Singleton manager for hook pools (v4-style).
interface IPoolManager {
    struct PoolState {
        address token0;
        address token1;
        address hooks;
        uint24 feeSeed; // static fee (bps) when hooks == address(0)
        uint160 sqrtPriceX96;
        uint128 liquidity;
        uint256 feeGrowthGlobal0X128;
        uint256 feeGrowthGlobal1X128;
        uint256 feesOwed0; // protocol-side pending (dust)
        uint256 feesOwed1;
    }

    struct PositionState {
        uint128 liquidity;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint256 tokensOwed0;
        uint256 tokensOwed1;
    }

    function createPool(address tokenA, address tokenB, address hooks, uint24 feeSeed, uint160 sqrtPriceX96)
        external
        returns (bytes32 poolId);

    function modifyLiquidity(bytes32 poolId, int256 liquidityDelta, address owner) external
        returns (uint256 amount0, uint256 amount1);

    function swap(bytes32 poolId, bool zeroForOne, uint256 amountIn, uint256 amountOutMin, address recipient)
        external
        returns (uint256 amountOut);

    function collect(bytes32 poolId, address owner, address recipient)
        external
        returns (uint256 amount0, uint256 amount1);

    function computePoolId(address tokenA, address tokenB, address hooks, uint24 feeSeed)
        external
        view
        returns (bytes32);

    function getPool(bytes32 poolId) external view returns (PoolState memory);

    function getPosition(bytes32 poolId, address owner) external view returns (PositionState memory);

    function poolTokens(bytes32 poolId) external view returns (address token0, address token1);

    function poolIdsForPair(address tokenA, address tokenB) external view returns (bytes32[] memory);

    function getAmountOut(bytes32 poolId, bool zeroForOne, uint256 amountIn)
        external
        view
        returns (uint256 amountOut, uint24 feeBps);
}
