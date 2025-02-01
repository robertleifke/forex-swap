/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {SetUp} from "../SetUp.sol";

contract MintSYTest is SetUp {
    function test_mintSY_MintsSYUsingETH() public useDefaultPool {
        deal(address(this), 1 ether);
        rmm.mintSY{value: 1 ether}(address(0xbeef), address(0), 1 ether, 0);
        assertEq(SY.balanceOf(address(0xbeef)), 1 ether);
    }

    function test_mintSY_MintsSYUsingWETH() public useDefaultPool withWETH(address(this), 1 ether) {
        rmm.mintSY(address(0xbeef), address(weth), 1 ether, 0);
        assertEq(SY.balanceOf(address(0xbeef)), 1 ether);
    }
}
