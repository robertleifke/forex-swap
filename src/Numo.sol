// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { BaseHook } from "@v4-periphery/base/hooks/BaseHook.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { BeforeSwapDelta, BeforeSwapDeltaLibrary } from "@v4-core/types/BeforeSwapDelta.sol";
import { BalanceDelta, add, BalanceDeltaLibrary } from "@v4-core/types/BalanceDelta.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { LiquidityAmounts } from "@v4-core-test/utils/LiquidityAmounts.sol";
import { SqrtPriceMath } from "@v4-core/libraries/SqrtPriceMath.sol";
import { FullMath } from "@v4-core/libraries/FullMath.sol";
import { FixedPoint96 } from "@v4-core/libraries/FixedPoint96.sol";
import { TransientStateLibrary } from "@v4-core/libraries/TransientStateLibrary.sol";
import { FixedPointMathLib } from "@solady/utils/FixedPointMathLib.sol";
import { ProtocolFeeLibrary } from "@v4-core/libraries/ProtocolFeeLibrary.sol";
import { SwapMath } from "@v4-core/libraries/SwapMath.sol";
import { SafeCastLib } from "@solady/utils/SafeCastLib.sol";
import { Currency } from "@v4-core/types/Currency.sol";

struct PortfolioData {
    int24 strikeFloor;
    int24 strikeCeiling;
    uint128 liquidity;
}

struct State {
    uint40 lastExpiry;
    int256 tickAccumulator;
    uint256 totalTokensSold;
    uint256 totalProceeds;
    uint256 totalTokensSoldLastEpoch;
    BalanceDelta feesAccrued;
}

struct Position {
    int24 strikeFloor;
    int24 strikeCeiling;
    uint128 liquidity;
    uint8 salt;
}

error InvalidGamma();

/// @notice Thrown when the time range is invalid (likely start is after end)
error InvalidTimeRange();

/// @notice Thrown when an attempt is made to add liquidity to the pool
error CannotAddLiquidity();

/// @notice Thrown when an attempt is made to swap before the start time
error CannotSwapBeforeStartTime();

error SwapBelowRange();

/// @notice Thrown when start time is before the current block.timestamp
error InvalidStartTime();

error InvalidTickRange();
error InvalidTickSpacing();
error InvalidEpochLength();
error InvalidProceedLimits();
error InvalidNumPDSlugs();
error InvalidSwapAfterMaturitySufficientProceeds();
error InvalidSwapAfterMaturityInsufficientProceeds();
error MaximumProceedsReached();
error SenderNotPoolManager();
error CannotMigrate();
error AlreadyInitialized();
error SenderNotInitializer();
error CannotDonate();

event Rebalance(int24 currentTick, int24 tickLower, int24 tickUpper, uint256 epoch);

event Swap(int24 currentTick, uint256 totalProceeds, uint256 totalTokensSold);

event EarlyExit(uint256 epoch);

event InsufficientProceeds();

uint256 constant MAX_SWAP_FEE = SwapMath.MAX_SWAP_FEE;
uint256 constant WAD = 1e18;
int256 constant I_WAD = 1e18;
int24 constant MAX_TICK_SPACING = 30;
uint256 constant MAX_PRICE_DISCOVERY_SLUGS = 10;
uint256 constant NUM_DEFAULT_SLUGS = 3;

contract Numo is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;
    using ProtocolFeeLibrary for *;
    using SafeCastLib for uint128;
    using SafeCastLib for int256;
    using SafeCastLib for uint256;

    bool public insufficientProceeds; // triggers if the pool matures and minimumProceeds is not met
    bool public earlyExit; // triggers if the pool ever reaches or exceeds maximumProceeds

    
    bool public isInitialized;

    PoolKey public poolKey;
    address public initializer;

    uint256 internal numTokensToSell; // total amount of tokens to be sold
    uint256 internal minimumProceeds; // minimum proceeds required to avoid refund phase
    uint256 internal maximumProceeds; // proceeds amount that will trigger early exit condition
    uint256 internal startingTime; // sale start time
    uint256 internal endingTime; // sale end time
    int24 internal startingTick; // dutch auction starting tick
    int24 internal endingTick; // dutch auction ending tick
    uint256 internal epochLength; // length of each epoch (seconds)
    int24 internal gamma; // 1.0001 ** (gamma), represents the maximum tick change for the entire bonding curve
    bool internal isToken0; // whether token0 is the token being sold (true) or token1 (false)
    uint256 internal numPDSlugs; // number of price discovery slugs

    uint256 internal totalEpochs; // total number of epochs
    uint256 internal normalizedEpochDelta; // normalized delta between two epochs
    int24 internal upperSlugRange; // range of the upper slug

    State public state;
    mapping(bytes32 salt => Position position) public positions;

    receive() external payable {
        if (msg.sender != address(poolManager)) revert SenderNotPoolManager();
    }

    constructor(
        IPoolManager _poolManager,
        uint256 _numTokensToSell,
        uint256 _minimumProceeds,
        uint256 _maximumProceeds,
        uint256 _startingTime,
        uint256 _endingTime,
        int24 _startingTick,
        int24 _endingTick
    ) {
        poolManager = _poolManager;
    }
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external override returns (bytes4) {
        require(msg.sender == address(poolManager), "Unauthorized");

        // Extract log-normal parameters from hookData
        (uint256 volatility, uint256 drift) = abi.decode(hookData, (uint256, uint256));

        // Compute log-normal price adjustment
        int256 priceShift = computeLogNormalPrice(params.amountSpecified, volatility, drift);

        // Apply price shift to the swap parameters (modifies sqrtPriceX96)
        params.sqrtPriceX96 = uint160(uint256(int256(params.sqrtPriceX96) + priceShift));

        return IUniswapV4Hook.beforeSwap.selector;
    }

    function computeLogNormalPrice(
        int256 amountSpecified,
        uint256 volatility,
        uint256 drift
    ) internal pure returns (int256) {
        // Log-normal price adjustment using the Black-Scholes-like model
        // Formula: P' = P * exp(volatility * sqrt(t) + drift * t)
        uint256 t = 1 days; // Assume daily rebalancing for now

        int256 logPriceChange = int256(
            (volatility * sqrt(t) / 1e18) + (drift * t / 1e18)
        );

        return logPriceChange;
    }

    function sqrt(uint256 x) internal pure returns (uint256) {
        return x**(1/2);
    }

    function beforeModifyPosition(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyPositionParams calldata params,
        bytes calldata hookData
    ) external override returns (bytes4) {
        return IUniswapV4Hook.beforeModifyPosition.selector;
    }

    function beforeInitialize(
        address sender,
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        bytes calldata hookData
    ) external override returns (bytes4) {
        return IUniswapV4Hook.beforeInitialize.selector;
    }
}
