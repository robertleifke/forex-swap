/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {console} from "forge-std/Test.sol";
import {PYIndexLib, IPYieldToken} from "pendle/core/StandardizedYield/PYIndex.sol";
import {SetUp} from "../SetUp.sol";
import "forge-std/console2.sol";

contract SwapExactYtForSyTest is SetUp {
    using PYIndexLib for IPYieldToken;

    function test_swapExactYtForSy_TransfersTokens() public useSYPool withPY(address(this), 10 ether) {
        address to = address(0xbeef);

        uint256 preYTBalance = ERC20(address(YT)).balanceOf(address(this));
        uint256 preSYBalance = ERC20(address(SY)).balanceOf(to);

        uint256 preSYBalanceRMM = ERC20(address(SY)).balanceOf(address(rmm));
        uint256 preYTBalanceRMM = ERC20(address(YT)).balanceOf(address(rmm));

        (uint256 amountInWad, uint256 amountOutWad, uint256 amountIn, int256 deltaLiquidity, uint256 strike_) =
            rmm.prepareSwapSyForExactPt(1 ether, block.timestamp, YT.newIndex());

        (uint256 amountOut, uint256 exactAmountIn,) = rmm.swapExactYtForSy(1 ether, 1000 ether, address(to));

        assertEq(ERC20(address(YT)).balanceOf(address(this)), preYTBalance - 1 ether);
        assertEq(ERC20(address(SY)).balanceOf(to), preSYBalance + amountOut);
        assertEq(ERC20(address(SY)).balanceOf(address(rmm)), preSYBalanceRMM + amountInWad);
    }
}
