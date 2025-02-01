/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {SetUp} from "../SetUp.sol";

contract StrikeTest is SetUp {
    function test_strike_OneAtMaturity_IncreasesOverTime() public useDefaultPool {
        vm.warp(rmm.maturity());
        rmm.swapExactSyForPt(1 ether, 0, address(this));
        assertEq(rmm.strike(), 1 ether);
    }
}
