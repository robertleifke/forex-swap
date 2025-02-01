/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {PYIndexLib, IPYieldToken, PYIndex} from "pendle/core/StandardizedYield/PYIndex.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {SetUp} from "../SetUp.sol";
import {ExcessInput} from "../../src/lib/RmmErrors.sol";
import {Swap} from "../../src/lib/RmmEvents.sol";

contract SwapExactSyForYtTest is SetUp {
    using FixedPointMathLib for uint256;
    using FixedPointMathLib for int256;

    struct State {
        uint256 exactSYIn;
        PYIndex index;
        uint256 ytOut;
        uint256 delta;
        uint256 amountOut;
        address to;
    }

    function test_swapExactSyForYt_TransfersTokens() public useSYPool withSY(address(this), 10 ether) {
        State memory state;
        state.to = address(0xbeef);
        state.exactSYIn = 1 ether;
        state.index = newIndex();

        uint256[] memory preBalances = new uint256[](3);
        preBalances[0] = ERC20(address(SY)).balanceOf(address(this));
        preBalances[1] = ERC20(address(YT)).balanceOf(state.to);
        preBalances[2] = ERC20(address(SY)).balanceOf(address(rmm));

        state.ytOut = rmm.computeSYToYT(state.index, state.exactSYIn, 0, block.timestamp, 0, 10_000);
        (uint256 amountInWad, uint256 amountOutWad,,,) = rmm.prepareSwapPtIn(state.ytOut, block.timestamp, state.index);
        state.delta = amountInWad - amountOutWad;
        (uint256 amtOut,) = rmm.swapExactSyForYt(
            state.exactSYIn, state.ytOut, state.ytOut.mulDivDown(95, 100), state.ytOut, 10_000, state.to
        );

        assertEq(ERC20(address(SY)).balanceOf(address(this)), preBalances[0] - state.delta);
        assertEq(ERC20(address(YT)).balanceOf(state.to), preBalances[1] + amtOut);
        assertEq(ERC20(address(SY)).balanceOf(address(rmm)), preBalances[2] - amountOutWad);
    }

    function test_swapExactSyForYt_AdjustsReserves() public useSYPool withSY(address(this), 10 ether) {
        uint256 preReserveX = rmm.reserveX();
        uint256 preReserveY = rmm.reserveY();
        uint256 preTotalLiquidity = rmm.totalLiquidity();

        uint256 exactSYIn = 1 ether;
        uint256 ytOut = rmm.computeSYToYT(newIndex(), exactSYIn, 0, block.timestamp, 0, 10_000);
        (uint256 amountInWad, uint256 amountOutWad,, int256 deltaLiquidity,) =
            rmm.prepareSwapPtIn(ytOut, block.timestamp, newIndex());
        rmm.swapExactSyForYt(exactSYIn, ytOut, ytOut.mulDivDown(95, 100), ytOut, 10_000, address(this));

        assertEq(rmm.reserveX(), preReserveX - amountOutWad);
        assertEq(rmm.reserveY(), preReserveY + amountInWad);
        assertEq(rmm.totalLiquidity(), preTotalLiquidity + uint256(deltaLiquidity));
    }

    function test_swapExactSyForYt_EmitsEvent() public useSYPool withSY(address(this), 10 ether) {
        uint256 exactSYIn = 1 ether;
        uint256 ytOut = rmm.computeSYToYT(newIndex(), exactSYIn, 0, block.timestamp, 0, 10_000);
        (uint256 amountInWad, uint256 amountOutWad, uint256 amountOut, int256 deltaLiquidity,) =
            rmm.prepareSwapPtIn(ytOut, block.timestamp, newIndex());

        uint256 delta = assetToSyUp(amountInWad) - amountOutWad;
        vm.expectEmit();
        emit Swap(address(this), address(0xbeef), address(SY), address(YT), delta, amountOut, deltaLiquidity);
        rmm.swapExactSyForYt(exactSYIn, ytOut, ytOut.mulDivDown(95, 100), ytOut, 10_000, address(0xbeef));
    }

    function test_swapExactSyForYt_RevertsWhenExcessInput() public useSYPool withSY(address(this), 10 ether) {
        uint256 exactSYIn = 1 ether;
        uint256 ytOut = rmm.computeSYToYT(newIndex(), exactSYIn, 0, block.timestamp, 0, 10_000);
        (, uint256 amountOutWad,,,) = rmm.prepareSwapPtIn(ytOut, block.timestamp, newIndex());

        vm.expectRevert();
        rmm.swapExactSyForYt(exactSYIn - 1 ether, ytOut, amountOutWad, ytOut, 10_000, address(this));
    }

    function test_swapExactSyForYt_RevertsWhenInsufficientOutput() public useSYPool withSY(address(this), 10 ether) {
        uint256 exactSYIn = 1 ether;
        uint256 ytOut = rmm.computeSYToYT(newIndex(), exactSYIn, 0, block.timestamp, 0, 10_000);
        (, uint256 amountOutWad,,,) = rmm.prepareSwapPtIn(ytOut, block.timestamp, newIndex());

        vm.expectRevert();
        rmm.swapExactSyForYt(exactSYIn, ytOut, amountOutWad + 1 ether, ytOut, 10_000, address(this));
    }
}
