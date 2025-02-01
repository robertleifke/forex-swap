/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {SetUp} from "../SetUp.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {FeeOnTransferToken} from "../../src/test/FeeOnTransferToken.sol";
import {InsufficientPayment} from "./../../src/lib/RmmErrors.sol";

contract DebitTest is SetUp {
    function test_debit_TransfersTokens() public {
        MockERC20 token = new MockERC20("", "", 18);

        uint256 amount = 1 ether;

        token.mint(address(this), amount);
        token.approve(address(rmm), amount);

        uint256 preBalanceRMM = token.balanceOf(address(rmm));
        uint256 preBalanceUser = token.balanceOf(address(this));

        rmm.debit(address(token), amount);

        assertEq(token.balanceOf(address(rmm)), preBalanceRMM + amount);
        assertEq(token.balanceOf(address(this)), preBalanceUser - amount);
    }

    function test_debit_DownscalesAmount() public {
        MockERC20 token = new MockERC20("", "", 6);

        uint256 amountWAD = 1 ether;
        uint256 amountNative = 1 * 10 ** 6;

        token.mint(address(this), amountNative);
        token.approve(address(rmm), amountNative);

        uint256 preBalanceRMM = token.balanceOf(address(rmm));
        uint256 preBalanceUser = token.balanceOf(address(this));

        rmm.debit(address(token), amountWAD);

        assertEq(token.balanceOf(address(rmm)), preBalanceRMM + amountNative);
        assertEq(token.balanceOf(address(this)), preBalanceUser - amountNative);
    }

    function test_debit_RevertsInsufficientPayment() public {
        FeeOnTransferToken token = new FeeOnTransferToken();

        uint256 amount = 1 ether;

        token.mint(address(this), amount);
        token.approve(address(rmm), amount);

        vm.expectRevert(
            abi.encodeWithSelector(InsufficientPayment.selector, address(token), amount - token.transferFee(), amount)
        );

        rmm.debit(address(token), amount);
    }
}
