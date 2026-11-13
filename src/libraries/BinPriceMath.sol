// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Bin price ladder: priceOfBin(id) = (1 + step/10000)^id in Q64.96.
/// @dev Exponentiation by squaring in Q64 fixed point. Ids are limited to
///      |id| <= MAX_BIN_ID so every intermediate stays comfortably inside uint256.
library BinPriceMath {
    uint256 internal constant Q64 = 1 << 64;
    uint256 internal constant Q96 = 1 << 96;

    int32 internal constant MAX_BIN_ID = 4096;

    error BinIdOutOfRange();
    error BinPriceOverflow();

    /// @notice (1 + stepBps/10000)^exp as Q64.96, exp >= 0.
    function powStep(uint16 stepBps, uint256 exp) internal pure returns (uint160) {
        uint256 b = (uint256(10_000 + stepBps) << 64) / 10_000; // base in Q64
        uint256 result = Q64;
        uint256 e = exp;
        while (e > 0) {
            if (e & 1 == 1) {
                result = (result * b) >> 64;
                if (result >= Q96) revert BinPriceOverflow(); // real price >= 2^32
            }
            e >>= 1;
            if (e > 0) {
                b = (b * b) >> 64;
                if (b >= Q96) revert BinPriceOverflow(); // any future multiply exceeds the cap
            }
        }
        return uint160(result << 32); // Q64 -> Q64.96
    }

    /// @notice Fixed price of bin `id` as token1-per-token0 in Q64.96.
    function priceOfBin(uint16 stepBps, int32 id) internal pure returns (uint160) {
        if (id > MAX_BIN_ID || id < -MAX_BIN_ID) revert BinIdOutOfRange();
        if (id >= 0) {
            return powStep(stepBps, uint256(uint32(id)));
        }
        // negative id: invert (1+s)^|id|  ->  1/p in Q96 = 2^192 / p
        uint160 p = powStep(stepBps, uint256(uint32(-id)));
        return uint160((1 << 192) / p);
    }
}
