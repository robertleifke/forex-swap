// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import { BaseCustomCurve } from "uniswap-hooks/src/base/BaseCustomCurve.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { BalanceDelta } from "v4-core/src/types/BalanceDelta.sol";
import { Math } from "v4-core/lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { Ownable } from "v4-core/lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import { Pausable } from "v4-core/lib/openzeppelin-contracts/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "v4-core/lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import { FullMath } from "v4-core/src/libraries/FullMath.sol";
import { FixedPoint96 } from "v4-core/src/libraries/FixedPoint96.sol";
import { StateLibrary } from "v4-core/src/libraries/StateLibrary.sol";
import { PoolIdLibrary } from "v4-core/src/types/PoolId.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { Currency } from "v4-core/src/types/Currency.sol";
import { Gaussian } from "./libraries/Gaussian.sol";
import { SignedWadMath } from "./libraries/SignedWadMath.sol";

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

/**
 * @title Forex Swap
 * @notice Uniswap v4 hook implementing a stateful approximation of Primitive's LogNormal DFMM.
 * @dev The hook owns the market maker state. Uniswap v4 is used for settlement and flash accounting.
 */
contract ForexSwap is BaseCustomCurve, Ownable, Pausable, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    error InvalidMean();
    error InvalidWidth();
    error FeeTooHigh();
    error ZeroAmount();
    error InsufficientLiquidity();
    error SlippageExceeded();
    error InvalidParameters();
    error DeadlineExpired();
    error MinAmountNotMet();
    error MaxAmountExceeded();
    error DomainExceeded();
    error UninitializedMarket();
    error NonMonotonicQuote();
    error ExponentOutOfBounds();
    error Int256CastOverflow();
    error UnsupportedTokenDecimals();
    error TokenDecimalsQueryFailed();
    error InvalidInventoryResponse();
    error BootstrapClipTooLarge();

    event MarketParametersUpdated(uint256 newMean, uint256 newWidth, uint256 newBaseHookFeeWad);
    event HookFeeModelUpdated(
        uint256 inventoryFeeScaleWad, uint256 volatilityFeeScaleWad, uint256 tenorFeeScaleWad, uint256 maxHookFeeWad
    );
    event InventoryResponseUpdated(uint256 inventoryResponseWad);
    event RealizedVolatilityUpdated(uint256 realizedVolatilityWad);
    event LiquidityAdded(address indexed provider, uint256 amount0, uint256 amount1, uint256 shares);
    event LiquidityRemoved(address indexed provider, uint256 amount0, uint256 amount1, uint256 shares);
    event LiquiditySettlementTrace(
        address indexed provider,
        bool bootstrap,
        uint256 reserve0Before,
        uint256 reserve1Before,
        uint256 reserve0After,
        uint256 reserve1After,
        uint256 amount0Settled,
        uint256 amount1Settled,
        uint256 normalizedAmount0Settled,
        uint256 normalizedAmount1Settled,
        uint256 shares
    );
    event SwapExecuted(
        address indexed trader,
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOut,
        uint256 hookFeeWad,
        uint256 hookFeeAmount
    );
    event EmergencyPaused(address indexed admin);
    event EmergencyUnpaused(address indexed admin);

    struct LogNormalParams {
        uint256 mean;
        uint256 width;
        uint256 baseHookFeeWad;
    }

    struct HookFeeModel {
        uint256 inventoryFeeScaleWad;
        uint256 volatilityFeeScaleWad;
        uint256 tenorFeeScaleWad;
        uint256 maxHookFeeWad;
    }

    struct PoolState {
        uint256 reserve0;
        uint256 reserve1;
        uint256 liquidity;
    }

    struct AddLiquidityPlan {
        uint256 amount0;
        uint256 amount1;
        uint256 shares;
        uint256 deltaL;
    }

    struct BootstrapTrace {
        uint256 priceWad;
        uint256 desiredPriceWad;
        uint256 normalizedAmount0Desired;
        uint256 normalizedAmount1Desired;
        uint256 xRatio;
        uint256 yRatio;
        uint256 requiredYForX;
        uint256 requiredXForY;
        uint256 clip0Bps;
        uint256 clip1Bps;
        bool amount0Limited;
        bool stableExact;
        uint256 amount0;
        uint256 amount1;
        uint256 rawAmount0;
        uint256 rawAmount1;
        uint256 deltaL;
        uint256 shares;
    }

    struct RemoveLiquidityPlan {
        uint256 amount0;
        uint256 amount1;
        uint256 shares;
        uint256 deltaL;
    }

    uint256 private constant WAD = 1e18;
    uint256 private constant SEARCH_STEPS = 64;
    uint256 private constant MAX_MEAN_WAD = 10_000e18;
    uint256 private constant STABLE_BOOTSTRAP_PRICE_TOLERANCE_BPS = 500;
    uint256 private constant MAX_BOOTSTRAP_CLIP_BPS = 50;
    // Minimum admissible bootstrap tail mass in WAD space.
    // This bounds liquidity amplification in deltaL = amount0 * WAD / xRatio
    // and keeps the accepted region above CDF tail noise.
    uint256 private constant EPS = 1e9;
    int256 private constant MAX_EXPONENT_WAD = 20e18;
    int256 private constant MIN_EXPONENT_WAD = -20e18;

    mapping(address account => uint256 balance) public balanceOf;
    uint256 public totalSupply;
    LogNormalParams public logNormalParams = LogNormalParams({ mean: 1e18, width: 2e17, baseHookFeeWad: 3e15 });
    HookFeeModel public hookFeeModel = HookFeeModel({
        inventoryFeeScaleWad: 0,
        volatilityFeeScaleWad: 0,
        tenorFeeScaleWad: 0,
        maxHookFeeWad: 1e17
    });
    uint256 public realizedVolatilityWad;
    PoolState public poolState;
    uint256 public inventoryResponseWad = 25e16;
    uint8 public token0Decimals = 18;
    uint8 public token1Decimals = 18;
    uint256 private token0Scale = 1;
    uint256 private token1Scale = 1;

    constructor(IPoolManager _poolManager) BaseCustomCurve(_poolManager) Ownable(msg.sender) { }

    function _beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        internal
        override
        returns (bytes4)
    {
        bytes4 selector = super._beforeInitialize(sender, key, sqrtPriceX96);
        (uint8 loadedToken0Decimals, uint8 loadedToken1Decimals) =
            (_loadTokenDecimals(key.currency0), _loadTokenDecimals(key.currency1));
        _setTokenScales(loadedToken0Decimals, loadedToken1Decimals);
        return selector;
    }

    function _getUnspecifiedAmount(IPoolManager.SwapParams calldata swapParams)
        internal
        override
        whenNotPaused
        returns (uint256 unspecifiedAmount)
    {
        if (poolState.liquidity == 0) revert UninitializedMarket();

        bool exactInput = swapParams.amountSpecified < 0;
        uint256 specifiedAmount =
            exactInput ? uint256(-swapParams.amountSpecified) : uint256(swapParams.amountSpecified);

        if (specifiedAmount == 0) revert ZeroAmount();

        if (exactInput) {
            unspecifiedAmount = swapParams.zeroForOne
                ? _denormalizeAmount1(_executeExactInput0For1(_normalizeAmount0(specifiedAmount)))
                : _denormalizeAmount0(_executeExactInput1For0(_normalizeAmount1(specifiedAmount)));
        } else {
            unspecifiedAmount = swapParams.zeroForOne
                ? _denormalizeAmount0Up(_executeExactOutput0For1(_normalizeAmount1(specifiedAmount)))
                : _denormalizeAmount1Up(_executeExactOutput1For0(_normalizeAmount0(specifiedAmount)));
        }
    }

    function _getAddLiquidity(
        uint160 sqrtPriceX96,
        AddLiquidityParams memory params
    )
        internal
        override
        returns (bytes memory, uint256)
    {
        AddLiquidityPlan memory plan = _planAddLiquidity(sqrtPriceX96, params);
        return (
            abi.encode(
                int128(uint128(_denormalizeAmount0(plan.amount0))), int128(uint128(_denormalizeAmount1(plan.amount1)))
            ),
            plan.shares
        );
    }

    function _getRemoveLiquidity(RemoveLiquidityParams memory params)
        internal
        override
        returns (bytes memory, uint256)
    {
        RemoveLiquidityPlan memory plan = _planRemoveLiquidity(params.liquidity);
        return (
            abi.encode(
                -int128(uint128(_denormalizeAmount0(plan.amount0))),
                -int128(uint128(_denormalizeAmount1(plan.amount1)))
            ),
            plan.shares
        );
    }

    function _getAmountIn(AddLiquidityParams memory params)
        internal
        view
        override
        returns (uint256 amount0, uint256 amount1, uint256 shares)
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());
        AddLiquidityPlan memory plan = _planAddLiquidity(sqrtPriceX96, params);
        return (_denormalizeAmount0(plan.amount0), _denormalizeAmount1(plan.amount1), plan.shares);
    }

    function _getAmountOut(RemoveLiquidityParams memory params)
        internal
        view
        override
        returns (uint256 amount0, uint256 amount1, uint256 shares)
    {
        RemoveLiquidityPlan memory plan = _planRemoveLiquidity(params.liquidity);
        return (_denormalizeAmount0(plan.amount0), _denormalizeAmount1(plan.amount1), plan.shares);
    }

    function _mint(
        AddLiquidityParams memory params,
        BalanceDelta,
        BalanceDelta,
        uint256 shares
    )
        internal
        override
        nonReentrant
        whenNotPaused
    {
        if (shares == 0) revert ZeroAmount();

        PoolState memory stateBefore = poolState;
        bool bootstrap = stateBefore.liquidity == 0;
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());
        AddLiquidityPlan memory plan = _planAddLiquidity(sqrtPriceX96, params);

        poolState.reserve0 += plan.amount0;
        poolState.reserve1 += plan.amount1;
        poolState.liquidity += plan.deltaL;

        balanceOf[params.to] += shares;
        totalSupply += shares;

        emit LiquidityAdded(params.to, _denormalizeAmount0(plan.amount0), _denormalizeAmount1(plan.amount1), shares);
        emit LiquiditySettlementTrace(
            params.to,
            bootstrap,
            _denormalizeAmount0(stateBefore.reserve0),
            _denormalizeAmount1(stateBefore.reserve1),
            _denormalizeAmount0(poolState.reserve0),
            _denormalizeAmount1(poolState.reserve1),
            _denormalizeAmount0(plan.amount0),
            _denormalizeAmount1(plan.amount1),
            plan.amount0,
            plan.amount1,
            shares
        );
    }

    function _burn(
        RemoveLiquidityParams memory,
        BalanceDelta,
        BalanceDelta,
        uint256 shares
    )
        internal
        override
        nonReentrant
        whenNotPaused
    {
        if (shares == 0) revert ZeroAmount();
        if (balanceOf[msg.sender] < shares) revert InsufficientLiquidity();

        RemoveLiquidityPlan memory plan = _planRemoveLiquidity(shares);

        balanceOf[msg.sender] -= shares;
        totalSupply -= shares;

        poolState.reserve0 -= plan.amount0;
        poolState.reserve1 -= plan.amount1;
        poolState.liquidity -= plan.deltaL;

        emit LiquidityRemoved(
            msg.sender, _denormalizeAmount0(plan.amount0), _denormalizeAmount1(plan.amount1), shares
        );
    }

    function updateLogNormalParams(
        uint256 newMean,
        uint256 newWidth,
        uint256 newBaseHookFeeWad
    )
        external
        onlyOwner
        whenNotPaused
    {
        if (newMean == 0 || newMean >= MAX_MEAN_WAD) revert InvalidMean();
        if (newWidth == 0 || newWidth >= 2 * WAD) revert InvalidWidth();
        if (newBaseHookFeeWad >= WAD / 10) revert FeeTooHigh();

        logNormalParams.mean = newMean;
        logNormalParams.width = newWidth;
        logNormalParams.baseHookFeeWad = newBaseHookFeeWad;

        emit MarketParametersUpdated(newMean, newWidth, newBaseHookFeeWad);
    }

    function updateHookFeeModel(
        uint256 inventoryFeeScaleWad,
        uint256 volatilityFeeScaleWad,
        uint256 tenorFeeScaleWad,
        uint256 maxHookFeeWad
    )
        external
        onlyOwner
        whenNotPaused
    {
        if (maxHookFeeWad >= WAD / 10) revert FeeTooHigh();

        hookFeeModel = HookFeeModel({
            inventoryFeeScaleWad: inventoryFeeScaleWad,
            volatilityFeeScaleWad: volatilityFeeScaleWad,
            tenorFeeScaleWad: tenorFeeScaleWad,
            maxHookFeeWad: maxHookFeeWad
        });

        emit HookFeeModelUpdated(inventoryFeeScaleWad, volatilityFeeScaleWad, tenorFeeScaleWad, maxHookFeeWad);
    }

    function setRealizedVolatilityWad(uint256 newRealizedVolatilityWad) external onlyOwner whenNotPaused {
        realizedVolatilityWad = newRealizedVolatilityWad;
        emit RealizedVolatilityUpdated(newRealizedVolatilityWad);
    }

    function updateInventoryResponseWad(uint256 newInventoryResponseWad) external onlyOwner whenNotPaused {
        if (newInventoryResponseWad == 0 || newInventoryResponseWad > WAD) revert InvalidInventoryResponse();
        inventoryResponseWad = newInventoryResponseWad;
        emit InventoryResponseUpdated(newInventoryResponseWad);
    }

    function emergencyPause() external onlyOwner {
        _pause();
        emit EmergencyPaused(msg.sender);
    }

    function emergencyUnpause() external onlyOwner {
        _unpause();
        emit EmergencyUnpaused(msg.sender);
    }

    function getSharePercentage(address provider) external view returns (uint256 sharePercentage) {
        if (totalSupply == 0) return 0;
        return FullMath.mulDiv(balanceOf[provider], WAD, totalSupply);
    }

    // Convenience quote wrapper. Execution still happens through the inherited addLiquidity/removeLiquidity
    // entrypoints.
    function addLiquidityWithSlippage(
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    )
        external
        view
        whenNotPaused
        returns (uint256 amount0, uint256 amount1, uint256 shares)
    {
        if (block.timestamp > deadline) revert DeadlineExpired();

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());
        AddLiquidityPlan memory plan = _planAddLiquidity(
            sqrtPriceX96,
            AddLiquidityParams({
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                to: msg.sender,
                deadline: deadline,
                tickLower: 0,
                tickUpper: 0,
                salt: bytes32(0)
            })
        );

        amount0 = _denormalizeAmount0(plan.amount0);
        amount1 = _denormalizeAmount1(plan.amount1);
        if (amount0 < amount0Min || amount1 < amount1Min) revert MinAmountNotMet();
        return (amount0, amount1, plan.shares);
    }

    function removeLiquidityWithSlippage(
        uint256 shares,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    )
        external
        view
        whenNotPaused
        returns (uint256 amount0, uint256 amount1)
    {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (balanceOf[msg.sender] < shares) revert InsufficientLiquidity();

        RemoveLiquidityPlan memory plan = _planRemoveLiquidity(shares);
        amount0 = _denormalizeAmount0(plan.amount0);
        amount1 = _denormalizeAmount1(plan.amount1);
        if (amount0 < amount0Min || amount1 < amount1Min) revert MinAmountNotMet();
        return (amount0, amount1);
    }

    // Convenience quote wrapper. Execution happens via PoolManager.swap.
    function swapWithSlippage(
        uint256 amountIn,
        uint256 amountOutMin,
        bool zeroForOne,
        uint256 deadline
    )
        external
        view
        whenNotPaused
        returns (uint256 amountOut)
    {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (amountIn == 0) revert ZeroAmount();

        amountOut = zeroForOne
            ? _denormalizeAmount1(_quoteExactInput0For1(_normalizeAmount0(amountIn)))
            : _denormalizeAmount0(_quoteExactInput1For0(_normalizeAmount1(amountIn)));
        if (amountOut < amountOutMin) revert SlippageExceeded();
    }

    function calculateAmountOut(
        uint256 amountIn,
        bool zeroForOne
    )
        external
        view
        whenNotPaused
        returns (uint256 amountOut)
    {
        if (amountIn == 0 || poolState.liquidity == 0) return 0;
        return zeroForOne
            ? _denormalizeAmount1(_quoteExactInput0For1(_normalizeAmount0(amountIn)))
            : _denormalizeAmount0(_quoteExactInput1For0(_normalizeAmount1(amountIn)));
    }

    function quoteExactInputForSolve(uint256 amountIn, bool zeroForOne) external view returns (uint256 amountOut) {
        if (amountIn == 0 || poolState.liquidity == 0) return 0;
        return zeroForOne ? _quoteExactInput0For1(amountIn) : _quoteExactInput1For0(amountIn);
    }

    function quoteHookFee(uint256 amountIn, bool zeroForOne)
        external
        view
        returns (uint256 hookFeeWad, uint256 hookFeeAmount)
    {
        uint256 normalizedAmountIn = zeroForOne ? _normalizeAmount0(amountIn) : _normalizeAmount1(amountIn);
        hookFeeWad = _computeHookFeeWad(poolState, normalizedAmountIn, zeroForOne);
        uint256 normalizedFeeAmount = FullMath.mulDiv(normalizedAmountIn, hookFeeWad, WAD);
        hookFeeAmount = zeroForOne ? _denormalizeAmount0(normalizedFeeAmount) : _denormalizeAmount1(normalizedFeeAmount);
    }

    function getPoolInfo()
        external
        view
        returns (uint256 reserve0, uint256 reserve1, uint256 liquidityL, uint256 priceWad, bool paused_)
    {
        PoolState memory state = poolState;
        priceWad = state.liquidity == 0 ? 0 : _price0(state.reserve0, state.liquidity);
        return (_denormalizeAmount0(state.reserve0), _denormalizeAmount1(state.reserve1), state.liquidity, priceWad, super.paused());
    }

    function previewExactOutput(uint256 amountOut, bool zeroForOne) external view returns (uint256 amountIn) {
        if (amountOut == 0 || poolState.liquidity == 0) return 0;
        return zeroForOne
            ? _denormalizeAmount0Up(_solveExactInput0For1(_normalizeAmount1(amountOut)))
            : _denormalizeAmount1Up(_solveExactInput1For0(_normalizeAmount0(amountOut)));
    }

    function traceBootstrapPlan(
        uint160 sqrtPriceX96,
        uint256 amount0Desired,
        uint256 amount1Desired
    )
        external
        view
        returns (BootstrapTrace memory trace)
    {
        uint256 priceWad = _sqrtPriceX96ToPriceWad(sqrtPriceX96);
        return _bootstrapTrace(priceWad, _normalizeAmount0(amount0Desired), _normalizeAmount1(amount1Desired));
    }

    function currentInvariant() external view returns (int256) {
        PoolState memory state = poolState;
        if (state.liquidity == 0) return 0;
        return _residual(state.reserve0, state.reserve1, state.liquidity);
    }

    function currentPrice() external view returns (uint256) {
        if (poolState.liquidity == 0) return 0;
        return _price0(poolState.reserve0, poolState.liquidity);
    }

    function _planAddLiquidity(
        uint160 sqrtPriceX96,
        AddLiquidityParams memory params
    )
        internal
        view
        returns (AddLiquidityPlan memory plan)
    {
        if (params.amount0Desired == 0 && params.amount1Desired == 0) revert ZeroAmount();

        PoolState memory state = poolState;
        if (state.liquidity == 0) {
            uint256 priceWad = _sqrtPriceX96ToPriceWad(sqrtPriceX96);
            plan = _bootstrapPlan(priceWad, _normalizeAmount0(params.amount0Desired), _normalizeAmount1(params.amount1Desired));
        } else {
            uint256 normalizedAmount0Desired = _normalizeAmount0(params.amount0Desired);
            uint256 normalizedAmount1Desired = _normalizeAmount1(params.amount1Desired);
            uint256 deltaLFrom0 = normalizedAmount0Desired == 0
                ? type(uint256).max
                : FullMath.mulDiv(state.liquidity, normalizedAmount0Desired, state.reserve0);
            uint256 deltaLFrom1 = normalizedAmount1Desired == 0
                ? type(uint256).max
                : FullMath.mulDiv(state.liquidity, normalizedAmount1Desired, state.reserve1);

            uint256 deltaL = Math.min(deltaLFrom0, deltaLFrom1);
            if (deltaL == 0 || deltaL == type(uint256).max) revert InsufficientLiquidity();

            plan.deltaL = deltaL;
            plan.amount0 = FullMath.mulDiv(state.reserve0, deltaL, state.liquidity);
            plan.amount1 = FullMath.mulDiv(state.reserve1, deltaL, state.liquidity);
            plan.shares = FullMath.mulDiv(totalSupply, deltaL, state.liquidity);
        }

        uint256 amount0Desired = _normalizeAmount0(params.amount0Desired);
        uint256 amount1Desired = _normalizeAmount1(params.amount1Desired);
        uint256 amount0Min = _normalizeAmount0(params.amount0Min);
        uint256 amount1Min = _normalizeAmount1(params.amount1Min);

        if (plan.amount0 > amount0Desired || plan.amount1 > amount1Desired) revert MaxAmountExceeded();
        if (plan.amount0 < amount0Min || plan.amount1 < amount1Min) revert MinAmountNotMet();
    }

    function _bootstrapPlan(
        uint256 priceWad,
        uint256 amount0Desired,
        uint256 amount1Desired
    )
        internal
        view
        returns (AddLiquidityPlan memory plan)
    {
        BootstrapTrace memory trace = _bootstrapTrace(priceWad, amount0Desired, amount1Desired);
        plan.amount0 = trace.amount0;
        plan.amount1 = trace.amount1;
        plan.deltaL = trace.deltaL;
        plan.shares = trace.shares;
    }

    function _bootstrapTrace(
        uint256 priceWad,
        uint256 amount0Desired,
        uint256 amount1Desired
    )
        internal
        view
        returns (BootstrapTrace memory trace)
    {
        if (priceWad == 0) revert InvalidParameters();

        uint256 mu = logNormalParams.mean;
        uint256 sigma = _effectiveWidth();

        trace.priceWad = priceWad;
        trace.desiredPriceWad = amount0Desired == 0 ? 0 : FullMath.mulDiv(amount1Desired, WAD, amount0Desired);
        trace.normalizedAmount0Desired = amount0Desired;
        trace.normalizedAmount1Desired = amount1Desired;

        if (amount0Desired > 0 && amount1Desired > 0
            && _withinBps(trace.desiredPriceWad, priceWad, STABLE_BOOTSTRAP_PRICE_TOLERANCE_BPS))
        {
            (trace.xRatio, trace.yRatio) = _bootstrapStableRatios(priceWad, mu, sigma);
            if (trace.xRatio <= EPS || trace.yRatio <= EPS) revert DomainExceeded();

            uint256 deltaLFrom0 = FullMath.mulDiv(amount0Desired, WAD, trace.xRatio);
            uint256 impliedAmount1 = FullMath.mulDiv(_maxReserve1(deltaLFrom0), trace.yRatio, WAD);
            uint256 deltaLFrom1 = FullMath.mulDiv(amount1Desired, WAD, FullMath.mulDiv(mu, trace.yRatio, WAD));
            uint256 impliedAmount0 = FullMath.mulDiv(deltaLFrom1, trace.xRatio, WAD);

            trace.clip0Bps = _relativeDiffBps(amount0Desired, impliedAmount0);
            trace.clip1Bps = _relativeDiffBps(amount1Desired, impliedAmount1);
            if (trace.clip0Bps > MAX_BOOTSTRAP_CLIP_BPS || trace.clip1Bps > MAX_BOOTSTRAP_CLIP_BPS) {
                revert BootstrapClipTooLarge();
            }

            trace.stableExact = true;
            trace.amount0Limited = true;
            trace.amount0 = amount0Desired;
            trace.amount1 = amount1Desired;
            trace.deltaL = deltaLFrom0;
            trace.rawAmount0 = _denormalizeAmount0(trace.amount0);
            trace.rawAmount1 = _denormalizeAmount1(trace.amount1);
            trace.shares = trace.deltaL;
            return trace;
        } else {
            uint256 d1 = _d1(priceWad, mu, sigma);
            uint256 d2 = _d2(priceWad, mu, sigma);
            trace.xRatio = WAD - _phiWad(int256(d1));
            trace.yRatio = _phiWad(int256(d2));
            if (trace.xRatio <= EPS || trace.yRatio <= EPS) revert DomainExceeded();
        }

        trace.requiredYForX =
            amount0Desired == 0 ? type(uint256).max : FullMath.mulDiv(mu, amount0Desired, trace.xRatio);
        trace.requiredYForX = FullMath.mulDiv(trace.requiredYForX, trace.yRatio, WAD);

        if (amount0Desired > 0 && trace.requiredYForX <= amount1Desired) {
            trace.amount0Limited = true;
            trace.amount0 = amount0Desired;
            trace.deltaL = FullMath.mulDiv(amount0Desired, WAD, trace.xRatio);
            trace.amount1 = FullMath.mulDiv(_maxReserve1(trace.deltaL), trace.yRatio, WAD);
        } else {
            trace.requiredXForY = amount1Desired == 0 ? 0 : FullMath.mulDiv(amount1Desired, WAD, trace.yRatio);
            trace.requiredXForY = FullMath.mulDiv(trace.requiredXForY, trace.xRatio, mu);

            if (amount1Desired == 0 || trace.requiredXForY > amount0Desired) revert InvalidParameters();

            trace.amount0Limited = false;
            trace.amount1 = amount1Desired;
            trace.deltaL = FullMath.mulDiv(amount1Desired, WAD, FullMath.mulDiv(mu, trace.yRatio, WAD));
            trace.amount0 = FullMath.mulDiv(trace.deltaL, trace.xRatio, WAD);
        }

        trace.rawAmount0 = _denormalizeAmount0(trace.amount0);
        trace.rawAmount1 = _denormalizeAmount1(trace.amount1);
        trace.clip0Bps = _clipBps(amount0Desired, trace.amount0);
        trace.clip1Bps = _clipBps(amount1Desired, trace.amount1);
        if (amount0Desired > 0 && amount1Desired > 0
            && _withinBps(trace.desiredPriceWad, priceWad, STABLE_BOOTSTRAP_PRICE_TOLERANCE_BPS)
            && (trace.clip0Bps > MAX_BOOTSTRAP_CLIP_BPS || trace.clip1Bps > MAX_BOOTSTRAP_CLIP_BPS))
        {
            revert BootstrapClipTooLarge();
        }
        trace.shares = trace.deltaL;
    }

    function _planRemoveLiquidity(uint256 shares) internal view returns (RemoveLiquidityPlan memory plan) {
        if (shares == 0 || totalSupply == 0 || poolState.liquidity == 0) revert InsufficientLiquidity();

        PoolState memory state = poolState;
        plan.shares = shares;
        plan.deltaL = FullMath.mulDiv(state.liquidity, shares, totalSupply);
        plan.amount0 = FullMath.mulDiv(state.reserve0, plan.deltaL, state.liquidity);
        plan.amount1 = FullMath.mulDiv(state.reserve1, plan.deltaL, state.liquidity);
    }

    function _executeExactInput0For1(uint256 amountIn) internal returns (uint256 amountOut) {
        PoolState memory state = poolState;
        uint256 hookFeeWad = _computeHookFeeWad(state, amountIn, true);
        uint256 feeAmount = FullMath.mulDiv(amountIn, hookFeeWad, WAD);
        uint256 effectiveIn = amountIn - feeAmount;

        uint256 xAfterFee = state.reserve0 + feeAmount;
        uint256 newLiquidity = _solveLiquidityFromReserves(xAfterFee, state.reserve1);
        uint256 newReserve0 = xAfterFee + effectiveIn;
        _requireReserve0Interior(newReserve0, newLiquidity);

        uint256 newReserve1 = _solveReserve1(newReserve0, newLiquidity);
        if (newReserve1 >= state.reserve1) revert InsufficientLiquidity();

        amountOut = state.reserve1 - newReserve1;

        poolState.reserve0 = newReserve0;
        poolState.reserve1 = newReserve1;
        poolState.liquidity = newLiquidity;

        emit SwapExecuted(
            msg.sender,
            true,
            _denormalizeAmount0(amountIn),
            _denormalizeAmount1(amountOut),
            hookFeeWad,
            _denormalizeAmount0(feeAmount)
        );
    }

    function _executeExactInput1For0(uint256 amountIn) internal returns (uint256 amountOut) {
        PoolState memory state = poolState;
        uint256 hookFeeWad = _computeHookFeeWad(state, amountIn, false);
        uint256 feeAmount = FullMath.mulDiv(amountIn, hookFeeWad, WAD);
        uint256 effectiveIn = amountIn - feeAmount;

        uint256 yAfterFee = state.reserve1 + feeAmount;
        uint256 newLiquidity = _solveLiquidityFromReserves(state.reserve0, yAfterFee);
        uint256 newReserve1 = yAfterFee + effectiveIn;
        _requireReserve1Interior(newReserve1, newLiquidity);

        uint256 newReserve0 = _solveReserve0(newReserve1, newLiquidity);
        if (newReserve0 >= state.reserve0) revert InsufficientLiquidity();

        amountOut = state.reserve0 - newReserve0;

        poolState.reserve0 = newReserve0;
        poolState.reserve1 = newReserve1;
        poolState.liquidity = newLiquidity;

        emit SwapExecuted(
            msg.sender,
            false,
            _denormalizeAmount1(amountIn),
            _denormalizeAmount0(amountOut),
            hookFeeWad,
            _denormalizeAmount1(feeAmount)
        );
    }

    function _executeExactOutput0For1(uint256 amountOut) internal returns (uint256 amountIn) {
        amountIn = _solveExactInput0For1(amountOut);
        return _executeExactInput0For1(amountIn);
    }

    function _executeExactOutput1For0(uint256 amountOut) internal returns (uint256 amountIn) {
        amountIn = _solveExactInput1For0(amountOut);
        return _executeExactInput1For0(amountIn);
    }

    function _solveExactInput0For1(uint256 targetOut) internal view returns (uint256 amountIn) {
        PoolState memory state = poolState;
        if (targetOut == 0 || targetOut >= state.reserve1) revert InsufficientLiquidity();

        return _solveLeastExactInput(targetOut, Math.max(state.reserve0, 1e6), state.liquidity * 4, true);
    }

    function _solveExactInput1For0(uint256 targetOut) internal view returns (uint256 amountIn) {
        PoolState memory state = poolState;
        if (targetOut == 0 || targetOut >= state.reserve0) revert InsufficientLiquidity();

        // solhint-disable-next-line max-line-length
        return _solveLeastExactInput(targetOut, Math.max(state.reserve1, 1e6), _maxReserve1(state.liquidity) * 4, false);
    }

    function _quoteExactInput0For1(uint256 amountIn) internal view returns (uint256 amountOut) {
        PoolState memory state = poolState;
        if (state.liquidity == 0 || amountIn == 0) return 0;

        uint256 feeAmount = FullMath.mulDiv(amountIn, _computeHookFeeWad(state, amountIn, true), WAD);
        uint256 effectiveIn = amountIn - feeAmount;

        uint256 xAfterFee = state.reserve0 + feeAmount;
        uint256 newLiquidity = _solveLiquidityFromReserves(xAfterFee, state.reserve1);
        uint256 newReserve0 = xAfterFee + effectiveIn;
        _requireReserve0Interior(newReserve0, newLiquidity);

        uint256 newReserve1 = _solveReserve1(newReserve0, newLiquidity);
        if (newReserve1 >= state.reserve1) return 0;
        return state.reserve1 - newReserve1;
    }

    function _quoteExactInput1For0(uint256 amountIn) internal view returns (uint256 amountOut) {
        PoolState memory state = poolState;
        if (state.liquidity == 0 || amountIn == 0) return 0;

        uint256 feeAmount = FullMath.mulDiv(amountIn, _computeHookFeeWad(state, amountIn, false), WAD);
        uint256 effectiveIn = amountIn - feeAmount;

        uint256 yAfterFee = state.reserve1 + feeAmount;
        uint256 newLiquidity = _solveLiquidityFromReserves(state.reserve0, yAfterFee);
        uint256 newReserve1 = yAfterFee + effectiveIn;
        _requireReserve1Interior(newReserve1, newLiquidity);

        uint256 newReserve0 = _solveReserve0(newReserve1, newLiquidity);
        if (newReserve0 >= state.reserve0) return 0;
        return state.reserve0 - newReserve0;
    }

    function _computeHookFeeWad(
        PoolState memory state,
        uint256 amountIn,
        bool zeroForOne
    )
        internal
        view
        virtual
        returns (uint256 hookFeeWad)
    {
        amountIn;
        hookFeeWad = logNormalParams.baseHookFeeWad;
        hookFeeWad += _inventoryFeeWad(state, zeroForOne);
        hookFeeWad += _volatilityFeeWad();
        hookFeeWad += _tenorFeeWad();

        uint256 maxHookFeeWad = hookFeeModel.maxHookFeeWad;
        if (hookFeeWad > maxHookFeeWad) hookFeeWad = maxHookFeeWad;
    }

    function _inventoryFeeWad(PoolState memory state, bool zeroForOne) internal view virtual returns (uint256) {
        zeroForOne;
        uint256 scale = hookFeeModel.inventoryFeeScaleWad;
        if (scale == 0 || state.liquidity == 0) return 0;

        uint256 reserve0ValueInToken1 = FullMath.mulDiv(state.reserve0, _price0(state.reserve0, state.liquidity), WAD);
        uint256 totalValueInToken1 = reserve0ValueInToken1 + state.reserve1;
        if (totalValueInToken1 == 0) return 0;

        uint256 imbalance = reserve0ValueInToken1 > state.reserve1
            ? reserve0ValueInToken1 - state.reserve1
            : state.reserve1 - reserve0ValueInToken1;
        uint256 imbalanceWad = FullMath.mulDiv(imbalance, WAD, totalValueInToken1);
        return FullMath.mulDiv(imbalanceWad, scale, WAD);
    }

    function _volatilityFeeWad() internal view virtual returns (uint256) {
        uint256 scale = hookFeeModel.volatilityFeeScaleWad;
        if (scale == 0 || realizedVolatilityWad == 0) return 0;
        return FullMath.mulDiv(realizedVolatilityWad, scale, WAD);
    }

    function _tenorFeeWad() internal view virtual returns (uint256) {
        uint256 scale = hookFeeModel.tenorFeeScaleWad;
        if (scale == 0) return 0;
        return 0;
    }

    function _solveLiquidityFromReserves(
        uint256 reserve0_,
        uint256 reserve1_
    )
        internal
        view
        returns (uint256 liquidity_)
    {
        uint256 mu = logNormalParams.mean;

        uint256 lower0 = reserve0_ + 1;
        uint256 lower1 = FullMath.mulDivRoundingUp(reserve1_, WAD, mu) + 1;
        uint256 low = Math.max(lower0, lower1);
        uint256 high = Math.max(poolState.liquidity, low);

        while (_residual(reserve0_, reserve1_, high) > 0) {
            high *= 2;
            if (high > type(uint256).max / 2) revert DomainExceeded();
        }

        for (uint256 i = 0; i < SEARCH_STEPS; ++i) {
            uint256 mid = (low + high) / 2;
            int256 residual = _residual(reserve0_, reserve1_, mid);
            if (residual > 0) low = mid + 1;
            else high = mid;
        }

        return high;
    }

    // solhint-disable-next-line code-complexity
    function _solveLeastExactInput(
        uint256 targetOut,
        uint256 initialHigh,
        uint256 maxHigh,
        bool zeroForOne
    )
        internal
        view
        returns (uint256 amountIn)
    {
        uint256 low = 0;
        uint256 lowQuote = 0;
        uint256 high = Math.min(initialHigh, maxHigh);
        uint256 highQuote = 0;
        bool highIsValid = false;

        while (true) {
            (bool ok, uint256 sampledQuote) = _safeQuoteExactInput(high, zeroForOne);
            if (ok) {
                if (sampledQuote < lowQuote) revert NonMonotonicQuote();
                highQuote = sampledQuote;
                highIsValid = sampledQuote >= targetOut;
            }

            if (highIsValid || !ok) {
                for (uint256 i = 0; i < SEARCH_STEPS; ++i) {
                    if (low + 1 >= high) break;

                    uint256 mid = (low + high) / 2;
                    (bool midOk, uint256 midQuote) = _safeQuoteExactInput(mid, zeroForOne);
                    if (!midOk) {
                        high = mid;
                        highIsValid = false;
                        continue;
                    }

                    if (midQuote < lowQuote || (highIsValid && midQuote > highQuote)) revert NonMonotonicQuote();

                    if (midQuote >= targetOut) {
                        high = mid;
                        highQuote = midQuote;
                        highIsValid = true;
                    } else {
                        low = mid;
                        lowQuote = midQuote;
                    }
                }

                if (!highIsValid) revert InsufficientLiquidity();

                (bool highOk, uint256 terminalHighQuote) = _safeQuoteExactInput(high, zeroForOne);
                if (!highOk || terminalHighQuote < targetOut) revert NonMonotonicQuote();
                if (high > 0) {
                    (bool prevOk, uint256 prevQuote) = _safeQuoteExactInput(high - 1, zeroForOne);
                    if (prevOk && prevQuote >= targetOut) revert NonMonotonicQuote();
                }
                return high;
            }

            if (high >= maxHigh) revert InsufficientLiquidity();
            low = high;
            lowQuote = sampledQuote;

            if (high > maxHigh / 2) {
                high = maxHigh;
            } else {
                high *= 2;
            }
        }
    }

    function _safeQuoteExactInput(uint256 amountIn, bool zeroForOne)
        internal
        view
        returns (bool ok, uint256 amountOut)
    {
        try this.quoteExactInputForSolve(amountIn, zeroForOne) returns (uint256 quoted) {
            return (true, quoted);
        } catch (bytes memory reason) {
            if (_revertSelector(reason) == DomainExceeded.selector) return (false, 0);
            assembly ("memory-safe") {
                revert(add(reason, 0x20), mload(reason))
            }
        }
    }

    function _revertSelector(bytes memory reason) internal pure returns (bytes4 selector) {
        if (reason.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            selector := mload(add(reason, 0x20))
        }
    }

    function _residual(uint256 reserve0_, uint256 reserve1_, uint256 liquidity_) internal view returns (int256) {
        _requireReserve0Interior(reserve0_, liquidity_);
        _requireReserve1Interior(reserve1_, liquidity_);

        uint256 xOverL = FullMath.mulDiv(reserve0_, WAD, liquidity_);
        uint256 yOverMuL = FullMath.mulDiv(reserve1_, WAD, _maxReserve1(liquidity_));

        return _invPhiWad(xOverL) + _invPhiWad(yOverMuL) + int256(_effectiveWidth());
    }

    function _solveReserve1(uint256 reserve0_, uint256 liquidity_) internal view returns (uint256 reserve1_) {
        _requireReserve0Interior(reserve0_, liquidity_);

        uint256 low = EPS;
        uint256 high = _maxReserve1(liquidity_) - EPS;

        for (uint256 i = 0; i < SEARCH_STEPS; ++i) {
            uint256 mid = (low + high) / 2;
            int256 residual = _residual(reserve0_, mid, liquidity_);
            if (residual > 0) high = mid;
            else low = mid + 1;
        }

        reserve1_ = high;
    }

    function _solveReserve0(uint256 reserve1_, uint256 liquidity_) internal view returns (uint256 reserve0_) {
        _requireReserve1Interior(reserve1_, liquidity_);

        uint256 low = EPS;
        uint256 high = liquidity_ - EPS;

        for (uint256 i = 0; i < SEARCH_STEPS; ++i) {
            uint256 mid = (low + high) / 2;
            int256 residual = _residual(mid, reserve1_, liquidity_);
            if (residual > 0) high = mid;
            else low = mid + 1;
        }

        reserve0_ = high;
    }

    function _price0(uint256 reserve0_, uint256 liquidity_) internal view returns (uint256 priceWad) {
        priceWad = FullMath.mulDiv(logNormalParams.mean, _expWadToUint(_priceExponent(reserve0_, liquidity_)), WAD);
    }

    function _d1(uint256 priceWad, uint256 mu, uint256 sigma) internal pure returns (uint256) {
        int256 lnTerm = SignedWadMath.lnWad(_toInt256(FullMath.mulDiv(priceWad, WAD, mu)));
        int256 numerator = lnTerm + _toInt256(FullMath.mulDiv(sigma, sigma, 2 * WAD));
        if (numerator <= 0) return 0;
        return uint256(numerator) * WAD / sigma;
    }

    function _d2(uint256 priceWad, uint256 mu, uint256 sigma) internal pure returns (uint256) {
        int256 lnTerm = SignedWadMath.lnWad(_toInt256(FullMath.mulDiv(priceWad, WAD, mu)));
        int256 numerator = lnTerm - _toInt256(FullMath.mulDiv(sigma, sigma, 2 * WAD));
        if (numerator <= 0) return 0;
        return uint256(numerator) * WAD / sigma;
    }

    function _phiWad(int256 z) internal pure returns (uint256) {
        return uint256(Gaussian.cdf(z));
    }

    function _invPhiWad(uint256 u) internal pure returns (int256) {
        if (u == 0 || u >= WAD) revert DomainExceeded();
        return Gaussian.ppf(int256(u));
    }

    function _sqrtPriceX96ToPriceWad(uint160 sqrtPriceX96) internal view returns (uint256) {
        uint256 priceQ96 = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), FixedPoint96.Q96);
        uint256 rawPriceWad = FullMath.mulDiv(priceQ96, WAD, FixedPoint96.Q96);
        return FullMath.mulDiv(rawPriceWad, token1Scale, token0Scale);
    }

    function _bootstrapStableRatios(uint256 priceWad, uint256 mu, uint256 sigma)
        internal
        pure
        returns (uint256 xRatio, uint256 yRatio)
    {
        (int256 z1, int256 z2) = _bootstrapSignedZTerms(priceWad, mu, sigma);
        xRatio = WAD - _phiWad(z1);
        yRatio = _phiWad(z2);
    }

    function _bootstrapSignedZTerms(uint256 priceWad, uint256 mu, uint256 sigma)
        internal
        pure
        returns (int256 z1, int256 z2)
    {
        int256 lnTerm = SignedWadMath.lnWad(_toInt256(FullMath.mulDiv(priceWad, WAD, mu)));
        int256 sigmaSquaredOverTwo = _toInt256(FullMath.mulDiv(sigma, sigma, 2 * WAD));
        int256 sigmaInt = _toInt256(sigma);
        z1 = (lnTerm + sigmaSquaredOverTwo) * int256(WAD) / sigmaInt;
        z2 = (lnTerm - sigmaSquaredOverTwo) * int256(WAD) / sigmaInt;
    }

    function _clipBps(uint256 desiredAmount, uint256 acceptedAmount) internal pure returns (uint256) {
        if (desiredAmount == 0 || acceptedAmount >= desiredAmount) return 0;
        return FullMath.mulDiv(desiredAmount - acceptedAmount, 10_000, desiredAmount);
    }

    function _relativeDiffBps(uint256 lhs, uint256 rhs) internal pure returns (uint256) {
        if (lhs == rhs) return 0;
        if (lhs == 0 || rhs == 0) return type(uint256).max;
        uint256 diff = lhs > rhs ? lhs - rhs : rhs - lhs;
        uint256 base = lhs > rhs ? lhs : rhs;
        return FullMath.mulDiv(diff, 10_000, base);
    }

    function _withinBps(uint256 lhs, uint256 rhs, uint256 toleranceBps) internal pure returns (bool) {
        if (lhs == rhs) return true;
        if (lhs == 0 || rhs == 0) return false;

        return _relativeDiffBps(lhs, rhs) <= toleranceBps;
    }

    function _maxReserve1(uint256 liquidity_) internal view returns (uint256) {
        return FullMath.mulDiv(logNormalParams.mean, liquidity_, WAD);
    }

    function _priceExponent(uint256 reserve0_, uint256 liquidity_) internal view returns (int256 exponent) {
        _requireReserve0Interior(reserve0_, liquidity_);

        uint256 u = WAD - FullMath.mulDiv(reserve0_, WAD, liquidity_);
        int256 z = _invPhiWad(u);
        uint256 effectiveWidth = _effectiveWidth();
        int256 sigmaTerm = _toInt256(FullMath.mulDiv(_abs(z), effectiveWidth, WAD));
        if (z < 0) sigmaTerm = -sigmaTerm;
        exponent = sigmaTerm - _toInt256(FullMath.mulDiv(effectiveWidth, effectiveWidth, 2 * WAD));
    }

    function _effectiveWidth() internal view returns (uint256) {
        return FullMath.mulDiv(logNormalParams.width, inventoryResponseWad, WAD);
    }

    function _expWadToUint(int256 exponent) internal pure returns (uint256 result) {
        if (exponent < MIN_EXPONENT_WAD || exponent > MAX_EXPONENT_WAD) revert ExponentOutOfBounds();

        int256 expResult = SignedWadMath.expWad(exponent);
        if (expResult <= 0) revert ExponentOutOfBounds();
        result = uint256(expResult);
    }

    function _toInt256(uint256 value) internal pure returns (int256 result) {
        if (value > uint256(type(int256).max)) revert Int256CastOverflow();
        result = int256(value);
    }

    function _abs(int256 value) internal pure returns (uint256 result) {
        if (value >= 0) return uint256(value);
        result = uint256(-value);
    }

    function _loadTokenDecimals(Currency currency) internal view returns (uint8 decimals_) {
        address token = Currency.unwrap(currency);
        (bool ok, bytes memory data) = token.staticcall(abi.encodeCall(IERC20Decimals.decimals, ()));
        if (!ok || data.length < 32) revert TokenDecimalsQueryFailed();

        decimals_ = abi.decode(data, (uint8));
        if (decimals_ > 18) revert UnsupportedTokenDecimals();
    }

    function _setTokenScales(uint8 token0Decimals_, uint8 token1Decimals_) internal {
        if (token0Decimals_ > 18 || token1Decimals_ > 18) revert UnsupportedTokenDecimals();
        token0Decimals = token0Decimals_;
        token1Decimals = token1Decimals_;
        token0Scale = 10 ** (18 - token0Decimals_);
        token1Scale = 10 ** (18 - token1Decimals_);
    }

    function _normalizeAmount0(uint256 amount) internal view returns (uint256) {
        return amount * token0Scale;
    }

    function _normalizeAmount1(uint256 amount) internal view returns (uint256) {
        return amount * token1Scale;
    }

    function _denormalizeAmount0(uint256 amount) internal view returns (uint256) {
        return amount / token0Scale;
    }

    function _denormalizeAmount1(uint256 amount) internal view returns (uint256) {
        return amount / token1Scale;
    }

    function _denormalizeAmount0Up(uint256 amount) internal view returns (uint256) {
        return _ceilDiv(amount, token0Scale);
    }

    function _denormalizeAmount1Up(uint256 amount) internal view returns (uint256) {
        return _ceilDiv(amount, token1Scale);
    }

    function _ceilDiv(uint256 numerator, uint256 denominator) internal pure returns (uint256) {
        return numerator == 0 ? 0 : ((numerator - 1) / denominator) + 1;
    }

    function _requireReserve0Interior(uint256 reserve0_, uint256 liquidity_) internal pure {
        if (liquidity_ <= 2 * EPS) revert DomainExceeded();
        if (reserve0_ <= EPS || reserve0_ >= liquidity_ - EPS) revert DomainExceeded();
    }

    function _requireReserve1Interior(uint256 reserve1_, uint256 liquidity_) internal view {
        uint256 maxReserve1_ = _maxReserve1(liquidity_);
        if (maxReserve1_ <= 2 * EPS) revert DomainExceeded();
        if (reserve1_ <= EPS || reserve1_ >= maxReserve1_ - EPS) revert DomainExceeded();
    }
}
