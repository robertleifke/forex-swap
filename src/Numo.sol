// SPDX-License-Identifier: MIT AND GPL-3.0-or-later
pragma solidity ^0.8.24;

import {BaseCustomCurve} from "@uniswap-hooks/base/BaseCustomCurve.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "./lib/SwapLib.sol";

/// @title Numo
/// @notice A log-normal AMM
contract Numo is BaseCustomCurve {
    using FixedPointMathLib for uint256;
    using FixedPointMathLib for int256;

    uint256 public mean;
    uint256 public width;
    uint256 public totalLiquidity;

    /// @notice Creates a pool
    /// @param _poolManager Uniswap V4 Pool Manager
    /// @param _mean Mean
    /// @param _width Width
    /// @param _totalLiquidity Total liquidity
    constructor(IPoolManager _poolManager, uint256 _mean, uint256 _width)
        BaseCustomCurve(_poolManager)
    {
        mean = _mean;
        width = _width;
        totalLiquidity = _totalLiquidity;
    }

    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory permissions) {
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

    
    /// @notice Get the amount of unspecified amount
    /// @param params The swap params
    /// @return unspecifiedAmount The amount of unspecified amount
    function _getUnspecifiedAmount(IPoolManager.SwapParams calldata params)
    internal
    override
    returns (uint256 unspecifiedAmount)
{
    uint256 amountSpecified = params.amountSpecified < 0
        ? uint256(-params.amountSpecified)
        : uint256(params.amountSpecified);

    (uint256 rX, uint256 rY) = _getReserves(); // Assume you have a way to get reserves (internal function)

    if (params.zeroForOne) {
        // Selling token0 (rX), buying token1 (rY)
        unspecifiedAmount = SwapLib.computeAmountOutGivenAmountInX(
            amountSpecified,
            rX,
            rY,
            totalLiquidity,
            mean,
            width
        );
    } else {
        // Selling token1 (rY), buying token0 (rX)
        unspecifiedAmount = SwapLib.computeAmountOutGivenAmountInY(
            amountSpecified,
            rX,
            rY,
            totalLiquidity,
            mean,
            width
        );
    }
}


    function getSpotPrice() public view returns (uint256) {
        if (block.timestamp >= maturity) return strike;

        uint256 timeToExpiry = maturity - block.timestamp;

        int256 tradingFunctionValue =
            SwapLib.computeTradingFunction(totalLiquidity, totalLiquidity, totalLiquidity, strike, sigma, timeToExpiry);

        return SwapLib.computeSpotPrice(totalLiquidity, totalLiquidity, strike, sigma, timeToExpiry).mulWadUp(
            uint256(tradingFunctionValue)
        );
    }

    function _getAmountIn(AddLiquidityParams memory params)
        internal
        override
        returns (uint256 amount0, uint256 amount1, uint256 shares)
    {
        if (block.timestamp >= maturity) revert("Expired, Cannot Add Liquidity");

        amount0 = params.amount0Desired;
        amount1 = params.amount1Desired;

        shares = SwapLib.computeLGivenX(amount0, totalLiquidity, strike, sigma, maturity - block.timestamp);
        totalLiquidity += shares;
    }

    function _getAmountOut(RemoveLiquidityParams memory params)
        internal
        override
        returns (uint256 amount0, uint256 amount1, uint256 shares)
    {
        shares = params.liquidity;
        amount0 = shares.mulDivDown(totalLiquidity, totalLiquidity + shares);
        amount1 = shares.mulDivDown(totalLiquidity, totalLiquidity + shares);
        totalLiquidity -= shares;
    }

    function _mint(AddLiquidityParams memory params, BalanceDelta callerDelta, BalanceDelta feesAccrued, uint256 shares)
        internal
        override
    {
        totalLiquidity += shares;
    }

    function _burn(
        RemoveLiquidityParams memory params,
        BalanceDelta callerDelta,
        BalanceDelta feesAccrued,
        uint256 shares
    ) internal override {
        totalLiquidity -= shares;
    }
}
