// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base} from "./Base.t.sol";
import {PositionManager} from "../src/core/PositionManager.sol";

contract CreditTest is Base {
    uint256 tokenId;
    uint256 loanId;

    function setUp() public virtual override {
        Base.setUp();
        // lender supplies the vault
        vm.startPrank(admin);
        usdx.mint(admin, 1_000_000e18);
        usdx.approve(address(vault), type(uint256).max);
        vault.deposit(500_000e18, admin);
        vm.stopPrank();

        // alice opens a WETH/USDX hook-pool position worth ~2 ETH + 6k USDX = $12k
        _approveAll(alice, address(positions));
        vm.startPrank(alice);
        tokenId = positions.mint(
            PositionManager.MintParams({
                tokenA: address(weth),
                tokenB: address(usdx),
                hooks: address(hook),
                feeSeed: 0,
                amount0Desired: 2e18,
                amount1Desired: 6_000e18,
                amount0Min: 1.9e18,
                amount1Min: 5_900e18,
                deadline: block.timestamp + 1,
                recipient: alice,
                lockUntil: 0
            })
        );
        positions.approve(address(credit), tokenId);
        positions.safeTransferFrom(alice, address(credit), tokenId);
        vm.stopPrank();
        loanId = credit.loanOf(tokenId);
    }

    function test_PledgeOpensLoan() public {
        assertTrue(credit.pledgedToken(tokenId));
        assertEq(credit.debtOf(loanId), 0);
    }

    function test_BorrowUpToLtv() public {
        uint256 val = credit.valuation(tokenId);
        // valuation ~ 2*3000 + 6000 = 12000 USDX
        assertGt(val, 11_000e18);
        assertLt(val, 13_000e18);

        _approveAll(alice, address(credit));
        vm.prank(alice);
        credit.borrow(loanId, val * 50 / 100); // exactly at LTV
        assertGt(credit.debtOf(loanId), 0);

        vm.prank(alice);
        vm.expectRevert(); // one wei more would exceed LTV
        credit.borrow(loanId, 2e18);
    }

    function test_RepayAndUnpledge() public {
        uint256 val = credit.valuation(tokenId);
        _approveAll(alice, address(credit));
        vm.startPrank(alice);
        credit.borrow(loanId, val * 30 / 100);
        vm.warp(block.timestamp + 30 days); // interest accrues
        uint256 debt = credit.debtOf(loanId);
        assertGt(debt, val * 30 / 100); // interest > 0
        credit.repay(loanId, debt * 2); // capped at outstanding
        assertEq(credit.debtOf(loanId), 0);
        credit.unpledge(loanId);
        assertFalse(credit.pledgedToken(tokenId));
        assertEq(positions.ownerOf(tokenId), alice);
        vm.stopPrank();
    }

    function test_LiquidationWhenUnderwater() public {
        uint256 val = credit.valuation(tokenId);
        _approveAll(alice, address(credit));
        vm.startPrank(alice);
        credit.borrow(loanId, val * 50 / 100);
        vm.stopPrank();

        // crash WETH price: collateral value collapses below liquidation threshold
        vm.startPrank(admin);
        oracle.setPrice(address(weth), 300e18); // -90%
        vm.stopPrank();

        uint256 debt = credit.debtOf(loanId);
        // bob liquidates: pays debt, seizes the NFT
        _approveAll(bob, address(credit));
        vm.prank(bob);
        credit.liquidate(loanId);
        assertEq(positions.ownerOf(tokenId), bob);
        assertFalse(credit.pledgedToken(tokenId));
        assertGt(debt, 0);
    }

    function test_CannotLiquidateHealthy() public {
        uint256 amount = (credit.valuation(tokenId) * 20) / 100;
        _approveAll(alice, address(credit));
        vm.prank(alice);
        credit.borrow(loanId, amount);
        _approveAll(bob, address(credit));
        vm.prank(bob);
        vm.expectRevert();
        credit.liquidate(loanId);
    }
}
