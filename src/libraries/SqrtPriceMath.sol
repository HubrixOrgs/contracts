// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Full-range (v3-style) sqrt price math used by the singleton pool manager.
/// @dev sqrt prices are Q64.96 (uint160). All rounding favors the pool.
library SqrtPriceMath {
    using Math for uint256;

    uint256 internal constant Q96 = 1 << 96;

    /// @notice Next sqrt price after an exact input of token0 (price decreases).
    function sqrtPriceAfterToken0In(uint160 sqrtP, uint128 liquidity, uint256 amount0In)
        internal
        pure
        returns (uint160)
    {
        // sqrtP' = (L<<96) * sqrtP / ((L<<96) + amount0 * sqrtP)  [round up]
        uint256 prod = Math.mulDiv(amount0In, sqrtP, 1);
        uint256 denom = (uint256(liquidity) << 96) + prod;
        if (denom == 0) return sqrtP;
        return uint160(Math.mulDiv(uint256(liquidity) << 96, sqrtP, denom, Math.Rounding.Ceil));
    }

    /// @notice Next sqrt price after an exact input of token1 (price increases).
    function sqrtPriceAfterToken1In(uint160 sqrtP, uint128 liquidity, uint256 amount1In)
        internal
        pure
        returns (uint160)
    {
        // sqrtP' = sqrtP + amount1 * 2^96 / L  [round up]
        uint256 delta = Math.mulDiv(amount1In, Q96, liquidity, Math.Rounding.Ceil);
        return uint160(uint256(sqrtP) + delta);
    }

    /// @notice token0 amount held for liquidity L at price sqrtP (full range, round down).
    function amount0(uint128 liquidity, uint160 sqrtP) internal pure returns (uint256) {
        return Math.mulDiv(liquidity, Q96, sqrtP); // L / sqrtP
    }

    /// @notice token1 amount held for liquidity L at price sqrtP (full range, round down).
    function amount1(uint128 liquidity, uint160 sqrtP) internal pure returns (uint256) {
        return Math.mulDiv(liquidity, sqrtP, Q96); // L * sqrtP
    }

    /// @notice token1 out when sqrtP moves from a to a' < a: L * (a - a') / 2^96 (round down).
    function token1Out(uint128 liquidity, uint160 a, uint160 aAfter) internal pure returns (uint256) {
        return Math.mulDiv(liquidity, a - aAfter, Q96);
    }

    /// @notice token0 out when sqrtP moves from a to a' > a: L*2^96*(a'-a)/(a*a') (round down).
    function token0Out(uint128 liquidity, uint160 a, uint160 aAfter) internal pure returns (uint256) {
        return Math.mulDiv(uint256(liquidity) << 96, aAfter - a, uint256(a) * aAfter);
    }

    /// @notice sqrtPriceX96 for a token1-per-token0 price in Q96.
    function sqrtQ96FromPriceX96(uint256 priceX96) internal pure returns (uint160) {
        return uint160(Math.sqrt(Math.mulDiv(priceX96, Q96, 1)));
    }

    /// @notice Price (token1 per token0) in Q96 from a sqrt price.
    function priceX96FromSqrt(uint160 sqrtP) internal pure returns (uint256) {
        return Math.mulDiv(sqrtP, sqrtP, Q96);
    }
}
