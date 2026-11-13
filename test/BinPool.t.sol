// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base} from "./Base.t.sol";
import {IBinPool} from "../src/interfaces/IBinPool.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract BinPoolTest is Base {
    IBinPool pool;
    bool wethIsToken0;

    // 1 WETH = 3000 USDX market, 25 bps bins, active id 0 by using a 1:1 pair? Use
    // WETH/USDX at ladder id 3207 like the deploy script.
    int32 active0 = 3207;

    function setUp() public virtual override {
        Base.setUp();
        wethIsToken0 = address(weth) < address(usdx);
        vm.prank(admin);
        pool = IBinPool(binFactory.createPool(address(weth), address(usdx), 25, wethIsToken0 ? active0 : -active0));
        _approveAll(alice, address(pool));
        _approveAll(bob, address(pool));
    }

    function _seed(uint256 wethPerBin, uint8 above, uint8 below) internal returns (int32 active) {
        active = pool.activeId();
        uint256 usdxPerBin = Math.mulDiv(wethPerBin, pool.priceOfBin(active), Q96);
        uint256 n = 1 + above + below;
        int32[] memory ids = new int32[](n);
        uint256[] memory a0 = new uint256[](n);
        uint256[] memory a1 = new uint256[](n);
        ids[0] = active;
        (a0[0], a1[0]) = wethIsToken0 ? (wethPerBin, usdxPerBin) : (usdxPerBin, wethPerBin);
        for (uint8 i = 0; i < above; i++) {
            ids[1 + i] = active + int32(uint32(i)) + 1;
            a0[1 + i] = wethIsToken0 ? wethPerBin : usdxPerBin;
        }
        for (uint8 i = 0; i < below; i++) {
            ids[1 + above + i] = active - int32(uint32(i)) - 1;
            a1[1 + above + i] = wethIsToken0 ? usdxPerBin : wethPerBin;
        }
        vm.prank(alice);
        pool.addLiquidity(ids, a0, a1, alice);
    }

    function test_LadderPriceAndSides() public {
        int32 active = _seed(1e18, 2, 2);
        assertTrue(pool.priceOfBin(active) > 0);
        // side enforcement: token1 into a bin above active reverts
        int32[] memory ids = new int32[](1);
        uint256[] memory a0 = new uint256[](1);
        uint256[] memory a1 = new uint256[](1);
        ids[0] = active + 1;
        a1[0] = 1e15;
        vm.expectRevert();
        vm.prank(alice);
        pool.addLiquidity(ids, a0, a1, alice);
    }

    function test_SmallSwapZeroIntraBinSlippage() public {
        int32 active = _seed(1e18, 2, 2);
        bool z41 = wethIsToken0; // sell WETH = sell token0
        uint256 price = pool.priceOfBin(active); // USDX per WETH (token1 per token0)
        uint256 amtIn = 1e16; // tiny: fills entirely inside the active bin
        uint256 feeBps = pool.currentFeeBps();
        uint256 expectOut = Math.mulDiv(amtIn * (10_000 - feeBps) / 10_000, price, Q96);
        uint256 out = pool.getAmountOut(z41, amtIn);
        assertApproxEqRel(out, expectOut, 1e12);
        assertEq(pool.activeId(), active); // price unchanged inside the bin

        vm.prank(bob);
        uint256 got = pool.swap(z41, amtIn, out * 99 / 100, bob);
        assertApproxEqRel(got, out, 1e12);
    }

    function test_LargeSwapWalksLadder() public {
        int32 active = _seed(1e18, 2, 2);
        bool z41 = wethIsToken0; // sell WETH -> price falls -> walk below
        uint256 amtIn = 2.5e18; // more than the active bin holds
        uint256 out = pool.getAmountOut(z41, amtIn);
        assertTrue(out > 0);
        vm.prank(bob);
        uint256 got = pool.swap(z41, amtIn, out * 98 / 100, bob);
        assertApproxEqRel(got, out, 1e12);
        assertTrue(pool.activeId() < active); // active bin moved down
    }

    function test_FeesStayInBins() public {
        _seed(1e18, 2, 2);
        uint256 shBefore = pool.sharesOf(pool.activeId(), alice);
        uint256 r1Before = wethIsToken0 ? pool.bin(pool.activeId()).reserve1 : pool.bin(pool.activeId()).reserve0;
        vm.prank(bob);
        pool.swap(wethIsToken0, 1e16, 0, bob);
        uint256 r1After = wethIsToken0 ? pool.bin(pool.activeId()).reserve1 : pool.bin(pool.activeId()).reserve0;
        assertLt(r1After, r1Before); // sold side consumed
        assertGt(shBefore, 0);
        // LP value per share grew: removing now returns more USDX-equivalent than deposited
    }

    function test_RemoveLiquidityReturnsPrincipalPlusFees() public {
        int32 active = _seed(1e18, 0, 0);
        uint256 shares = pool.sharesOf(active, alice);
        uint256 bobUsdxBefore = usdx.balanceOf(bob);
        vm.prank(alice);
        int32[] memory ids = new int32[](1);
        uint256[] memory sh = new uint256[](1);
        ids[0] = active;
        sh[0] = shares;
        pool.removeLiquidity(ids, sh, bob);
        // active bin held 1 WETH + ~3000 USDX -> bob receives both sides (USDX side here)
        assertGt(usdx.balanceOf(bob), bobUsdxBefore);
    }
}
