// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Single-range (one dynamic band) pool venue with fungible shares.
interface IRangePool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function hub() external view returns (address);
    function reserve0() external view returns (uint256);
    function reserve1() external view returns (uint256);
    function totalShares() external view returns (uint256);
    function sharesOf(address account) external view returns (uint256);
    function sqrtPriceX96() external view returns (uint160);
    function launchFeeBps() external view returns (uint24);
    function currentFeeBps() external view returns (uint24);

    function addLiquidity(uint256 amount0Desired, uint256 amount1Desired, uint256 minShares, address to)
        external
        returns (uint256 shares);

    function removeLiquidity(uint256 shares, uint256 amount0Min, uint256 amount1Min, address to)
        external
        returns (uint256 amount0, uint256 amount1);

    function swap(bool zeroForOne, uint256 amountIn, uint256 amountOutMin, address recipient)
        external
        returns (uint256 amountOut);

    function getAmountOut(bool zeroForOne, uint256 amountIn) external view returns (uint256 amountOut);

    /// @notice Exact token1 amount paired with `amount0` for a band-ratio deposit.
    function pairedAmount1For0(uint256 amount0) external view returns (uint256);

    function band() external view returns (uint160 sqrtLowerX96, uint160 sqrtUpperX96);
}
