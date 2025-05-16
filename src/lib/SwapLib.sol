// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Gaussian} from "solstat/Gaussian.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

library SwapLib {
    using FixedPointMathLib for uint256;
    using FixedPointMathLib for int256;

    /*//////////////////////////////////////////////////////////////
                              Trading Core
    //////////////////////////////////////////////////////////////*/

    function computeTradingFunction(uint256 rX, uint256 rY, uint256 L, uint256 mean, uint256 width)
        public
        pure
        returns (int256)
    {
        uint256 a_i = rX.divWadDown(L);
        uint256 b_i = rY.divWadDown(mean.mulWadDown(L));

        int256 a = Gaussian.ppf(int256(a_i));
        int256 b = Gaussian.ppf(int256(b_i));

        return a + b + int256(width);
    }

    function computeSpotPrice(uint256 rX, uint256 L, uint256 mean, uint256 width) public pure returns (uint256) {
        int256 a = Gaussian.ppf(int256(1 ether - rX.divWadDown(L)));
        int256 exp = (a.mul(int256(width))).expWad();
        return mean.mulWadUp(uint256(exp));
    }

    /*//////////////////////////////////////////////////////////////
                        Reserve Conversions
    //////////////////////////////////////////////////////////////*/

    function computeYGivenX(uint256 rX, uint256 L, uint256 mean, uint256 width) public pure returns (uint256 rY) {
        int256 a = Gaussian.ppf(int256(1 ether - rX.divWadDown(L)));
        int256 c = Gaussian.cdf(a - int256(width));
        rY = mean.mulWadDown(L).mulWadDown(uint256(c));
    }

    function computeXGivenY(uint256 rY, uint256 L, uint256 mean, uint256 width) public pure returns (uint256 rX) {
        int256 a = Gaussian.ppf(int256(rY.divWadDown(mean.mulWadDown(L))));
        int256 c = Gaussian.cdf(a + int256(width));
        rX = L.mulWadDown(1 ether - uint256(c));
    }

    /*//////////////////////////////////////////////////////////////
                          Swap Amounts
    //////////////////////////////////////////////////////////////*/

    function computeAmountOutGivenAmountInX(
        uint256 amountIn,
        uint256 rX,
        uint256 rY,
        uint256 L,
        uint256 mean,
        uint256 width
    ) public pure returns (uint256 amountOut) {
        uint256 newRX = rX + amountIn;
        uint256 newRY = computeYGivenX(newRX, L, mean, width);
        amountOut = rY - newRY;
    }

    function computeAmountOutGivenAmountInY(
        uint256 amountIn,
        uint256 rX,
        uint256 rY,
        uint256 L,
        uint256 mean,
        uint256 width
    ) public pure returns (uint256 amountOut) {
        uint256 newRY = rY + amountIn;
        uint256 newRX = computeXGivenY(newRY, L, mean, width);
        amountOut = rX - newRX;
    }

    /*//////////////////////////////////////////////////////////////
                         Liquidity Changes
    //////////////////////////////////////////////////////////////*/

    function computeDeltaLXIn(
        uint256 amountIn,
        uint256 rX,
        uint256 rY,
        uint256 L,
        uint256 swapFee,
        uint256 mean,
        uint256 width
    ) public pure returns (uint256 deltaL) {
        uint256 fees = swapFee.mulWadUp(amountIn);
        uint256 px = computeSpotPrice(rX, L, mean, width);
        deltaL = px.mulWadUp(L).mulWadUp(fees).divWadDown(px.mulWadDown(rX) + rY);
    }

    function computeDeltaLYIn(
        uint256 amountIn,
        uint256 rX,
        uint256 rY,
        uint256 L,
        uint256 swapFee,
        uint256 mean,
        uint256 width
    ) public pure returns (uint256 deltaL) {
        uint256 fees = swapFee.mulWadUp(amountIn);
        uint256 px = computeSpotPrice(rX, L, mean, width);
        deltaL = L.mulWadUp(fees).divWadDown(px.mulWadDown(rX) + rY);
    }

    /*//////////////////////////////////////////////////////////////
                           Root Finders
    //////////////////////////////////////////////////////////////*/

    function findX(bytes memory data, uint256 rX) public pure returns (int256) {
        (uint256 rY, uint256 L, uint256 mean, uint256 width) = abi.decode(data, (uint256, uint256, uint256, uint256));
        return computeTradingFunction(rX, rY, L, mean, width);
    }

    function findY(bytes memory data, uint256 rY) public pure returns (int256) {
        (uint256 rX, uint256 L, uint256 mean, uint256 width) = abi.decode(data, (uint256, uint256, uint256, uint256));
        return computeTradingFunction(rX, rY, L, mean, width);
    }

    function findL(bytes memory data, uint256 L) public pure returns (int256) {
        (uint256 rX, uint256 rY, uint256 mean, uint256 width) = abi.decode(data, (uint256, uint256, uint256, uint256));
        return computeTradingFunction(rX, rY, L, mean, width);
    }

    function findRootNewX(bytes memory args, uint256 initialGuess, uint256 maxIterations, uint256 tolerance)
        public
        pure
        returns (uint256 root)
    {
        root = initialGuess;
        for (uint256 i = 0; i < maxIterations; i++) {
            int256 fValue = findX(args, root);
            if (abs(fValue) <= int256(tolerance)) {
                break;
            }
            if (fValue > 0) {
                root = root.mulDivDown(999, 1000); // move lower
            } else {
                root = root.mulDivUp(1001, 1000); // move higher
            }
        }
    }

    function findRootNewY(bytes memory args, uint256 initialGuess, uint256 maxIterations, uint256 tolerance)
        public
        pure
        returns (uint256 root)
    {
        root = initialGuess;
        for (uint256 i = 0; i < maxIterations; i++) {
            int256 fValue = findY(args, root);
            if (abs(fValue) <= int256(tolerance)) {
                break;
            }
            if (fValue > 0) {
                root = root.mulDivDown(999, 1000);
            } else {
                root = root.mulDivUp(1001, 1000);
            }
        }
    }

    function findRootNewLiquidity(bytes memory args, uint256 initialGuess, uint256 maxIterations, uint256 tolerance)
        public
        pure
        returns (uint256 root)
    {
        root = initialGuess;
        for (uint256 i = 0; i < maxIterations; i++) {
            int256 fValue = findL(args, root);
            if (abs(fValue) <= int256(tolerance)) {
                break;
            }
            if (fValue > 0) {
                root = root.mulDivDown(999, 1000);
            } else {
                root = root.mulDivUp(1001, 1000);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                        Small Math Helpers
    //////////////////////////////////////////////////////////////*/

    function abs(int256 x) public pure returns (int256) {
        return x < 0 ? -x : x;
    }
}
