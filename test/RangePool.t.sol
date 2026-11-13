// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base} from "./Base.t.sol";
import {IRangePool} from "../src/interfaces/IRangePool.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract RangePoolTest is Base {
    IRangePool pool;
    IRangePoolT poolT;

    function setUp() public virtual override {
        Base.setUp();
        // 1 WETH = 12 STOK; price = token1 per token0 in base units (60e18/5e18 or 5e18/60e18)
        uint256 num = address(weth) < address(stok) ? 60e18 : 5e18;
        uint256 den = address(weth) < address(stok) ? 5e18 : 60e18;
        uint160 anchor = uint160(Math.sqrt(Math.mulDiv(num, 1 << 192, den)));
        vm.startPrank(admin);
        pool = IRangePool(rangeFactory.createPool(address(weth), address(stok), anchor, 1200, 5, 3000, 1 hours));
        poolT = IRangePoolT(address(pool));
        vm.stopPrank();
        _approveAll(alice, address(pool));
        _approveAll(bob, address(pool));
    }

    function _seed() internal returns (uint256 shares) {
        // deposit 5 WETH-equivalent on the token0 side and the exact paired token1 amount
        uint256 d0;
        uint256 d1;
        if (address(weth) < address(stok)) {
            d0 = 5e18;
            d1 = poolT.pairedAmount1For0(d0);
        } else {
            d0 = 5e18; // token0 = STOK side small units? keep symmetric via pair helper below
            d1 = poolT.pairedAmount1For0(d0);
        }
        vm.prank(alice);
        shares = pool.addLiquidity(d0, d1, 0, alice);
    }

    function test_FirstSharesAreSqrtXY() public {
        uint256 shares = _seed();
        uint256 x = pool.reserve0();
        uint256 y = pool.reserve1();
        assertApproxEqRel(shares, Math.sqrt(x * y), 1e12);
        assertGt(shares, 0);
    }

    function test_SwapInsideBandAndQuoteMatch() public {
        _seed();
        bool z41 = pool.token0() == address(weth); // sell WETH
        uint256 amtIn = 0.1e18;
        uint256 quote = pool.getAmountOut(z41, amtIn);
        assertTrue(quote > 0);
        vm.prank(bob);
        uint256 got = pool.swap(z41, amtIn, quote * 99 / 100, bob);
        assertApproxEqRel(got, quote, 1e12);
    }

    function test_LaunchFeeDecays() public {
        // launch fee starts at 3000 bps, clamped by the hub cap (1000)
        assertEq(uint256(pool.currentFeeBps()), 1000);
        vm.warp(block.timestamp + 30 minutes); // mid-window: ~1503 bps -> still clamped
        assertEq(uint256(pool.currentFeeBps()), 1000);
        vm.warp(block.timestamp + 31 minutes); // past window: dynamic fee at base (accumulator 0)
        uint24 f = pool.currentFeeBps();
        assertTrue(f < 100);
    }

    function test_EdgePartialFillRefunds() public {
        _seed();
        // 5 WETH in band ±12%: capacity in token0-to-lower-edge is small.
        bool z41 = pool.token0() == address(weth);
        uint256 bobWethBefore = weth.balanceOf(bob);
        uint256 bobStokBefore = stok.balanceOf(bob);
        vm.startPrank(bob);
        // swap a huge amount: partial fill at the band edge + refund
        uint256 out;
        if (z41) {
            out = pool.swap(true, 100e18, 0, bob); // sell WETH far beyond capacity
        } else {
            out = pool.swap(false, 100e18, 0, bob); // token1 = WETH side
        }
        vm.stopPrank();
        assertTrue(out > 0);
        // input consumed < 100: refund visible (WETH balance decreased by less than 100)
        uint256 wethDelta = bobWethBefore - weth.balanceOf(bob);
        assertLt(wethDelta, 100e18);
        assertGt(stok.balanceOf(bob), bobStokBefore);
    }

    function test_FeesAccruePerShare() public {
        _seed();
        (bool z41,) = (pool.token0() == address(weth), false);
        vm.startPrank(bob);
        pool.swap(z41, 0.1e18, 0, bob);
        vm.stopPrank();
        (uint256 f0, uint256 f1) = poolT.claimableFees(alice);
        assertTrue(f0 > 0 || f1 > 0);
        vm.prank(alice);
        poolT.claimFees(alice);
        (uint256 f0b, uint256 f1b) = poolT.claimableFees(alice);
        assertEq(f0b, 0);
        assertEq(f1b, 0);
    }
}

interface IRangePoolT {
    function claimableFees(address) external view returns (uint256, uint256);
    function claimFees(address) external returns (uint256, uint256);
    function pairedAmount1For0(uint256) external view returns (uint256);
}
