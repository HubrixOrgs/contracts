// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Discrete-bin liquidity pool venue.
interface IBinPool {
    struct BinState {
        uint256 reserve0; // token0 held by the bin
        uint256 reserve1; // token1 held by the bin
        uint256 totalShares; // fungible shares of this bin
    }

    function token0() external view returns (address);
    function token1() external view returns (address);
    function binStepBps() external view returns (uint16);
    function activeId() external view returns (int32);
    function hub() external view returns (address);

    /// @notice Fixed price of a bin as token1-per-token0 in Q64.96.
    function priceOfBin(int32 id) external view returns (uint160);

    function bin(int32 id) external view returns (BinState memory);
    function sharesOf(int32 id, address account) external view returns (uint256);

    function addLiquidity(int32[] calldata ids, uint256[] calldata amounts0, uint256[] calldata amounts1, address to)
        external
        returns (uint256[] memory sharesMinted);

    function removeLiquidity(int32[] calldata ids, uint256[] calldata shares, address to)
        external
        returns (uint256[] memory amounts0, uint256[] memory amounts1);

    function swap(bool zeroForOne, uint256 amountIn, uint256 amountOutMin, address recipient)
        external
        returns (uint256 amountOut);

    function currentFeeBps() external view returns (uint24);

    function getAmountOut(bool zeroForOne, uint256 amountIn) external view returns (uint256 amountOut);
}
