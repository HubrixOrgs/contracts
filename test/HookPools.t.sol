// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base} from "./Base.t.sol";
import {PositionManager} from "../src/core/PositionManager.sol";
import {PoolHook} from "../src/core/PoolHook.sol";

contract HookPoolsTest is Base {
    uint256 ethUsdxTokenId;
    uint256 stokUsdxTokenId;
    bytes32 ethUsdxPoolId;

    function setUp() public virtual override {
        Base.setUp();
        _approveAll(alice, address(positions));
        _approveAll(bob, address(manager));
        _approveAll(bob, address(positions));
        vm.startPrank(alice);
        ethUsdxTokenId = positions.mint(
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
        stokUsdxTokenId = positions.mint(
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
        ethUsdxPoolId = positions.positionPool(ethUsdxTokenId);
    }

    function _swapEthUsdx(bool sellEth, uint256 amountIn) internal returns (uint256 out) {
        (address t0,) = manager.poolTokens(ethUsdxPoolId);
        bool z41 = sellEth ? t0 == address(weth) : t0 == address(usdx);
        address tokenIn = z41 ? t0 : address(weth) == t0 ? address(weth) : address(usdx);
        // determine input token explicitly
        tokenIn = sellEth ? address(weth) : address(usdx);
        z41 = t0 == tokenIn;
        vm.prank(bob);
        out = manager.swap(ethUsdxPoolId, z41, amountIn, 0, bob);
    }

    function test_PoolModes() public view {
        (PoolHook.Mode m1, uint24 base1, uint24 cap1) = hook.poolConfig(ethUsdxPoolId);
        assertEq(uint8(m1), uint8(PoolHook.Mode.DYNAMIC));
        assertEq(uint256(base1), 5);
        assertEq(uint256(cap1), 2000);
        (PoolHook.Mode m2, uint24 base2,) = hook.poolConfig(positions.positionPool(stokUsdxTokenId));
        assertEq(uint8(m2), uint8(PoolHook.Mode.ORACLE_GUARDED));
        assertEq(uint256(base2), 30);
    }

    function test_DynamicFeeStartsAtBase() public {
        // first swap: accumulator 0 -> base fee 5 bps
        uint256 out = _swapEthUsdx(true, 0.01e18);
        assertTrue(out > 0);
        (uint96 acc,,) = hook.volInfo(ethUsdxPoolId);
        assertTrue(acc > 0); // volatility registered
    }

    function test_DynamicFeeRisesWithVolatility() public {
        _swapEthUsdx(true, 0.5e18);
        _swapEthUsdx(false, 1500e18);
        _swapEthUsdx(true, 0.5e18);
        (uint96 acc,,) = hook.volInfo(ethUsdxPoolId);
        assertTrue(acc > 1e16); // >1% accumulated movement
        // fee now above base
        (, uint24 base,) = hook.poolConfig(ethUsdxPoolId);
        (, uint24 fee) = manager.getAmountOut(ethUsdxPoolId, true, 0.01e18);
        assertGt(fee, base);
    }

    function test_FeesCollectible() public {
        _swapEthUsdx(true, 1e18);
        (, uint256 a0,, uint256 owed0, uint256 owed1) = positions.positionAmounts(ethUsdxTokenId);
        (a0);
        assertTrue(owed0 > 0 || owed1 > 0);
        vm.prank(alice);
        (uint256 c0, uint256 c1) = positions.collect(ethUsdxTokenId, alice);
        assertTrue(c0 > 0 || c1 > 0);
    }

    function test_OracleGuardBlocksStaleFeed() public {
        bytes32 stockPoolId = positions.positionPool(stokUsdxTokenId);
        (address t0,) = manager.poolTokens(stockPoolId);
        vm.warp(block.timestamp + 25 hours); // oracle older than 24h
        vm.prank(bob);
        vm.expectRevert(PoolHook.OracleStale.selector);
        manager.swap(stockPoolId, t0 == address(stok), 1e18, 0, bob);
        // but liquidity removal still works (exits never require the oracle)
        uint128 liq = positions.position(stokUsdxTokenId).liquidity / 10;
        vm.startPrank(alice);
        positions.removeLiquidity(
            PositionManager.RemoveParams({
                tokenId: stokUsdxTokenId,
                liquidity: liq,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();
    }

    function test_CircuitBreakerBlocksFarTrades() public {
        bytes32 stockPoolId = positions.positionPool(stokUsdxTokenId);
        // break the oracle far from pool price: stock worth 1 USDX instead of 250
        vm.startPrank(admin);
        oracle.setPrice(address(stok), 1e18); // oracle deviation >> 10%
        vm.stopPrank();
        (address t0,) = manager.poolTokens(stockPoolId);
        vm.prank(bob);
        vm.expectRevert();
        manager.swap(stockPoolId, t0 == address(stok), 1e18, 0, bob);
    }

    function test_LocksAndVesting() public {
        vm.startPrank(alice);
        positions.lock(ethUsdxTokenId, type(uint64).max);
        vm.expectRevert(abi.encodeWithSelector(PositionManager.PositionLocked.selector, ethUsdxTokenId, type(uint64).max));
        positions.removeLiquidity(
            PositionManager.RemoveParams({
                tokenId: ethUsdxTokenId,
                liquidity: 1e10,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1
            })
        );
        // collect still allowed while locked
        positions.collect(ethUsdxTokenId, alice);
        // vesting: cliff blocks principal, releases over time
        positions.setVesting(ethUsdxTokenId, uint64(block.timestamp + 10 days), 10 days);
        assertEq(positions.withdrawablePrincipal(ethUsdxTokenId), 0);
        vm.warp(block.timestamp + 15 days); // halfway
        uint128 vested = positions.vestedPrincipal(ethUsdxTokenId);
        assertGt(vested, 0);
        vm.stopPrank();
    }
}
