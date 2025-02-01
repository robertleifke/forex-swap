/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {SetUp} from "../SetUp.sol";

contract CreditTest is SetUp {
    function test_credit_TransfersTokens() public {
        deal(address(weth), address(rmm), 1 ether);

        uint256 preBalanceRMM = weth.balanceOf(address(rmm));
        uint256 preBalanceAccount = weth.balanceOf(address(this));

        rmm.credit(address(weth), address(this), 1 ether);

        assertEq(weth.balanceOf(address(rmm)), preBalanceRMM - 1 ether);
        assertEq(weth.balanceOf(address(this)), preBalanceAccount + 1 ether);
    }

    function test_credit_DownscalesAmount() public {
        MockERC20 token = new MockERC20("", "", 6);

        uint256 amountWAD = 1 ether;
        uint256 amountNative = 1 * 10 ** 6;

        token.mint(address(rmm), amountNative);

        uint256 preBalanceRMM = token.balanceOf(address(rmm));
        uint256 preBalanceUser = token.balanceOf(address(this));

        rmm.credit(address(token), address(this), amountWAD);

        assertEq(token.balanceOf(address(rmm)), preBalanceRMM - amountNative);
        assertEq(token.balanceOf(address(this)), preBalanceUser + amountNative);
    }
}
