// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseCustomCurve} from "@uniswap-hooks/base/BaseCustomCurve.sol";
import {IPoolManager} from "@uniswap/v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/types/BeforeSwapDelta.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import "./lib/SwapLib.sol";

/// @title Numo
/// @notice Log-normal automated market maker
/// @dev This is a modified version of the Numo contract that allows for the use of a custom curve.
/// @dev The custom curve is defined by the mean and width parameters.
/// @dev The mean is the mean of the log-normal distribution.
/// @dev The width is the width of the log-normal distribution.
/// @dev The mean and width are used to calculate the spot price of the pool.

contract Numo is BaseCustomCurve {
    using FixedPointMathLib for uint256;
    using FixedPointMathLib for int256;

    uint256 public mean;
    uint256 public width;
    uint256 public totalLiquidity;
    uint256 public reserve0;
    uint256 public reserve1;

    uint256 public constant SWAP_FEE_WAD = 1e14; // 0.01%

    event Swap(address indexed sender, bool zeroForOne, uint256 amountIn, uint256 amountOut);
    event LiquidityAdded(address indexed sender, uint256 amount0, uint256 amount1, uint256 shares);
    event LiquidityRemoved(address indexed sender, uint256 amount0, uint256 amount1, uint256 shares);

    constructor(IPoolManager _poolManager, uint256 _mean, uint256 _width) BaseCustomCurve(_poolManager) {
        mean = _mean;
        width = _width;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _getUnspecifiedAmount(
        PoolKey calldata,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) internal view override returns (uint256 amount) {
        uint256 localMean = mean;
        uint256 localWidth = width;

        uint256 amountSpecified = params.amountSpecified < 0
            ? uint256(-params.amountSpecified)
            : uint256(params.amountSpecified);

        if (params.zeroForOne) {
            // Input is in token0, solve for token1 out
            amount = SwapLib.computeAmountOutGivenAmountInX(
                amountSpecified, reserve0, reserve1, totalLiquidity, localMean, localWidth
            );
        } else {
            // Input is in token1, solve for token0 out
            amount = SwapLib.computeAmountOutGivenAmountInY(
                amountSpecified, reserve0, reserve1, totalLiquidity, localMean, localWidth
            );
        }
    }

    function _beforeSwap(address sender, PoolKey calldata, IPoolManager.SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint256 amountSpecified =
            params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);

        require(amountSpecified > 0, "ZERO_SWAP_AMOUNT");

        uint256 amountAfterFee = amountSpecified.mulWadDown(1e18 - SWAP_FEE_WAD);

        uint256 localMean = mean;
        uint256 localWidth = width;

        uint256 amountOut;
        if (params.zeroForOne) {
            amountOut = SwapLib.computeAmountOutGivenAmountInX(
                amountAfterFee, reserve0, reserve1, totalLiquidity, localMean, localWidth
            );
            require(amountOut <= reserve1, "INSUFFICIENT_LIQUIDITY_0");

            reserve0 += amountAfterFee;
            reserve1 -= amountOut;
        } else {
            amountOut = SwapLib.computeAmountOutGivenAmountInY(
                amountAfterFee, reserve0, reserve1, totalLiquidity, localMean, localWidth
            );
            require(amountOut <= reserve0, "INSUFFICIENT_LIQUIDITY_1");

            reserve1 += amountAfterFee;
            reserve0 -= amountOut;
        }

        BeforeSwapDelta delta = params.zeroForOne
            ? toBeforeSwapDelta(
                SafeCast.toInt128(SafeCast.toInt256(amountAfterFee)), SafeCast.toInt128(-SafeCast.toInt256(amountOut))
            )
            : toBeforeSwapDelta(
                SafeCast.toInt128(-SafeCast.toInt256(amountOut)), SafeCast.toInt128(SafeCast.toInt256(amountAfterFee))
            );

        emit Swap(sender, params.zeroForOne, amountAfterFee, amountOut);

        return (this.beforeSwap.selector, delta, 0);
    }

    function getSpotPrice() public view returns (uint256) {
        return SwapLib.computeSpotPrice(reserve0, totalLiquidity, mean, width);
    }

    function _getAmountIn(AddLiquidityParams memory params)
        internal
        override
        returns (uint256 amount0, uint256 amount1, uint256 shares)
    {
        amount0 = params.amount0Desired;
        amount1 = params.amount1Desired;

        require(amount0 > 0 || amount1 > 0, "ZERO_LIQUIDITY");

        if (totalLiquidity == 0) {
            shares = amount0 + amount1.mulWadDown(1e18).divWadDown(mean);
        } else {
            uint256 share0 = reserve0 > 0 ? amount0.mulDivDown(totalLiquidity, reserve0) : 0;
            uint256 share1 = reserve1 > 0 ? amount1.mulDivDown(totalLiquidity, reserve1) : 0;
            shares = share0 < share1 ? share0 : share1;
        }

        require(shares > 0, "INSUFFICIENT_SHARES");

        reserve0 += amount0;
        reserve1 += amount1;
        totalLiquidity += shares;

        emit LiquidityAdded(msg.sender, amount0, amount1, shares);
    }

    function _getAmountOut(RemoveLiquidityParams memory params)
        internal
        override
        returns (uint256 amount0, uint256 amount1, uint256 shares)
    {
        shares = params.liquidity;
        require(totalLiquidity > 0, "NO_LIQUIDITY");
        require(shares > 0, "ZERO_SHARES");

        amount0 = reserve0.mulDivDown(shares, totalLiquidity);
        amount1 = reserve1.mulDivDown(shares, totalLiquidity);

        require(amount0 <= reserve0 && amount1 <= reserve1, "INSUFFICIENT_RESERVES");

        reserve0 -= amount0;
        reserve1 -= amount1;
        totalLiquidity -= shares;

        emit LiquidityRemoved(msg.sender, amount0, amount1, shares);
    }

    function _mint(AddLiquidityParams memory, BalanceDelta, BalanceDelta, uint256) internal override {}

    function _burn(RemoveLiquidityParams memory, BalanceDelta, BalanceDelta, uint256) internal override {}
}
