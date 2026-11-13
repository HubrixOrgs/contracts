// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Shared dynamic-fee math: volatility accumulator + fee derivation.
/// @dev All values WAD-scaled (1e18).
library FeeMath {
    uint256 internal constant WAD = 1e18;
    uint64 internal constant DEFAULT_DECAY_WINDOW = 600; // seconds

    struct VolState {
        uint96 accumulator; // saturated at 1e18
        uint160 lastPriceX96; // last reference price (Q64.96)
        uint64 lastTs;
    }

    error VolPriceZero();

    /// @notice Update the accumulator for a new observed price.
    /// acc' = acc * window/(window+dt) + |price - lastPrice|/lastPrice, capped at 1e18.
    function update(VolState memory s, uint160 priceX96, uint64 window) internal view returns (uint96 newAcc) {
        if (s.lastTs == 0 || s.lastPriceX96 == 0) {
            return uint96(0); // first observation seeds only
        }
        uint256 dt = block.timestamp > s.lastTs ? block.timestamp - s.lastTs : 0;
        uint256 acc = s.accumulator;
        if (dt > 0) {
            acc = (acc * window) / (window + dt);
        }
        uint256 move;
        if (priceX96 >= s.lastPriceX96) {
            move = priceX96 - s.lastPriceX96;
        } else {
            move = s.lastPriceX96 - priceX96;
        }
        move = (move * WAD) / s.lastPriceX96;
        acc += move;
        if (acc > WAD) acc = WAD;
        return uint96(acc);
    }

    /// @notice Derive the dynamic fee: base + (cap - base) * accumulator, clamped by protocolCap.
    function dynamicFee(uint24 baseBps, uint24 capBps, uint96 accumulator, uint24 protocolCapBps)
        internal
        pure
        returns (uint24)
    {
        uint256 span = capBps > baseBps ? capBps - baseBps : 0;
        uint256 fee = baseBps + (span * uint256(accumulator)) / WAD;
        if (fee > protocolCapBps) fee = protocolCapBps;
        if (fee > 10_000) fee = 10_000;
        return uint24(fee);
    }

    /// @notice Linear launch-fee decay: launchStart -> base over `window` seconds.
    function launchFee(uint24 baseBps, uint24 launchStartBps, uint32 window, uint64 createdAt)
        internal
        view
        returns (uint24)
    {
        if (window == 0 || block.timestamp >= createdAt + window) return baseBps;
        uint256 elapsed = block.timestamp - createdAt;
        uint256 remaining = window - elapsed;
        uint256 fee = baseBps + ((uint256(launchStartBps - baseBps) * remaining) / window);
        return uint24(fee);
    }
}
