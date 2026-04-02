// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {BaseCustomCurve} from "uniswap-hooks/src/base/BaseCustomCurve.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Math} from "v4-core/lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {Ownable} from "v4-core/lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {Pausable} from "v4-core/lib/openzeppelin-contracts/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "v4-core/lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Gaussian} from "./libraries/Gaussian.sol";
import {SignedWadMath} from "./libraries/SignedWadMath.sol";

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

    event ParametersUpdated(uint256 newMean, uint256 newWidth, uint256 newSwapFee);
    event LiquidityAdded(address indexed provider, uint256 amount0, uint256 amount1, uint256 shares);
    event LiquidityRemoved(address indexed provider, uint256 amount0, uint256 amount1, uint256 shares);
    event SwapExecuted(address indexed trader, bool zeroForOne, uint256 amountIn, uint256 amountOut, uint256 feeAmount);
    event EmergencyPaused(address indexed admin);
    event EmergencyUnpaused(address indexed admin);

    struct LogNormalParams {
        uint256 mean;
        uint256 width;
        uint256 swapFee;
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

    struct RemoveLiquidityPlan {
        uint256 amount0;
        uint256 amount1;
        uint256 shares;
        uint256 deltaL;
    }

    uint256 private constant WAD = 1e18;
    uint256 private constant SEARCH_STEPS = 64;
    uint256 private constant EPS = 1e9;
    int256 private constant MAX_EXPONENT_WAD = 20e18;
    int256 private constant MIN_EXPONENT_WAD = -20e18;

    mapping(address account => uint256 balance) public balanceOf;
    uint256 public totalSupply;
    LogNormalParams public logNormalParams = LogNormalParams({mean: 1e18, width: 2e17, swapFee: 3e15});
    PoolState public poolState;

    constructor(IPoolManager _poolManager) BaseCustomCurve(_poolManager) Ownable(msg.sender) {}

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
                ? _executeExactInput0For1(specifiedAmount)
                : _executeExactInput1For0(specifiedAmount);
        } else {
            unspecifiedAmount = swapParams.zeroForOne
                ? _executeExactOutput0For1(specifiedAmount)
                : _executeExactOutput1For0(specifiedAmount);
        }
    }

    function _getAddLiquidity(uint160 sqrtPriceX96, AddLiquidityParams memory params)
        internal
        override
        returns (bytes memory, uint256)
    {
        AddLiquidityPlan memory plan = _planAddLiquidity(sqrtPriceX96, params);
        return (abi.encode(int128(uint128(plan.amount0)), int128(uint128(plan.amount1))), plan.shares);
    }

    function _getRemoveLiquidity(RemoveLiquidityParams memory params)
        internal
        override
        returns (bytes memory, uint256)
    {
        RemoveLiquidityPlan memory plan = _planRemoveLiquidity(params.liquidity);
        return (abi.encode(-int128(uint128(plan.amount0)), -int128(uint128(plan.amount1))), plan.shares);
    }

    function _getAmountIn(AddLiquidityParams memory params)
        internal
        view
        override
        returns (uint256 amount0, uint256 amount1, uint256 shares)
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());
        AddLiquidityPlan memory plan = _planAddLiquidity(sqrtPriceX96, params);
        return (plan.amount0, plan.amount1, plan.shares);
    }

    function _getAmountOut(RemoveLiquidityParams memory params)
        internal
        view
        override
        returns (uint256 amount0, uint256 amount1, uint256 shares)
    {
        RemoveLiquidityPlan memory plan = _planRemoveLiquidity(params.liquidity);
        return (plan.amount0, plan.amount1, plan.shares);
    }

    function _mint(
        AddLiquidityParams memory params,
        BalanceDelta,
        BalanceDelta,
        uint256 shares
    ) internal override nonReentrant whenNotPaused {
        if (shares == 0) revert ZeroAmount();

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());
        AddLiquidityPlan memory plan = _planAddLiquidity(sqrtPriceX96, params);

        poolState.reserve0 += plan.amount0;
        poolState.reserve1 += plan.amount1;
        poolState.liquidity += plan.deltaL;

        balanceOf[params.to] += shares;
        totalSupply += shares;

        emit LiquidityAdded(params.to, plan.amount0, plan.amount1, shares);
    }

    function _burn(
        RemoveLiquidityParams memory,
        BalanceDelta,
        BalanceDelta,
        uint256 shares
    ) internal override nonReentrant whenNotPaused {
        if (shares == 0) revert ZeroAmount();
        if (balanceOf[msg.sender] < shares) revert InsufficientLiquidity();

        RemoveLiquidityPlan memory plan = _planRemoveLiquidity(shares);

        balanceOf[msg.sender] -= shares;
        totalSupply -= shares;

        poolState.reserve0 -= plan.amount0;
        poolState.reserve1 -= plan.amount1;
        poolState.liquidity -= plan.deltaL;

        emit LiquidityRemoved(msg.sender, plan.amount0, plan.amount1, shares);
    }

    function updateLogNormalParams(uint256 newMean, uint256 newWidth, uint256 newSwapFee)
        external
        onlyOwner
        whenNotPaused
    {
        if (newMean == 0 || newMean >= 100 * WAD) revert InvalidMean();
        if (newWidth == 0 || newWidth >= 2 * WAD) revert InvalidWidth();
        if (newSwapFee >= WAD / 10) revert FeeTooHigh();

        logNormalParams.mean = newMean;
        logNormalParams.width = newWidth;
        logNormalParams.swapFee = newSwapFee;

        emit ParametersUpdated(newMean, newWidth, newSwapFee);
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

    // Convenience quote wrapper. Execution still happens through the inherited addLiquidity/removeLiquidity entrypoints.
    function addLiquidityWithSlippage(
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) external view whenNotPaused returns (uint256 amount0, uint256 amount1, uint256 shares) {
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

        if (plan.amount0 < amount0Min || plan.amount1 < amount1Min) revert MinAmountNotMet();
        return (plan.amount0, plan.amount1, plan.shares);
    }

    function removeLiquidityWithSlippage(
        uint256 shares,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) external view whenNotPaused returns (uint256 amount0, uint256 amount1) {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (balanceOf[msg.sender] < shares) revert InsufficientLiquidity();

        RemoveLiquidityPlan memory plan = _planRemoveLiquidity(shares);
        if (plan.amount0 < amount0Min || plan.amount1 < amount1Min) revert MinAmountNotMet();
        return (plan.amount0, plan.amount1);
    }

    // Convenience quote wrapper. Execution happens via PoolManager.swap.
    function swapWithSlippage(
        uint256 amountIn,
        uint256 amountOutMin,
        bool zeroForOne,
        uint256 deadline
    ) external view whenNotPaused returns (uint256 amountOut) {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (amountIn == 0) revert ZeroAmount();

        amountOut = zeroForOne ? _quoteExactInput0For1(amountIn) : _quoteExactInput1For0(amountIn);
        if (amountOut < amountOutMin) revert SlippageExceeded();
    }

    function calculateAmountOut(uint256 amountIn, bool zeroForOne)
        external
        view
        whenNotPaused
        returns (uint256 amountOut)
    {
        if (amountIn == 0 || poolState.liquidity == 0) return 0;
        return zeroForOne ? _quoteExactInput0For1(amountIn) : _quoteExactInput1For0(amountIn);
    }

    function getPoolInfo()
        external
        view
        returns (
            uint256 reserve0,
            uint256 reserve1,
            uint256 liquidityL,
            uint256 priceWad,
            bool paused_
        )
    {
        PoolState memory state = poolState;
        priceWad = state.liquidity == 0 ? 0 : _price0(state.reserve0, state.liquidity);
        return (state.reserve0, state.reserve1, state.liquidity, priceWad, super.paused());
    }

    function previewExactOutput(uint256 amountOut, bool zeroForOne) external view returns (uint256 amountIn) {
        if (amountOut == 0 || poolState.liquidity == 0) return 0;
        return zeroForOne ? _solveExactInput0For1(amountOut) : _solveExactInput1For0(amountOut);
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

    function _planAddLiquidity(uint160 sqrtPriceX96, AddLiquidityParams memory params)
        internal
        view
        returns (AddLiquidityPlan memory plan)
    {
        if (params.amount0Desired == 0 && params.amount1Desired == 0) revert ZeroAmount();

        PoolState memory state = poolState;
        if (state.liquidity == 0) {
            uint256 priceWad = _sqrtPriceX96ToPriceWad(sqrtPriceX96);
            plan = _bootstrapPlan(priceWad, params.amount0Desired, params.amount1Desired);
        } else {
            uint256 deltaLFrom0 = params.amount0Desired == 0
                ? type(uint256).max
                : FullMath.mulDiv(state.liquidity, params.amount0Desired, state.reserve0);
            uint256 deltaLFrom1 = params.amount1Desired == 0
                ? type(uint256).max
                : FullMath.mulDiv(state.liquidity, params.amount1Desired, state.reserve1);

            uint256 deltaL = Math.min(deltaLFrom0, deltaLFrom1);
            if (deltaL == 0 || deltaL == type(uint256).max) revert InsufficientLiquidity();

            plan.deltaL = deltaL;
            plan.amount0 = FullMath.mulDiv(state.reserve0, deltaL, state.liquidity);
            plan.amount1 = FullMath.mulDiv(state.reserve1, deltaL, state.liquidity);
            plan.shares = FullMath.mulDiv(totalSupply, deltaL, state.liquidity);
        }

        if (plan.amount0 > params.amount0Desired || plan.amount1 > params.amount1Desired) revert MaxAmountExceeded();
        if (plan.amount0 < params.amount0Min || plan.amount1 < params.amount1Min) revert MinAmountNotMet();
    }

    function _bootstrapPlan(uint256 priceWad, uint256 amount0Desired, uint256 amount1Desired)
        internal
        view
        returns (AddLiquidityPlan memory plan)
    {
        if (priceWad == 0) revert InvalidParameters();

        uint256 mu = logNormalParams.mean;
        uint256 sigma = logNormalParams.width;
        uint256 d1 = _d1(priceWad, mu, sigma);
        uint256 d2 = _d2(priceWad, mu, sigma);

        uint256 xRatio = WAD - _phiWad(int256(d1));
        uint256 yRatio = _phiWad(int256(d2));
        if (xRatio <= EPS || yRatio <= EPS) revert DomainExceeded();

        uint256 requiredYForX = amount0Desired == 0
            ? type(uint256).max
            : FullMath.mulDiv(mu, amount0Desired, xRatio);
        requiredYForX = FullMath.mulDiv(requiredYForX, yRatio, WAD);

        if (amount0Desired > 0 && requiredYForX <= amount1Desired) {
            plan.amount0 = amount0Desired;
            plan.deltaL = FullMath.mulDiv(amount0Desired, WAD, xRatio);
            plan.amount1 = FullMath.mulDiv(_maxReserve1(plan.deltaL), yRatio, WAD);
        } else {
            uint256 requiredXForY = amount1Desired == 0
                ? 0
                : FullMath.mulDiv(amount1Desired, WAD, yRatio);
            requiredXForY = FullMath.mulDiv(requiredXForY, xRatio, mu);

            if (amount1Desired == 0 || requiredXForY > amount0Desired) revert InvalidParameters();

            plan.amount1 = amount1Desired;
            plan.deltaL = FullMath.mulDiv(amount1Desired, WAD, FullMath.mulDiv(mu, yRatio, WAD));
            plan.amount0 = FullMath.mulDiv(plan.deltaL, xRatio, WAD);
        }

        plan.shares = plan.deltaL;
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
        uint256 feeAmount = FullMath.mulDiv(amountIn, logNormalParams.swapFee, WAD);
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

        emit SwapExecuted(msg.sender, true, amountIn, amountOut, feeAmount);
    }

    function _executeExactInput1For0(uint256 amountIn) internal returns (uint256 amountOut) {
        PoolState memory state = poolState;
        uint256 feeAmount = FullMath.mulDiv(amountIn, logNormalParams.swapFee, WAD);
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

        emit SwapExecuted(msg.sender, false, amountIn, amountOut, feeAmount);
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

        return _solveLeastExactInput(targetOut, Math.max(state.reserve1, 1e6), _maxReserve1(state.liquidity) * 4, false);
    }

    function _quoteExactInput0For1(uint256 amountIn) internal view returns (uint256 amountOut) {
        PoolState memory state = poolState;
        if (state.liquidity == 0 || amountIn == 0) return 0;

        uint256 feeAmount = FullMath.mulDiv(amountIn, logNormalParams.swapFee, WAD);
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

        uint256 feeAmount = FullMath.mulDiv(amountIn, logNormalParams.swapFee, WAD);
        uint256 effectiveIn = amountIn - feeAmount;

        uint256 yAfterFee = state.reserve1 + feeAmount;
        uint256 newLiquidity = _solveLiquidityFromReserves(state.reserve0, yAfterFee);
        uint256 newReserve1 = yAfterFee + effectiveIn;
        _requireReserve1Interior(newReserve1, newLiquidity);

        uint256 newReserve0 = _solveReserve0(newReserve1, newLiquidity);
        if (newReserve0 >= state.reserve0) return 0;
        return state.reserve0 - newReserve0;
    }

    function _solveLiquidityFromReserves(uint256 reserve0_, uint256 reserve1_) internal view returns (uint256 liquidity_) {
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

    function _solveLeastExactInput(
        uint256 targetOut,
        uint256 initialHigh,
        uint256 maxHigh,
        bool zeroForOne
    ) internal view returns (uint256 amountIn) {
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

    function _safeQuoteExactInput(uint256 amountIn, bool zeroForOne) internal view returns (bool ok, uint256 amountOut) {
        try this.calculateAmountOut(amountIn, zeroForOne) returns (uint256 quoted) {
            return (true, quoted);
        } catch {
            return (false, 0);
        }
    }

    function _residual(uint256 reserve0_, uint256 reserve1_, uint256 liquidity_)
        internal
        view
        returns (int256)
    {
        _requireReserve0Interior(reserve0_, liquidity_);
        _requireReserve1Interior(reserve1_, liquidity_);

        uint256 xOverL = FullMath.mulDiv(reserve0_, WAD, liquidity_);
        uint256 yOverMuL = FullMath.mulDiv(reserve1_, WAD, _maxReserve1(liquidity_));

        return _invPhiWad(xOverL) + _invPhiWad(yOverMuL) + int256(logNormalParams.width);
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
        _requireReserve0Interior(reserve0_, liquidity_);

        uint256 u = WAD - FullMath.mulDiv(reserve0_, WAD, liquidity_);
        int256 z = _invPhiWad(u);
        int256 sigmaTerm = _toInt256(FullMath.mulDiv(_abs(z), logNormalParams.width, WAD));
        if (z < 0) sigmaTerm = -sigmaTerm;
        int256 exponent = sigmaTerm - _toInt256(FullMath.mulDiv(logNormalParams.width, logNormalParams.width, 2 * WAD));
        priceWad = FullMath.mulDiv(logNormalParams.mean, _expWadToUint(exponent), WAD);
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

    function _sqrtPriceX96ToPriceWad(uint160 sqrtPriceX96) internal pure returns (uint256) {
        uint256 priceQ96 = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), FixedPoint96.Q96);
        return FullMath.mulDiv(priceQ96, WAD, FixedPoint96.Q96);
    }

    function _maxReserve1(uint256 liquidity_) internal view returns (uint256) {
        return FullMath.mulDiv(logNormalParams.mean, liquidity_, WAD);
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
