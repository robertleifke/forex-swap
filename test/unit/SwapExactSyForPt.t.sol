/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {SetUp} from "../SetUp.sol";
import {Swap} from "../../src/lib/RmmEvents.sol";
import {InsufficientOutput} from "../../src/lib/RmmErrors.sol";
import {abs, computeSpotPrice} from "./../../src/lib/RmmLib.sol";

contract SwapExactSyForPtTest is SetUp {
    function test_swapExactSyForPt_TransfersTokens() public useDefaultPool {
        address to = address(0xbeef);

        deal(address(SY), address(this), 1 ether);

        uint256 preSYBalance = ERC20(address(SY)).balanceOf(address(this));
        uint256 prePTBalance = ERC20(address(PT)).balanceOf(to);

        uint256 preSYBalanceRMM = ERC20(address(SY)).balanceOf(address(rmm));
        uint256 prePTBalanceRMM = ERC20(address(PT)).balanceOf(address(rmm));

        uint256 amountIn = 1 ether;
        (uint256 amountOut,) = rmm.swapExactSyForPt(amountIn, 0, address(to));

        assertEq(ERC20(address(SY)).balanceOf(address(this)), preSYBalance - amountIn);
        assertEq(ERC20(address(PT)).balanceOf(address(to)), prePTBalance + amountOut);
        assertEq(ERC20(address(SY)).balanceOf(address(rmm)), preSYBalanceRMM + amountIn);
        assertEq(ERC20(address(PT)).balanceOf(address(rmm)), prePTBalanceRMM - amountOut);
    }

    function test_swapExactSyForPt_Adjusts() public useDefaultPool {
        address to = address(0xbeef);
        deal(address(SY), address(this), 1 ether);

        uint256 preReserveX = rmm.reserveX();
        uint256 preReserveY = rmm.reserveY();
        uint256 preTotalLiquidity = rmm.totalLiquidity();

        uint256 amountIn = 1 ether;
        (uint256 amountOut, int256 deltaLiquidity) = rmm.swapExactSyForPt(amountIn, 0, address(to));

        assertEq(rmm.reserveX(), preReserveX + amountIn);
        assertEq(rmm.reserveY(), preReserveY - amountOut);
        assertEq(rmm.totalLiquidity(), preTotalLiquidity + uint256(deltaLiquidity));
    }

    function test_swapExactSyForPt_MaintainsTradingFunction() public useDefaultPool {
        uint256 amountIn = 1 ether;
        rmm.swapExactSyForPt(amountIn, 0, address(this));
        assertTrue(abs(rmm.tradingFunction(newIndex())) < 100, "Trading function invalid");
    }

    function test_swapExactSyForPt_MaintainsPrice() public useDefaultPool {
        uint256 amountIn = 1 ether;
        uint256 prevPrice = computeSpotPrice(syToAsset(rmm.reserveX()), rmm.totalLiquidity(), rmm.strike(), rmm.sigma(), rmm.lastTau());
        rmm.swapExactSyForPt(amountIn, 0, address(this));
        assertTrue(computeSpotPrice(syToAsset(rmm.reserveX()), rmm.totalLiquidity(), rmm.strike(), rmm.sigma(), rmm.lastTau()) < prevPrice, "Price did not increase after buying Y.");
    }

    function test_swapExactSyForPt_EmitsEvent() public useDefaultPool {
        uint256 deltaSy = 1 ether;
        (,, uint256 minAmountOut, int256 deltaLiquidity,) = rmm.prepareSwapSyIn(deltaSy, block.timestamp, newIndex());
        vm.expectEmit(true, true, true, true);
        emit Swap(address(this), address(this), address(SY), address(PT), deltaSy, minAmountOut, deltaLiquidity);
        rmm.swapExactSyForPt(deltaSy, minAmountOut, address(this));
    }

    function test_swapExactSyForPt_RevertsIfInsufficientOutput() public useDefaultPool {
        uint256 deltaSy = 1 ether;
        (,, uint256 minAmountOut,,) = rmm.prepareSwapSyIn(deltaSy, block.timestamp, newIndex());
        vm.expectRevert(abi.encodeWithSelector(InsufficientOutput.selector, deltaSy, minAmountOut + 10, minAmountOut));
        rmm.swapExactSyForPt(deltaSy, minAmountOut + 10, address(this));
    }
}
