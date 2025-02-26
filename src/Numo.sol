// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseCustomCurve} from "@uniswap-hooks/base/BaseCustomCurve.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title Numo
/// @notice An hook for replicating short puts and calls
contract Numo is BaseCustomCurve {
    using FixedPointMathLib for uint256;

    uint256 public sigma; // Volatility parameter
    uint256 public maturity; // Expiry timestamp
    uint256 public strike; // Strike price

    uint256 public totalLiquidity; // Total LP supply
    uint256 public lastImpliedPrice; // Last computed implied price

    /// @notice Creates a Numo pool
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

    /// @dev Hook permissions for Uniswap V4
    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
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

    /// @notice Compute swap amounts, enforcing expiry logic.
    function _getUnspecifiedAmount(IPoolManager.SwapParams calldata params)
        internal
        override
        returns (uint256 unspecifiedAmount)
    {
        if (block.timestamp >= maturity) {
            // If expired, lock price to strike
            unspecifiedAmount = params.amountSpecified.mulWadDown(strike);
        } else {
            // Pre-expiry: Compute implied price using RMM formula
            uint256 impliedPrice = computeSpotPrice();
            unspecifiedAmount = params.amountSpecified.mulWadDown(impliedPrice);
        }
    }

    /// @dev Computes the adjusted spot price based on volatility and time to expiry.
    function computeSpotPrice() public view returns (uint256) {
        if (block.timestamp >= maturity) return strike; // Expired → settle at strike

        uint256 timeToExpiry = maturity - block.timestamp; // Remaining time
        return sigma.mulWadDown(strike).mulWadDown(timeToExpiry);
    }

    /// @notice Handles adding liquidity but prevents adding after expiry.
    function _getAmountIn(AddLiquidityParams memory params)
        internal
        override
        returns (uint256 amount0, uint256 amount1, uint256 shares)
    {
        if (block.timestamp >= maturity) revert("RMM: Expired, Cannot Add Liquidity");

        amount0 = params.amount0;
        amount1 = params.amount1;
        shares = amount0 + amount1; // Simple proportional liquidity
        totalLiquidity += shares;
    }

    /// @notice Handles removing liquidity, allowing settlement post-expiry.
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
}