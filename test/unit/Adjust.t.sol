/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {console} from "forge-std/console.sol";
import {DEFAULT_EXPIRY, SetUp} from "../SetUp.sol";

contract AdjustTest is SetUp {
    function test_adjust_UpdatesReservesAndPrices() public {
        uint256 preLastImpliedPrice = rmm.lastImpliedPrice();

        uint256 preReserveX = rmm.reserveX();
        uint256 preReserveY = rmm.reserveY();
        uint256 preTotalLiquidity = rmm.totalLiquidity();

        (uint256 deltaX, uint256 deltaY, uint256 deltaLiquidity,) = rmm.prepareAllocate(true, 1 ether);
        rmm.adjust(int256(deltaX), int256(deltaY), int256(deltaLiquidity), rmm.strike(), newIndex());

        assertEq(rmm.reserveX(), preReserveX + deltaX);
        assertEq(rmm.reserveY(), preReserveY + deltaY);
        assertEq(rmm.totalLiquidity(), preTotalLiquidity + deltaLiquidity);

        uint256 postLastImpliedPrice = rmm.lastImpliedPrice();

        console.log("preLastImpliedPrice: ", preLastImpliedPrice);
        console.log("postLastImpliedPrice: ", postLastImpliedPrice);
    }
}
