// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title Numo
/// @notice An hook for replicating short puts and calls
contract Numo is BaseHook {
    uint256 public sigma; 
    uint256 public maturity; 
    uint256 public strike; 

    uint256 public reserveX;
    uint256 public reserveY; 
    uint256 public totalLiquidity;
    uint256 public lastImpliedPrice; 

    /// @notice Creates a Numo pool 
    /// @param _poolManager V4 pool manager
    /// @param _sigma volatility parameter
    /// @param _strike strike price
    /// @param _maturity expiry
    constructor(IPoolManager _poolManager, uint256 _sigma, uint256 _strike, uint256 _maturity)
        BaseHook(_poolManager)
    {
        sigma = _sigma;
        strike = _strike;
        maturity = _maturity;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        uint256 adjustedPrice = computeSpotPrice();

        BeforeSwapDelta delta = toBeforeSwapDelta(SafeCast.toInt128(int256(adjustedPrice)), 0);

        return (IHooks.beforeSwap.selector, delta, 100);
    }

    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4) {
        uint256 newLiquidity = computeLiquidity(SafeCast.toUint256(params.liquidityDelta));

        emit LiquidityAdjusted(sender, newLiquidity);

        return IHooks.beforeAddLiquidity.selector;
    }

    /// @dev Computes the adjusted spot price based on implied volatility and time to maturity.
    function computeSpotPrice() public view returns (uint256) {
        uint256 timeToExpiry = maturity > block.timestamp ? (maturity - block.timestamp) : 0;

        return timeToExpiry > 0
            ? uint256(int256(lastImpliedPrice) * int256(365 * 86400) / int256(timeToExpiry))
            : 1 ether;
    }

    function computeLiquidity(uint256 liquidityDelta) internal view returns (uint256) {
        return totalLiquidity + (liquidityDelta * sigma) / 1e18;
    }

    event LiquidityAdjusted(address indexed sender, uint256 newLiquidity);
}
