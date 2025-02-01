/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {SetUp, RMM, InitParams, DEFAULT_NAME, DEFAULT_SYMBOL, DEFAULT_EXPIRY} from "../SetUp.sol";

contract ConstructorTest is SetUp {
    function test_constructor_InitializesParameters() public view {
        InitParams memory initParams = getDefaultParams();

        assertEq(rmm.name(), DEFAULT_NAME);
        assertEq(rmm.symbol(), DEFAULT_SYMBOL);
        assertEq(address(rmm.PT()), address(PT));
        assertEq(address(rmm.SY()), address(SY));
        assertEq(address(rmm.YT()), address(YT));
        assertEq(rmm.sigma(), initParams.sigma);
        assertEq(rmm.fee(), initParams.fee);
        assertEq(rmm.maturity(), DEFAULT_EXPIRY);
    }
}
