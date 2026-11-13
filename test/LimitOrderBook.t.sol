// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base} from "./Base.t.sol";
import {LimitOrderBook} from "../src/periphery/LimitOrderBook.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IBinPoolT {
    function activeId() external view returns (int32);
    function priceOfBin(int32) external view returns (uint160);
    function addLiquidity(int32[] calldata, uint256[] calldata, uint256[] calldata, address)
        external
        returns (uint256[] memory);
    function swap(bool, uint256, uint256, address) external returns (uint256);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

contract LimitOrderBookTest is Base {
    IBinPoolT pool;
    bool wethIsToken0;

    function setUp() public virtual override {
        Base.setUp();
        wethIsToken0 = address(weth) < address(usdx);
        vm.startPrank(admin);
        pool = IBinPoolT(binFactory.createPool(address(weth), address(usdx), 25, wethIsToken0 ? int32(3207) : -int32(3207)));
        vm.stopPrank();
        _approveAll(alice, address(pool));
        _approveAll(alice, address(lob));
        _approveAll(bob, address(pool));
        _approveAll(bob, address(lob));
        _approveAll(keeper, address(lob));
        _seed();
    }

    function _seed() internal {
        uint256 price = pool.priceOfBin(pool.activeId());
        int32[] memory ids = new int32[](1);
        uint256[] memory a0 = new uint256[](1);
        uint256[] memory a1 = new uint256[](1);
        ids[0] = pool.activeId();
        if (wethIsToken0) {
            a0[0] = 5e18;
            a1[0] = Math.mulDiv(5e18, price, Q96);
        } else {
            a0[0] = Math.mulDiv(5e18, price, Q96);
            a1[0] = 5e18;
        }
        vm.prank(alice);
        pool.addLiquidity(ids, a0, a1, alice);
    }

    function test_PlaceAndCancel() public {
        int32 active = pool.activeId();
        vm.prank(alice);
        uint256 oid = wethIsToken0
            ? lob.place(address(pool), active + 1, true, 0.1e18, 10)
            : lob.place(address(pool), active - 1, false, 0.1e18, 10);
        assertFalse(lob.filled(oid));
        vm.prank(alice);
        lob.cancel(oid);
        LimitOrderBook.Order memory o = _order(oid);
        assertFalse(o.active);
    }

    function test_FillAndClaim() public {
        int32 active = pool.activeId();
        vm.prank(alice);
        uint256 oid = wethIsToken0
            ? lob.place(address(pool), active + 1, true, 0.1e18, 10)
            : lob.place(address(pool), active - 1, false, 0.1e18, 10);

        // drive the market across the order bin: buy WETH hard with USDX
        if (wethIsToken0) {
            // WETH = token0; price rises when token1 (USDX) is sold in -> zeroForOne = false
            vm.startPrank(bob);
            usdx.transfer(bob, 0);
            pool.swap(false, Math.mulDiv(4e18, pool.priceOfBin(active), Q96) * 2, 0, bob);
            vm.stopPrank();
        } else {
            // WETH = token1; price falls when token0 (USDX) is sold in -> zeroForOne = true
            vm.prank(bob);
            pool.swap(true, Math.mulDiv(4e18, pool.priceOfBin(active), Q96) * 2, 0, bob);
            vm.stopPrank();
        }
        assertTrue(lob.filled(oid));

        // keeper claims: owner gets proceeds minus 10 bps keeper fee
        vm.prank(keeper);
        lob.claim(oid);
        LimitOrderBook.Order memory o = _order(oid);
        assertFalse(o.active);
    }

    function _order(uint256 oid) internal view returns (LimitOrderBook.Order memory) {
        return lob.order(oid);
    }
}
