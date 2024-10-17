// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.13;

import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

using FixedPointMathLib for uint256;
using FixedPointMathLib for int256;

function computeDeltaLGivenDeltaX(uint256 deltaX, uint256 liquidity, uint256 reserveX) pure returns (uint256 deltaL) {
    return liquidity.mulDivDown(deltaX, reserveX);
}

function computeDeltaLGivenDeltaY(uint256 deltaY, uint256 liquidity, uint256 reserveY) pure returns (uint256 deltaL) {
    return liquidity.mulDivDown(deltaY, reserveY);
}

function computeDeltaYGivenDeltaX(uint256 deltaX, uint256 reserveX, uint256 reserveY) pure returns (uint256 deltaY) {
    return reserveY.mulDivUp(deltaX, reserveX);
}

function computeDeltaXGivenDeltaY(uint256 deltaY, uint256 reserveX, uint256 reserveY) pure returns (uint256 deltaX) {
    return reserveX.mulDivUp(deltaY, reserveY);
}

function computeDeltaXGivenDeltaL(uint256 deltaL, uint256 liquidity, uint256 reserveX) pure returns (uint256 deltaX) {
    return reserveX.mulDivUp(deltaL, liquidity);
}

function computeDeltaYGivenDeltaL(uint256 deltaL, uint256 liquidity, uint256 reserveY) pure returns (uint256 deltaX) {
    return reserveY.mulDivUp(deltaL, liquidity);
}

function computeAllocationGivenDeltaX(uint256 deltaX, uint256 reserveX, uint256 reserveY, uint256 liquidity)
    pure
    returns (uint256 deltaY, uint256 deltaL)
{
    deltaY = computeDeltaYGivenDeltaX(deltaX, reserveX, reserveY);
    deltaL = computeDeltaLGivenDeltaX(deltaX, liquidity, reserveX);
}

function computeAllocationGivenDeltaY(uint256 deltaY, uint256 reserveX, uint256 reserveY, uint256 liquidity)
    pure
    returns (uint256 deltaX, uint256 deltaL)
{
    deltaX = computeDeltaXGivenDeltaY(deltaY, reserveX, reserveY);
    deltaL = computeDeltaLGivenDeltaY(deltaY, liquidity, reserveY);
}