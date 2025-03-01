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
import "./lib/SwapLib.sol";

///-------------------------------- 
/// ERRORS
///--------------------------------

// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

/// @dev Thrown if trying to initialize a pool with an invalid strike price (strike < 1e18).
error InvalidStrike();
/// @dev Thrown if trying to initialize an already initialized pool.
error AlreadyInitialized();
/// @dev Thrown when a `balanceOf` call fails or returns unexpected data.
error BalanceError();
/// @dev Thrown when a payment to this contract is insufficient.
error InsufficientPayment(address token, uint256 actual, uint256 expected);
/// @dev Thrown when a mint does not output enough liquidity.
error InsufficientLiquidityOut(bool inTermsOfX, uint256 amount, uint256 minLiquidity, uint256 liquidity);
/// @dev Thrown when a swap does not output enough tokens.
error InsufficientOutput(uint256 amountIn, uint256 minAmountOut, uint256 amountOut);
/// @dev Thrown when a swap does not mint sufficient tokens given the minimum amount.
error InsufficientSYMinted(uint256 amountMinted, uint256 minAmountMinted);
/// @dev Thrown when a swap expects greater input than is allowed
error ExcessInput(uint256 amountOut, uint256 maxAmountIn, uint256 amountIn);
/// @dev Thrown when an allocate would reduce the liquidity.
error InvalidAllocate(uint256 deltaX, uint256 deltaY, uint256 currLiquidity, uint256 nextLiquidity);
/// @dev Thrown on `init` when a token has invalid decimals.
error InvalidDecimals(address token, uint256 decimals);
/// @dev Thrown when the trading function result is out of bounds
error OutOfRange(int256 terminal);
/// @dev Thrown when a payment to or from the user returns false or no data.
error PaymentFailed(address token, address from, address to, uint256 amount);
/// @dev Thrown when a token passed to `mint` is not valid
error InvalidTokenIn(address tokenIn);
/// @dev Thrown when an external call is made within the same frame as another.
error Reentrancy();
/// @dev Thrown when the maturity date is reached.
error MaturityReached();
/// @dev Thrown when a `toInt` call overflows.
error ToIntOverflow();
/// @dev Thrown when a `toUint` call overflows.
error ToUintOverflow();

///-------------------------------- 
/// EVENTS
///--------------------------------

event Init(
    address caller,
    uint256 totalLiquidity,
    uint256 strike,
    uint256 sigma,
    uint256 fee,
    uint256 maturity
);

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
        return SwapLib.computeSpotPrice(
            totalLiquidity, totalLiquidity, strike, sigma, timeToExpiry
        );
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