// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base} from "./Base.t.sol";
import {FeeMath} from "../src/libraries/FeeMath.sol";
import {BinPriceMath} from "../src/libraries/BinPriceMath.sol";

contract FeeMathTest is Base {
    using FeeMath for FeeMath.VolState;

    function test_DynamicFeeBounded() public pure {
        uint24 base = 5;
        uint24 cap = 2000;
        // calm: accumulator 0 -> base fee
        assertEq(uint256(FeeMath.dynamicFee(base, cap, 0, 1000)), 5);
        // saturated: accumulator 1e18 -> cap (clamped by protocol cap 1000)
        assertEq(uint256(FeeMath.dynamicFee(base, cap, 1e18, 1000)), 1000);
        assertEq(uint256(FeeMath.dynamicFee(base, 2000, 1e18, 10_000)), 2000);
        // half
        assertEq(uint256(FeeMath.dynamicFee(base, 2000, 5e17, 10_000)), uint256(uint24(5) + (uint24(2000) - 5) / 2));
        // protocol cap is hard
        assertEq(uint256(FeeMath.dynamicFee(900, 2000, 0, 500)), 500);
    }

    function test_LaunchFeeDecay() public {
        uint24 f0 = FeeMath.launchFee(5, 3000, 1 hours, uint64(block.timestamp));
        assertEq(uint256(f0), 3000);
        vm.warp(block.timestamp + 30 minutes);
        uint24 fMid = FeeMath.launchFee(5, 3000, 1 hours, uint64(block.timestamp - 30 minutes));
        assertEq(uint256(fMid), uint256(uint24(5) + (uint24(3000) - 5) / 2));
        vm.warp(block.timestamp + 30 minutes + 1);
        assertEq(uint256(FeeMath.launchFee(5, 3000, 1 hours, uint64(block.timestamp - 1 hours - 1))), 5);
    }

    function test_VolAccumulatorDecayAndMove() public {
        uint256 q96 = 1 << 96;
        FeeMath.VolState memory v;
        v.lastPriceX96 = uint160(q96);
        v.lastTs = uint64(block.timestamp);
        // +1% price move in the same block: no decay, move = 0.01e18
        uint96 acc = FeeMath.update(v, uint160(q96 * 101 / 100), 600);
        assertApproxEqRel(uint256(acc), 0.01e18, 1e15);
        // 600 s of calm at the NEW price: decays to half (600/(600+600))
        v.accumulator = acc;
        v.lastPriceX96 = uint160(q96 * 101 / 100);
        v.lastTs = uint64(block.timestamp);
        vm.warp(block.timestamp + 600);
        uint96 acc2 = FeeMath.update(v, uint160(q96 * 101 / 100), 600);
        assertApproxEqRel(uint256(acc2), 0.005e18, 1e15);
    }


    function test_BinLadderPrices() public pure {
        uint256 q96 = 1 << 96;
        uint16 step = 25; // bps
        uint160 p0 = BinPriceMath.priceOfBin(step, 0);
        assertEq(uint256(p0), q96);
        uint160 p1 = BinPriceMath.priceOfBin(step, 1);
        // p1 = 1.0025 in Q96
        assertApproxEqRel(uint256(p1), q96 * 10_025 / 10_000, 1e14);
        uint160 pn1 = BinPriceMath.priceOfBin(step, -1);
        // 1/1.0025 in Q96
        assertApproxEqRel(uint256(pn1), q96 * 10_000 / 10_025, 1e14);
        // ladder consistency: p(2) ~= p(1)^2
        uint160 p2 = BinPriceMath.priceOfBin(step, 2);
        assertApproxEqRel(uint256(p2), uint256(p1) * p1 >> 96, 1e12);
    }
}
