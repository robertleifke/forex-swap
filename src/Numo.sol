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
/// @notice An hook for replicating calls and puts
contract Numo is BaseCustomCurve {
    using FixedPointMathLib for uint256;
    using FixedPointMathLib for int256;

    uint256 public sigma; 
    uint256 public maturity; 
    uint256 public strike; 
    uint256 public totalLiquidity;
    uint256 public lastImpliedPrice; 

    /// @notice Creates a pool
    /// @param _poolManager Uniswap V4 Pool Manager
    /// @param _sigma Implied volatility
    /// @param _strike Strike price
    /// @param _maturity Expiry timestamp
    constructor(IPoolManager _poolManager, uint256 _sigma, uint256 _strike, uint256 _maturity)
        BaseCustomCurve(_poolManager)
    {
        sigma = _sigma;
        strike = _strike;
        maturity = _maturity;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterAddLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: true,
            afterDonate: true,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: true,
            afterRemoveLiquidityReturnDelta: true
        });
    }

    // TODO: override beforeInitialize
    function prepareInit(
        uint256 priceX,
        uint256 amountX,
        uint256 strike_,
        uint256 sigma_
    ) public view returns (uint256 totalLiquidity_, uint256 amountY) {
        uint256 tau_ = SwapLib.computeTauWadYears(maturity - block.timestamp);
        
        SwapLib.PoolPreCompute memory comp = SwapLib.PoolPreCompute({
            reserveInAsset: amountX,
            strike_: strike_,
            tau_: tau_
        });

        uint256 initialLiquidity = SwapLib.computeLGivenX(
            amountX,
            totalLiquidity,
            strike_,
            sigma_,
            tau_
        );

        amountY = SwapLib.computeY(
            amountX,
            initialLiquidity,
            strike_,
            sigma_,
            tau_
        );

        totalLiquidity_ = SwapLib.solveL(comp, initialLiquidity, amountY, sigma_);
    }

    function _getUnspecifiedAmount(IPoolManager.SwapParams calldata params)
        internal
        override
        returns (uint256 unspecifiedAmount)
    {
        if (block.timestamp >= maturity) {
            unspecifiedAmount = uint256(params.amountSpecified > 0 ? params.amountSpecified : -params.amountSpecified).mulWadDown(strike);
        } else {
            // Pre-expiry: Compute implied price using RMM formula
            uint256 impliedPrice = getSpotPrice();
            unspecifiedAmount = uint256(params.amountSpecified > 0 ? params.amountSpecified : -params.amountSpecified).mulWadDown(impliedPrice);
        }
    }

    function getSpotPrice() public view returns (uint256) {
        if (block.timestamp >= maturity) return strike;

        uint256 timeToExpiry = maturity - block.timestamp;
        
        int256 tradingFunctionValue = SwapLib.computeTradingFunction(
            totalLiquidity, totalLiquidity, totalLiquidity, strike, sigma, timeToExpiry
        );

        return SwapLib.computeSpotPrice(
            totalLiquidity, totalLiquidity, strike, sigma, timeToExpiry
        ).mulWadUp(uint256(tradingFunctionValue));
    }

    function _getAmountIn(AddLiquidityParams memory params)
        internal
        override
        returns (uint256 amount0, uint256 amount1, uint256 shares)
    {
        if (block.timestamp >= maturity) revert("RMM: Expired, Cannot Add Liquidity");

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

    function _mint(
        AddLiquidityParams memory params,
        BalanceDelta callerDelta,
        BalanceDelta feesAccrued,
        uint256 shares
    ) internal override {
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