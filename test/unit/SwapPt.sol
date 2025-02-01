/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {PYIndex, IPYieldToken} from "./../../src/RMM.sol";
import {SetUp, RMM} from "../SetUp.sol";
import {Swap} from "../../src/lib/RmmEvents.sol";
import {InsufficientOutput} from "../../src/lib/RmmErrors.sol";

contract SwapPtTest is SetUp {
    function test_swapPt_AdjustsPool() public useDefaultPool withSY(address(this), 1_000 ether) {
        (uint256 deltaXWad, uint256 deltaYWad, uint256 deltaLiquidity,) =
            rmm.prepareAllocate(true, 1 ether);
        rmm.allocate(true, 1 ether, deltaLiquidity, address(this));

        PYIndex index = PYIndex.wrap(YT.pyIndexCurrent());
        uint256 amountIn = 1 ether;
        (,, uint256 minAmountOut,,) = rmm.prepareSwapPtIn(amountIn, block.timestamp, index);

        uint256 preReserveX = rmm.reserveX();
        uint256 preReserveY = rmm.reserveY();

        (uint256 amountOut,) = rmm.swapExactPtForSy(amountIn, minAmountOut, address(this));

        assertEq(rmm.reserveX(), preReserveX - amountOut);
        assertEq(rmm.reserveY(), preReserveY + amountIn);
    }

    function test_swapPt_TransfersTokens() public useDefaultPool withSY(address(this), 1_000 ether) {
        (uint256 deltaXWad, uint256 deltaYWad, uint256 deltaLiquidity,) =
            rmm.prepareAllocate(true, 1 ether);
        rmm.allocate(true, 1 ether, deltaLiquidity, address(this));

        PYIndex index = PYIndex.wrap(YT.pyIndexCurrent());
        uint256 amountIn = 1 ether;
        (,, uint256 minAmountOut,,) = rmm.prepareSwapPtIn(amountIn, block.timestamp, index);

        uint256 preRMMBalanceX = SY.balanceOf(address(rmm));
        uint256 preRMMBalanceY = PT.balanceOf(address(rmm));
        uint256 preBalanceX = SY.balanceOf(address(this));
        uint256 preBalanceY = PT.balanceOf(address(this));

        (uint256 amountOut,) = rmm.swapExactPtForSy(amountIn, minAmountOut, address(this));

        assertEq(preBalanceX + amountOut, SY.balanceOf(address(this)));
        assertEq(preBalanceY - amountIn, PT.balanceOf(address(this)));
        assertEq(preRMMBalanceX - amountOut, SY.balanceOf(address(rmm)));
        assertEq(preRMMBalanceY + amountIn, PT.balanceOf(address(rmm)));
    }

    function test_swapPt_EmitsSwap() public useDefaultPool withSY(address(this), 1_000 ether) {
        (uint256 deltaXWad, uint256 deltaYWad, uint256 deltaLiquidity,) =
            rmm.prepareAllocate(true, 1 ether);
        rmm.allocate(true, 1 ether, deltaLiquidity, address(this));

        PYIndex index = PYIndex.wrap(YT.pyIndexCurrent());
        uint256 amountIn = 1 ether;
        (,, uint256 minAmountOut, int256 deltaLiquiditySwap,) = rmm.prepareSwapPtIn(amountIn, block.timestamp, index);
        vm.expectEmit(true, true, true, true);

        emit Swap(address(this), address(this), address(PT), address(SY), amountIn, minAmountOut, deltaLiquiditySwap);
        rmm.swapExactPtForSy(amountIn, minAmountOut, address(this));
    }

    function test_swapPt_RevertsWhenInsufficientOutput() public useDefaultPool withSY(address(this), 1_000 ether) {
        (uint256 deltaXWad, uint256 deltaYWad, uint256 deltaLiquidity,) =
            rmm.prepareAllocate(true, 1 ether);
        rmm.allocate(true, 1 ether, deltaLiquidity, address(this));

        PYIndex index = PYIndex.wrap(YT.pyIndexCurrent());
        uint256 amountIn = 1 ether;
        (,, uint256 minAmountOut,,) = rmm.prepareSwapPtIn(amountIn, block.timestamp, index);
        vm.expectRevert(abi.encodeWithSelector(InsufficientOutput.selector, amountIn, minAmountOut + 1, minAmountOut));
        rmm.swapExactPtForSy(amountIn, minAmountOut + 1, address(this));
    }
}
