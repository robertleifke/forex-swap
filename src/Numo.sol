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
import { LogNormal } from "./LogNormal.sol";
import { BaseCustomCurveHook } from "@uniswap-hooks/base/BaseCustomCurveHook.sol";
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
uint256 constant MIN_WIDTH = 1;
uint256 constant MAX_WIDTH = uint256(int24(TickMath.MAX_TICK) - TickMath.MIN_TICK);
uint256 constant MIN_MEAN = 1e18;
uint256 constant MAX_MEAN = 1e18 * 100;

contract Numo is BaseCustomCurveHook, LogNormal {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;
    using ProtocolFeeLibrary for *;
    using SafeCastLib for uint128;
    using SafeCastLib for int256;
    using SafeCastLib for uint256;

    struct LogNormalParams {
        uint256 mean;
        uint256 width;
        uint256 swapFee;
        uint256 controller;
    }

    bool public isInitialized;

    PoolKey public poolKey;
    address public initializer;

    uint256 internal startingTime; // sale start time
    uint256 internal endingTime; // sale end time
    int24 internal startingTick; // dutch auction starting tick
    int24 internal endingTick; // dutch auction ending tick
    uint256 internal epochLength; // length of each epoch (seconds)
    int24 internal gamma; // 1.0001 ** (gamma), represents the maximum tick change for the entire bonding curve
    bool internal isToken0; // whether token0 is the token being sold (true) or token1 (false)

    uint256 internal totalEpochs; // total number of epochs
    uint256 internal normalizedEpochDelta; // normalized delta between two epochs

    State public state;
    mapping(bytes32 salt => Position position) public positions;

    receive() external payable {
        if (msg.sender != address(poolManager)) revert SenderNotPoolManager();
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: true,
            afterRemoveLiquidityReturnDelta: true
        });
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

    function setPoolParams(
        PoolKey calldata key,
        uint256 mean, 
        uint256 width,
        uint256 swapFee,
        uint256 controller)
    ) external {
        if (msg.sender != address(poolManager)) revert SenderNotPoolManager();

        if (mean < MIN_MEAN || mean > MAX_MEAN) revert InvalidMean();
        if (width < MIN_WIDTH || width > MAX_WIDTH) revert InvalidWidth();
        
    }
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata data
    ) external override returns (bytes4) {
        require(msg.sender == address(poolManager), "Unauthorized");

        bytes32 poolId = keccak256(abi.encode(key));
        LogNormalParams storage pool = poolParams[poolId];

        if (sender != pool.controller) revert Unauthorized();

        uint256 amountIn = params.amount.abs();
        uint256 deltaL;

        if (params.zeroForOne) {
            deltaL = pool.liquidity.mul(amountIn).div(pool.sqrtPriceX96);
        } else {
            deltaL = pool.liquidity.mul(amountIn).div(pool.sqrtPriceX96);
        }
    }

    function beforeAddLiquidity(
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
