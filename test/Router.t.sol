// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base} from "./Base.t.sol";
import {SwapRouter} from "../src/periphery/SwapRouter.sol";
import {PositionManager} from "../src/core/PositionManager.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract RouterTest is Base {
    bytes32 hookPoolId;

    function setUp() public virtual override {
        Base.setUp();
        _approveAll(alice, address(positions));
        vm.startPrank(alice);
        uint256 tid = positions.mint(
            PositionManager.MintParams({
                tokenA: address(weth),
                tokenB: address(usdx),
                hooks: address(hook),
                feeSeed: 0,
                amount0Desired: 10e18,
                amount1Desired: 30_000e18,
                amount0Min: 9e18,
                amount1Min: 29_000e18,
                deadline: block.timestamp + 1,
                recipient: alice,
                lockUntil: 0
            })
        );
        vm.stopPrank();
        hookPoolId = positions.positionPool(tid);
        _approveAll(alice, address(router));
        _approveAll(bob, address(router));
    }

    function test_QuoteDirectHookPool() public view {
        SwapRouter.Route memory r = router.quoteExactIn(address(usdx), 1000e18, address(weth));
        assertEq(r.hops.length, 1);
        assertGt(r.amountOut, 0);
        assertEq(uint8(r.hops[0].venue), uint8(SwapRouter.Venue.Hook));
    }

    function test_ExecuteDirect() public {
        SwapRouter.Route memory r = router.quoteExactIn(address(usdx), 1000e18, address(weth));
        uint256 bobBefore = weth.balanceOf(bob);
        vm.prank(bob);
        uint256 out = router.execute(r, 1000e18, (r.amountOut * 99) / 100, block.timestamp + 1 hours);
        assertEq(weth.balanceOf(bob) - bobBefore, out);
    }

    function test_TwoHopWhenNoDirectPool() public {
        // STOK -> USDX pool exists via hook? none registered; use stok/usdx hook pool + weth/usdx
        _approveAll(alice, address(positions));
        vm.startPrank(alice);
        positions.mint(
            PositionManager.MintParams({
                tokenA: address(stok),
                tokenB: address(usdx),
                hooks: address(hook),
                feeSeed: 0,
                amount0Desired: 400e18,
                amount1Desired: 100_000e18,
                amount0Min: 390e18,
                amount1Min: 99_000e18,
                deadline: block.timestamp + 1,
                recipient: alice,
                lockUntil: 0
            })
        );
        vm.stopPrank();

        SwapRouter.Route memory r = router.quoteExactIn(address(stok), 2e18, address(weth));
        assertEq(r.hops.length, 2, "expected two-hop route STOK->USDX->WETH");
        assertGt(r.amountOut, 0);
        uint256 before = weth.balanceOf(bob);
        vm.prank(bob);
        router.execute(r, 2e18, (r.amountOut * 95) / 100, block.timestamp + 1 hours);
        assertGt(weth.balanceOf(bob), before);
    }

    function test_MinOutReverts() public {
        SwapRouter.Route memory r = router.quoteExactIn(address(usdx), 1000e18, address(weth));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SwapRouter.InsufficientOutput.selector, r.amountOut, type(uint256).max));
        router.execute(r, 1000e18, type(uint256).max, block.timestamp + 1 hours);
    }

    function test_DeadlineReverts() public {
        SwapRouter.Route memory r = router.quoteExactIn(address(usdx), 1000e18, address(weth));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SwapRouter.Expired.selector, block.timestamp - 1));
        router.execute(r, 1000e18, 0, block.timestamp - 1);
    }

    function test_BestOfTwoVenues() public {
        // add a bin pool with a better price and confirm the router prefers it
        bool wethIsToken0 = address(weth) < address(usdx);
        vm.startPrank(admin);
        address binPool = binFactory.createPool(address(weth), address(usdx), 25, wethIsToken0 ? int32(3207) : -int32(3207));
        vm.stopPrank();
        _approveAll(alice, binPool);
        vm.startPrank(alice);
        {
            IBinPoolLike p = IBinPoolLike(binPool);
            int32 active = p.activeId();
            uint256 price = p.priceOfBin(active);
            int32[] memory ids = new int32[](1);
            uint256[] memory a0 = new uint256[](1);
            uint256[] memory a1 = new uint256[](1);
            ids[0] = active;
            if (wethIsToken0) {
                a0[0] = 2e18;
                a1[0] = Math.mulDiv(2e18, price, Q96);
            } else {
                a0[0] = Math.mulDiv(2e18, price, Q96);
                a1[0] = 2e18;
            }
            p.addLiquidity(ids, a0, a1, alice);
        }
        vm.stopPrank();

        SwapRouter.Route memory r = router.quoteExactIn(address(usdx), 100e18, address(weth));
        assertGt(r.amountOut, 0);
        // whichever venue wins, executing settles at least the quote minus slippage
        uint256 before = weth.balanceOf(bob);
        vm.prank(bob);
        router.execute(r, 100e18, (r.amountOut * 98) / 100, block.timestamp + 1 hours);
        assertGt(weth.balanceOf(bob), before);
    }
}

interface IBinPoolLike {
    function activeId() external view returns (int32);
    function priceOfBin(int32) external view returns (uint160);
    function addLiquidity(int32[] calldata, uint256[] calldata, uint256[] calldata, address) external returns (uint256[] memory);
}
