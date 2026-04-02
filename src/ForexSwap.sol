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
    uint256 private constant HALF_WAD = 5e17;
    uint256 private constant LN_2 = 693_147_180_559_945_309;
    uint256 private constant MAX_EXP_INPUT = 20e18;
    uint256 private constant Q192 = FixedPoint96.Q96 * FixedPoint96.Q96;
    uint256 private constant LOGISTIC_A = 1_702_000_000_000_000_000;
    uint256 private constant SEARCH_STEPS = 64;

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

        uint256 xOverL = FullMath.mulDiv(state.reserve0, WAD, state.liquidity);
        uint256 yOverMuL = FullMath.mulDiv(state.reserve1, WAD, _maxReserve1(state.liquidity));
        return _invPhiWad(xOverL) + _invPhiWad(yOverMuL) + int256(logNormalParams.width);
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
        if (xRatio == 0 || yRatio == 0) revert DomainExceeded();

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
        uint256 deltaL = _feeToLiquidity0(state, feeAmount);
        uint256 newLiquidity = state.liquidity + deltaL;
        uint256 newReserve0 = state.reserve0 + amountIn;
        if (newReserve0 >= newLiquidity) revert DomainExceeded();

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
        uint256 deltaL = _feeToLiquidity1(state, feeAmount);
        uint256 newLiquidity = state.liquidity + deltaL;
        uint256 newReserve1 = state.reserve1 + amountIn;
        if (newReserve1 >= _maxReserve1(newLiquidity)) revert DomainExceeded();

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

        uint256 low = 1;
        uint256 high = Math.max(state.reserve0, 1e6);
        while (_quoteExactInput0For1(high) < targetOut) {
            high *= 2;
            if (high >= state.liquidity * 4) revert InsufficientLiquidity();
        }

        for (uint256 i = 0; i < SEARCH_STEPS; ++i) {
            uint256 mid = (low + high) / 2;
            if (_quoteExactInput0For1(mid) >= targetOut) high = mid;
            else low = mid + 1;
        }
        return high;
    }

    function _solveExactInput1For0(uint256 targetOut) internal view returns (uint256 amountIn) {
        PoolState memory state = poolState;
        if (targetOut == 0 || targetOut >= state.reserve0) revert InsufficientLiquidity();

        uint256 low = 1;
        uint256 high = Math.max(state.reserve1, 1e6);
        while (_quoteExactInput1For0(high) < targetOut) {
            high *= 2;
            if (high >= _maxReserve1(state.liquidity) * 4) revert InsufficientLiquidity();
        }

        for (uint256 i = 0; i < SEARCH_STEPS; ++i) {
            uint256 mid = (low + high) / 2;
            if (_quoteExactInput1For0(mid) >= targetOut) high = mid;
            else low = mid + 1;
        }
        return high;
    }

    function _quoteExactInput0For1(uint256 amountIn) internal view returns (uint256 amountOut) {
        PoolState memory state = poolState;
        if (state.liquidity == 0 || amountIn == 0) return 0;

        uint256 feeAmount = FullMath.mulDiv(amountIn, logNormalParams.swapFee, WAD);
        uint256 deltaL = _feeToLiquidity0(state, feeAmount);
        uint256 newLiquidity = state.liquidity + deltaL;
        uint256 newReserve0 = state.reserve0 + amountIn;
        if (newReserve0 >= newLiquidity) revert DomainExceeded();

        uint256 newReserve1 = _solveReserve1(newReserve0, newLiquidity);
        if (newReserve1 >= state.reserve1) return 0;
        return state.reserve1 - newReserve1;
    }

    function _quoteExactInput1For0(uint256 amountIn) internal view returns (uint256 amountOut) {
        PoolState memory state = poolState;
        if (state.liquidity == 0 || amountIn == 0) return 0;

        uint256 feeAmount = FullMath.mulDiv(amountIn, logNormalParams.swapFee, WAD);
        uint256 deltaL = _feeToLiquidity1(state, feeAmount);
        uint256 newLiquidity = state.liquidity + deltaL;
        uint256 newReserve1 = state.reserve1 + amountIn;
        if (newReserve1 >= _maxReserve1(newLiquidity)) revert DomainExceeded();

        uint256 newReserve0 = _solveReserve0(newReserve1, newLiquidity);
        if (newReserve0 >= state.reserve0) return 0;
        return state.reserve0 - newReserve0;
    }

    function _feeToLiquidity0(PoolState memory state, uint256 feeAmount) internal view returns (uint256 deltaL) {
        if (feeAmount == 0) return 0;
        uint256 priceWad = _price0(state.reserve0, state.liquidity);
        uint256 totalValueY = FullMath.mulDiv(priceWad, state.reserve0, WAD) + state.reserve1;
        uint256 feeValueY = FullMath.mulDiv(priceWad, feeAmount, WAD);
        return FullMath.mulDiv(state.liquidity, feeValueY, totalValueY);
    }

    function _feeToLiquidity1(PoolState memory state, uint256 feeAmount) internal view returns (uint256 deltaL) {
        if (feeAmount == 0) return 0;
        uint256 priceWad = _price0(state.reserve0, state.liquidity);
        uint256 totalValueY = FullMath.mulDiv(priceWad, state.reserve0, WAD) + state.reserve1;
        return FullMath.mulDiv(state.liquidity, feeAmount, totalValueY);
    }

    function _solveReserve1(uint256 reserve0_, uint256 liquidity_) internal view returns (uint256 reserve1_) {
        uint256 xOverL = FullMath.mulDiv(reserve0_, WAD, liquidity_);
        int256 inside = -int256(logNormalParams.width) - _invPhiWad(xOverL);
        uint256 yRatio = _phiWad(inside);
        reserve1_ = FullMath.mulDiv(_maxReserve1(liquidity_), yRatio, WAD);
    }

    function _solveReserve0(uint256 reserve1_, uint256 liquidity_) internal view returns (uint256 reserve0_) {
        uint256 yOverMuL = FullMath.mulDiv(reserve1_, WAD, _maxReserve1(liquidity_));
        int256 inside = -int256(logNormalParams.width) - _invPhiWad(yOverMuL);
        uint256 xRatio = _phiWad(inside);
        reserve0_ = FullMath.mulDiv(liquidity_, xRatio, WAD);
    }

    function _price0(uint256 reserve0_, uint256 liquidity_) internal view returns (uint256 priceWad) {
        uint256 u = WAD - FullMath.mulDiv(reserve0_, WAD, liquidity_);
        int256 z = _invPhiWad(u);
        int256 sigmaTerm = int256(FullMath.mulDiv(uint256(z >= 0 ? z : -z), logNormalParams.width, WAD));
        if (z < 0) sigmaTerm = -sigmaTerm;
        int256 exponent = sigmaTerm - int256(FullMath.mulDiv(logNormalParams.width, logNormalParams.width, 2 * WAD));
        priceWad = FullMath.mulDiv(logNormalParams.mean, _expSignedWad(exponent), WAD);
    }

    function _d1(uint256 priceWad, uint256 mu, uint256 sigma) internal pure returns (uint256) {
        int256 lnTerm = _lnWad(FullMath.mulDiv(priceWad, WAD, mu));
        int256 numerator = lnTerm + int256(FullMath.mulDiv(sigma, sigma, 2 * WAD));
        if (numerator <= 0) return 0;
        return uint256(numerator) * WAD / sigma;
    }

    function _d2(uint256 priceWad, uint256 mu, uint256 sigma) internal pure returns (uint256) {
        int256 lnTerm = _lnWad(FullMath.mulDiv(priceWad, WAD, mu));
        int256 numerator = lnTerm - int256(FullMath.mulDiv(sigma, sigma, 2 * WAD));
        if (numerator <= 0) return 0;
        return uint256(numerator) * WAD / sigma;
    }

    function _phiWad(int256 z) internal pure returns (uint256) {
        bool negative = z < 0;
        uint256 scaled = FullMath.mulDiv(uint256(negative ? -z : z), LOGISTIC_A, WAD);
        uint256 expTerm = _expWad(scaled);

        if (negative) {
            return FullMath.mulDiv(WAD, WAD, WAD + expTerm);
        }
        return FullMath.mulDiv(expTerm, WAD, WAD + expTerm);
    }

    function _invPhiWad(uint256 u) internal pure returns (int256) {
        if (u == 0 || u >= WAD) revert DomainExceeded();
        int256 lnOdds = _lnWad(FullMath.mulDiv(u, WAD, WAD - u));
        return (lnOdds * int256(WAD)) / int256(LOGISTIC_A);
    }

    function _expSignedWad(int256 x) internal pure returns (uint256) {
        if (x == 0) return WAD;
        if (x > 0) return _expWad(uint256(x));

        uint256 absX = uint256(-x);
        uint256 expAbs = _expWad(absX);
        return FullMath.mulDiv(WAD, WAD, expAbs);
    }

    function _expWad(uint256 x) internal pure returns (uint256) {
        if (x == 0) return WAD;
        if (x > MAX_EXP_INPUT) return type(uint256).max / 2;

        uint256 k = x / LN_2;
        uint256 r = x % LN_2;

        uint256 series = WAD;
        uint256 term = WAD;

        for (uint256 i = 1; i <= 8; ++i) {
            term = FullMath.mulDiv(term, r, i * WAD);
            series += term;
        }

        return series << k;
    }

    function _lnWad(uint256 x) internal pure returns (int256) {
        if (x == 0) revert DomainExceeded();
        if (x == WAD) return 0;

        bool invert = x < WAD;
        uint256 y = invert ? FullMath.mulDiv(WAD, WAD, x) : x;
        uint256 k;

        while (y >= 2 * WAD) {
            y /= 2;
            ++k;
        }

        int256 u = int256(y) - int256(WAD);
        int256 result = u;
        int256 term = u;

        for (uint256 i = 2; i <= 8; ++i) {
            term = (term * u) / int256(WAD);
            int256 contribution = term / int256(i);
            result = i % 2 == 0 ? result - contribution : result + contribution;
        }

        result += int256(k) * int256(LN_2);
        return invert ? -result : result;
    }

    function _sqrtPriceX96ToPriceWad(uint160 sqrtPriceX96) internal pure returns (uint256) {
        uint256 priceQ96 = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), FixedPoint96.Q96);
        return FullMath.mulDiv(priceQ96, WAD, FixedPoint96.Q96);
    }

    function _maxReserve1(uint256 liquidity_) internal view returns (uint256) {
        return FullMath.mulDiv(logNormalParams.mean, liquidity_, WAD);
    }
}
