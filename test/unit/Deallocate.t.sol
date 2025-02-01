/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {PYIndex} from "./../../src/RMM.sol";
import {SetUp, RMM} from "../SetUp.sol";
import {Deallocate} from "../../src/lib/RmmEvents.sol";
import {InsufficientOutput} from "../../src/lib/RmmErrors.sol";

contract DeallocateTest is SetUp {
    function test_deallocate_BurnsLiquidity() public useDefaultPool {
        (uint256 deltaXWad, uint256 deltaYWad, uint256 deltaLiquidity,) =
            rmm.prepareAllocate(true, 0.1 ether);

        deltaLiquidity = rmm.allocate(true, 0.1 ether, deltaLiquidity, address(this));

        uint256 lptBurned;
        (deltaXWad, deltaYWad, lptBurned) = rmm.prepareDeallocate(deltaLiquidity / 2);

        uint256 preTotalLiquidity = rmm.totalLiquidity();
        rmm.deallocate(deltaLiquidity / 2, 0, 0, address(this));
        assertEq(rmm.totalLiquidity(), preTotalLiquidity - deltaLiquidity / 2);
    }

    function test_deallocate_AdjustsPool() public useDefaultPool withSY(address(this), 1_000 ether) {
        (uint256 deltaXWad, uint256 deltaYWad, uint256 deltaLiquidity,) =
            rmm.prepareAllocate(true, 0.1 ether);

        deltaLiquidity = rmm.allocate(true, 0.1 ether, deltaLiquidity, address(this));

        uint256 lptBurned;
        (deltaXWad, deltaYWad, lptBurned) = rmm.prepareDeallocate(deltaLiquidity / 2);

        uint256 preReserveX = rmm.reserveX();
        uint256 preReserveY = rmm.reserveY();

        rmm.deallocate(deltaLiquidity / 2, 0, 0, address(this));
        assertEq(rmm.reserveX(), preReserveX - deltaXWad);
        assertEq(rmm.reserveY(), preReserveY - deltaYWad);
        assertEq(rmm.lastTimestamp(), block.timestamp);
    }

    function test_deallocate_TransfersTokens() public useDefaultPool withSY(address(this), 1_000 ether) {
        (uint256 deltaXWad, uint256 deltaYWad, uint256 deltaLiquidity,) =
            rmm.prepareAllocate(true, 0.1 ether);
        deltaLiquidity = rmm.allocate(true, 0.1 ether, deltaLiquidity, address(this));
        uint256 lptBurned;

        uint256 thisPreBalanceSY = SY.balanceOf(address(this));
        uint256 thisPreBalancePT = PT.balanceOf(address(this));
        uint256 rmmPreBalanceSY = SY.balanceOf(address(rmm));
        uint256 rmmPreBalancePT = PT.balanceOf(address(rmm));

        (deltaXWad, deltaYWad, lptBurned) = rmm.prepareDeallocate(deltaLiquidity / 2);
        rmm.deallocate(deltaLiquidity / 2, 0, 0, address(this));

        assertEq(SY.balanceOf(address(this)), thisPreBalanceSY + deltaXWad);
        assertEq(PT.balanceOf(address(this)), thisPreBalancePT + deltaYWad);
        assertEq(SY.balanceOf(address(rmm)), rmmPreBalanceSY - deltaXWad);
        assertEq(PT.balanceOf(address(rmm)), rmmPreBalancePT - deltaYWad);
    }

    function test_deallocate_EmitsDeallocate() public useDefaultPool withSY(address(this), 1_000 ether) {
        (uint256 deltaXWad, uint256 deltaYWad, uint256 deltaLiquidity,) =
            rmm.prepareAllocate(true, 0.1 ether);
        deltaLiquidity = rmm.allocate(true, 0.1 ether, deltaLiquidity, address(this));
        uint256 lptBurned;

        (deltaXWad, deltaYWad, lptBurned) = rmm.prepareDeallocate(deltaLiquidity / 2);

        vm.expectEmit(true, true, true, true);
        emit Deallocate(address(this), address(this), deltaXWad, deltaYWad, deltaLiquidity / 2);
        rmm.deallocate(deltaLiquidity / 2, 0, 0, address(this));
    }

    function test_deallocate_RevertsIfInsufficientSYOutput() public useDefaultPool withSY(address(this), 1_000 ether) {
        (uint256 deltaXWad, uint256 deltaYWad, uint256 deltaLiquidity,) =
            rmm.prepareAllocate(true, 0.1 ether);
        deltaLiquidity = rmm.allocate(true, 0.1 ether, deltaLiquidity, address(this));
        uint256 lptBurned;

        (deltaXWad, deltaYWad, lptBurned) = rmm.prepareDeallocate(deltaLiquidity / 2);
        vm.expectRevert(
            abi.encodeWithSelector(InsufficientOutput.selector, deltaLiquidity / 2, deltaXWad + 1, deltaXWad)
        );
        rmm.deallocate(deltaLiquidity / 2, deltaXWad + 1, 0, address(this));
    }

    function test_deallocate_RevertsIfInsufficientPTOutput() public useDefaultPool withSY(address(this), 1_000 ether) {
        (uint256 deltaXWad, uint256 deltaYWad, uint256 deltaLiquidity,) =
            rmm.prepareAllocate(true, 0.1 ether);
        deltaLiquidity = rmm.allocate(true, 0.1 ether, deltaLiquidity, address(this));
        uint256 lptBurned;

        (deltaXWad, deltaYWad, lptBurned) = rmm.prepareDeallocate(deltaLiquidity / 2);
        vm.expectRevert(
            abi.encodeWithSelector(InsufficientOutput.selector, deltaLiquidity / 2, deltaYWad + 1, deltaYWad)
        );
        rmm.deallocate(deltaLiquidity / 2, 0, deltaYWad + 1, address(this));
    }
}
