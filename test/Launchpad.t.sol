// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base} from "./Base.t.sol";
import {TokenLaunchpad} from "../src/periphery/TokenLaunchpad.sol";
import {PositionManager} from "../src/core/PositionManager.sol";

contract LaunchpadTest is Base {
    uint256 launchId;

    function setUp() public virtual override {
        Base.setUp();
        vm.deal(alice, 1000 ether);
        vm.startPrank(alice);
        launchId = launchpad.create("Test Launch", "TST", 0.5 ether); // low threshold for tests
        vm.stopPrank();
    }

    function test_CurveBuyRaisesAndIncreasesPrice() public {
        uint256 p0 = launchpad.price(launchId);
        vm.deal(bob, 100 ether);
        vm.startPrank(bob);
        uint256 tokens = launchpad.buy{value: 0.1 ether}(launchId, 0, block.timestamp + 1);
        vm.stopPrank();
        assertGt(tokens, 0);
        TokenLaunchpad.Launch memory l = launchpad.launch(launchId);
        assertApproxEqRel(l.realEth, 0.1 ether * 99 / 100, 1e15); // fee removed
        assertGt(launchpad.price(launchId), p0);
    }

    function test_GraduationLocksLiquidityForever() public {
        vm.deal(bob, 100 ether);
        vm.startPrank(bob);
        launchpad.buy{value: 0.3 ether}(launchId, 0, block.timestamp + 1);
        vm.stopPrank();
        vm.prank(alice);
        launchpad.buy{value: 0.21 ether}(launchId, 0, block.timestamp + 1); // crosses the 0.5 ETH threshold

        vm.prank(bob);
        launchpad.graduate(launchId);
        TokenLaunchpad.Launch memory l = launchpad.launch(launchId);
        assertTrue(l.graduated);
        assertGt(l.positionTokenId, 0);

        // the graduation position is permanently locked
        PositionManager.PositionInfo memory p = positions.position(l.positionTokenId);
        assertEq(p.lockUntil, type(uint64).max);
        assertGt(p.liquidity, 0);
    }

    function test_CreatorClaimsCurveFees() public {
        vm.deal(bob, 100 ether);
        vm.prank(bob);
        launchpad.buy{value: 0.1 ether}(launchId, 0, block.timestamp + 1);
        TokenLaunchpad.Launch memory l = launchpad.launch(launchId);
        assertGt(l.creatorFeePot, 0);
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        launchpad.claimCreatorPot(launchId);
        assertGt(alice.balance, aliceBefore);
    }

    function test_CannotGraduateBeforeThreshold() public {
        vm.deal(bob, 100 ether);
        vm.prank(bob);
        launchpad.buy{value: 0.1 ether}(launchId, 0, block.timestamp + 1);
        vm.prank(bob);
        vm.expectRevert();
        launchpad.graduate(launchId);
    }
}
