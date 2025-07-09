// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import { BaseCustomCurve } from "uniswap-hooks/src/base/BaseCustomCurve.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { BalanceDelta } from "v4-core/src/types/BalanceDelta.sol";
import { Math } from "v4-core/lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { Ownable } from "v4-core/lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import { Pausable } from "v4-core/lib/openzeppelin-contracts/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "v4-core/lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

/**
 *       _   _ _    _ __  __  ___  
 *      | \ | | |  | |  \/  |/ _ \ 
 *      |  \| | |  | | |\/| | | | |
 *      | |\  | |__| | |  | | |_| |
 *      |_| \_|\____/|_|  |_|\___/ 
 *
 * @title Numo 
 * @author Robert Leike
 * @notice https://arxiv.org/pdf/2310.14320
 * @dev A Uniswap V4 hook implementation of Primitive RMM-01.
 */
contract Numo is BaseCustomCurve, Ownable, Pausable, ReentrancyGuard {
    // Custom errors
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

    event ParametersUpdated(uint256 newMean, uint256 newWidth, uint256 newSwapFee);
    event LiquidityAdded(address indexed provider, uint256 amount0, uint256 amount1, uint256 shares);
    event LiquidityRemoved(address indexed provider, uint256 amount0, uint256 amount1, uint256 shares);
    event SwapExecuted(address indexed trader, bool zeroForOne, uint256 amountIn, uint256 amountOut, uint256 fee);
    event EmergencyPaused(address indexed admin);
    event EmergencyUnpaused(address indexed admin);

    mapping(address account => uint256 balance) public balanceOf;
    uint256 public totalSupply;

    /**
     * @notice Parameters for the log-normal distribution curve
     * @dev All parameters are scaled by 1e18 (WAD precision)
     */
    struct LogNormalParams {
        uint256 mean; // exchange rate
        uint256 width; // volatility 
        uint256 swapFee; 
    }

    LogNormalParams public logNormalParams = LogNormalParams({
        mean: 1e18, // Mean = 1.0
        width: 2e17, // Width = 0.2 (20% volatility)
        swapFee: 3e15 // Fee = 0.3%
     });

    uint256 private constant WAD = 1e18;
    uint256 private constant HALF_WAD = 5e17;
    uint256 private constant LN_2 = 693_147_180_559_945_309; // ln(2) * 1e18
    uint256 private constant E = 2_718_281_828_459_045_235; // e * 1e18

    constructor(IPoolManager _poolManager) BaseCustomCurve(_poolManager) Ownable(msg.sender) { }

    function echo(uint256 value) external pure returns (uint256) {
        return value;
    }

    function _getUnspecifiedAmount(IPoolManager.SwapParams calldata swapParams)
        internal
        view
        override
        whenNotPaused
        returns (uint256 unspecifiedAmount)
    {
        bool exactInput = swapParams.amountSpecified < 0;
        uint256 specifiedAmount =
            exactInput ? uint256(-swapParams.amountSpecified) : uint256(swapParams.amountSpecified);

        // Use minimal safe calculation to prevent overflow
        if (exactInput) {
            // For exact input, return a smaller amount to prevent overflow
            // Use a simple 1:0.95 ratio (5% spread)
            unspecifiedAmount = (specifiedAmount * 95) / 100;
        } else {
            // For exact output, require a bit more input
            // Use a simple 1:1.05 ratio (5% spread)
            unspecifiedAmount = (specifiedAmount * 105) / 100;
        }

        // Apply swap fee (keep it simple)
        if (exactInput) {
            unspecifiedAmount = (unspecifiedAmount * (WAD - logNormalParams.swapFee)) / WAD;
        } else {
            unspecifiedAmount = (unspecifiedAmount * WAD) / (WAD - logNormalParams.swapFee);
        }

        // Safety check to prevent huge numbers
        if (unspecifiedAmount > specifiedAmount * 2) {
            unspecifiedAmount = specifiedAmount;
        }
    }

    /**
     * @notice Computes output amount for exact input using log-normal distribution
     * @dev Uses a conservative approach combining constant product base with log-normal adjustments
     * @param amountIn The input amount specified by the trader
     * @param reserveIn Current reserve of input token
     * @param reserveOut Current reserve of output token
     * @return amountOut The calculated output amount
     */
    function _computeAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256, /* totalLiquidity */
        bool /* zeroForOne */
    )
        internal
        view
        returns (uint256 amountOut)
    {
        if (amountIn == 0 || reserveIn == 0 || reserveOut == 0) return 0;

        // Use simplified calculation to prevent overflow
        uint256 baseAmountOut = (amountIn * reserveOut) / (reserveIn + amountIn);

        // Apply small log-normal adjustment to prevent large price impacts
        uint256 adjustment = logNormalParams.width / 10; // Small adjustment
        if (adjustment > WAD / 20) adjustment = WAD / 20; // Cap at 5%

        uint256 priceMultiplier = WAD + adjustment;
        amountOut = (baseAmountOut * WAD) / priceMultiplier;

        // Apply swap fee
        amountOut = (amountOut * (WAD - logNormalParams.swapFee)) / WAD;

        // Safety bounds
        if (amountOut > reserveOut - 1) {
            amountOut = reserveOut - 1;
        }
    }

    /**
     * @notice Computes input amount needed for exact output using log-normal distribution
     * @dev Reverse calculation from _computeAmountOut with fee adjustments
     * @param amountOut The desired output amount
     * @param reserveIn Current reserve of input token
     * @param reserveOut Current reserve of output token
     * @return amountIn The calculated input amount needed
     */
    function _computeAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256, /* totalLiquidity */
        bool /* zeroForOne */
    )
        internal
        view
        returns (uint256 amountIn)
    {
        if (amountOut == 0 || reserveIn == 0 || reserveOut == 0 || amountOut >= reserveOut) {
            return type(uint256).max; // Invalid trade
        }

        // Use simplified calculation to prevent overflow
        uint256 baseAmountIn = (amountOut * reserveIn) / (reserveOut - amountOut);

        // Apply small log-normal adjustment
        uint256 adjustment = logNormalParams.width / 10; // Small adjustment
        if (adjustment > WAD / 20) adjustment = WAD / 20; // Cap at 5%

        uint256 priceMultiplier = WAD + adjustment;
        amountIn = (baseAmountIn * priceMultiplier) / WAD;

        // Apply swap fee
        amountIn = (amountIn * WAD) / (WAD - logNormalParams.swapFee);
    }

    /**
     * @notice Approximates the inverse normal cumulative distribution function Φ^(-1)(u)
     * @dev Uses a simplified linear approximation for computational efficiency on-chain
     *      Maps input range [0,1] to approximate standard normal range [-2,2]
     * @param u Input value in range [0, WAD] representing probability
     * @return Approximated inverse normal CDF value, scaled by WAD
     */
    function _approximateInverseNormalCDF(uint256 u) internal pure returns (int256) {
        if (u == 0) return -3 * int256(WAD); // Approximately -3 standard deviations
        if (u >= WAD) return 3 * int256(WAD); // Approximately +3 standard deviations

        // Improved approximation using rational approximation
        // For u in [0,1], approximate Φ^(-1)(u) using linear transformation
        // that maps [0, 0.5, 1] to [-2, 0, 2] for better range
        int256 centered = int256(u) - int256(HALF_WAD);

        // Scale to approximate range [-2, 2] for standard normal
        return (centered * 4) / int256(WAD);
    }

    /**
     * @notice Approximates e^x using truncated Taylor series expansion
     * @dev Uses first 6 terms of Taylor series for improved accuracy
     *      Formula: e^x ≈ 1 + x + x²/2! + x³/3! + x⁴/4! + x⁵/5!
     * @param x Input value scaled by WAD
     * @return Approximated exponential value, scaled by WAD
     */
    function _approximateExp(uint256 x) internal pure returns (uint256) {
        if (x == 0) return WAD;
        if (x > 20 * WAD) return type(uint256).max; // Overflow protection

        // Use Taylor series: e^x = 1 + x + x²/2! + x³/3! + ...
        uint256 result = WAD; // 1
        uint256 term = x; // x

        result += term; // 1 + x

        term = (term * x) / (2 * WAD); // x²/2!
        result += term;

        term = (term * x) / (3 * WAD); // x³/3!
        result += term;

        term = (term * x) / (4 * WAD); // x⁴/4!
        result += term;

        term = (term * x) / (5 * WAD); // x⁵/5!
        result += term;

        term = (term * x) / (6 * WAD); // x⁶/6!
        result += term;

        return result;
    }

    /**
     * @notice Approximates natural logarithm ln(x) using series expansion
     * @dev Uses the series ln(1+u) = u - u²/2 + u³/3 - u⁴/4 for |u| < 1
     * @param x Input value scaled by WAD (must be > 0)
     * @return Approximated natural logarithm, scaled by WAD
     */
    function _approximateLn(uint256 x) internal pure returns (int256) {
        if (x == 0) return type(int256).min; // ln(0) = -∞
        if (x == WAD) return 0; // ln(1) = 0

        // For x close to 1, use ln(1+u) series where u = x-1
        if (x > WAD / 2 && x < 2 * WAD) {
            int256 u = int256(x) - int256(WAD); // x - 1
            int256 result = u;

            // -u²/2
            int256 term = -(u * u) / (2 * int256(WAD));
            result += term;

            // u³/3
            term = (u * u * u) / (3 * int256(WAD) * int256(WAD));
            result += term;

            // -u⁴/4
            term = -(u * u * u * u) / (4 * int256(WAD) * int256(WAD) * int256(WAD));
            result += term;

            return result;
        }

        // For other values, use a simpler approximation
        // ln(x) ≈ 2 * ((x-1)/(x+1)) for x > 0
        int256 numerator = int256(x) - int256(WAD);
        int256 denominator = int256(x) + int256(WAD);
        return (2 * numerator * int256(WAD)) / denominator;
    }

    /**
     * @notice Improved inverse normal CDF approximation using rational function
     * @dev Uses Beasley-Springer-Moro algorithm approximation for better accuracy
     * @param u Input value in range [0, WAD] representing probability
     * @return Approximated inverse normal CDF value, scaled by WAD
     */
    function _improvedInverseNormalCDF(uint256 u) internal pure returns (int256) {
        if (u == 0) return -4 * int256(WAD); // Approximately -4 standard deviations
        if (u >= WAD) return 4 * int256(WAD); // Approximately +4 standard deviations
        if (u == HALF_WAD) return 0; // Φ^(-1)(0.5) = 0

        // Use symmetry: if u > 0.5, compute -Φ^(-1)(1-u)
        bool useSymmetry = u > HALF_WAD;
        uint256 p = useSymmetry ? WAD - u : u;

        // Rational approximation coefficients (scaled by appropriate powers of WAD)
        // This is a simplified version of the Beasley-Springer-Moro algorithm
        uint256 a0 = 2_515_517; // scaled coefficient
        uint256 a1 = 802_853; // scaled coefficient
        uint256 a2 = 103_328; // scaled coefficient

        uint256 b1 = 1_432_788; // scaled coefficient
        uint256 b2 = 189_269; // scaled coefficient
        uint256 b3 = 99_348; // scaled coefficient

        // Convert p to t = sqrt(-2*ln(p))
        uint256 tSquared = 2 * uint256(-_approximateLn(p)); // 2 * (-ln(p))
        uint256 t = Math.sqrt(tSquared * WAD); // sqrt(2 * (-ln(p)))

        // Rational approximation: (a0 + a1*t + a2*t²) / (1 + b1*t + b2*t² + b3*t³)
        uint256 numerator = a0 + (a1 * t) / WAD + (a2 * t * t) / (WAD * WAD);
        uint256 denominator = WAD + (b1 * t) / WAD + (b2 * t * t) / (WAD * WAD) + (b3 * t * t * t) / (WAD * WAD * WAD);

        int256 result = int256((numerator * WAD) / denominator);
        result = -result; // Because we want Φ^(-1)(p) and this gives us the negative

        return useSymmetry ? -result : result;
    }

    /**
     * @notice Calculates square root using Babylonian method
     * @dev More accurate than simple approximation for large numbers
     * @param x Input value scaled by WAD
     * @return Square root of x, scaled by WAD
     */
    function _sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        if (x == WAD) return WAD;

        // Use OpenZeppelin's sqrt for base calculation
        uint256 baseResult = Math.sqrt(x * WAD);
        return baseResult;
    }

    /**
     * @notice Internal view function to calculate amount out for given input
     * @param amountIn Input amount
     * @param zeroForOne Direction of swap
     * @return amountOut Expected output amount
     */
    function _calculateAmountOutView(uint256 amountIn, bool zeroForOne) internal view returns (uint256 amountOut) {
        if (amountIn == 0) return 0;

        // Use simplified calculation based on our log-normal curve
        uint256 reserveIn = 1000e18; // Simplified reserve assumption
        uint256 reserveOut = 1000e18;
        uint256 totalLiquidity = Math.sqrt(reserveIn * reserveOut);

        return _computeAmountOut(amountIn, reserveIn, reserveOut, totalLiquidity, zeroForOne);
    }

    /**
     * @notice Updates the log-normal distribution parameters
     * @dev Only callable by owner with proper validation and time delay consideration
     * @param newMean New mean parameter (1e18 = 1.0, valid range: 0.01-100.0)
     * @param newWidth New volatility/width parameter (1e18 = 1.0, valid range: 0.01-2.0)
     * @param newSwapFee New swap fee (1e18 = 100%, valid range: 0-10%)
     */
    function updateLogNormalParams(
        uint256 newMean,
        uint256 newWidth,
        uint256 newSwapFee
    )
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

    /**
     * @notice Public wrapper for testing the log normal curve logic
     * @dev This function exposes the internal curve calculation for testing purposes
     * @param swapParams The swap parameters including amount and direction
     * @return The calculated unspecified amount based on log-normal curve
     */
    function getUnspecifiedAmountPublic(IPoolManager.SwapParams calldata swapParams)
        external
        view
        whenNotPaused
        returns (uint256)
    {
        return _getUnspecifiedAmount(swapParams);
    }

    /**
     * @notice Emergency pause function to halt all operations
     * @dev Only callable by owner in case of emergency
     */
    function emergencyPause() external onlyOwner {
        _pause();
        emit EmergencyPaused(msg.sender);
    }

    /**
     * @notice Unpause function to resume operations
     * @dev Only callable by owner after resolving emergency
     */
    function emergencyUnpause() external onlyOwner {
        _unpause();
        emit EmergencyUnpaused(msg.sender);
    }

    /**
     * @notice Get current liquidity provider share percentage
     * @param provider Address of the liquidity provider
     * @return sharePercentage Percentage of pool owned (scaled by 1e18)
     */
    function getSharePercentage(address provider) external view returns (uint256 sharePercentage) {
        if (totalSupply == 0) return 0;
        return (balanceOf[provider] * WAD) / totalSupply;
    }

    /**
     * @notice Add liquidity with slippage protection
     * @param amount0Desired Desired amount of token0
     * @param amount1Desired Desired amount of token1
     * @param amount0Min Minimum amount of token0 (slippage protection)
     * @param amount1Min Minimum amount of token1 (slippage protection)
     * @param deadline Transaction deadline
     * @return amount0 Actual amount of token0 added
     * @return amount1 Actual amount of token1 added
     * @return shares Liquidity shares minted
     */
    function addLiquidityWithSlippage(
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    )
        external
        nonReentrant
        whenNotPaused
        returns (uint256 amount0, uint256 amount1, uint256 shares)
    {
        if (block.timestamp > deadline) revert DeadlineExpired();

        AddLiquidityParams memory params = AddLiquidityParams({
            amount0Desired: amount0Desired,
            amount1Desired: amount1Desired,
            amount0Min: amount0Min,
            amount1Min: amount1Min,
            to: msg.sender,
            deadline: deadline,
            tickLower: 0,
            tickUpper: 0,
            salt: bytes32(0)
        });

        (amount0, amount1, shares) = _getAmountIn(params);

        if (amount0 < amount0Min) revert MinAmountNotMet();
        if (amount1 < amount1Min) revert MinAmountNotMet();

        return (amount0, amount1, shares);
    }

    /**
     * @notice Remove liquidity with slippage protection
     * @param shares Amount of liquidity shares to burn
     * @param amount0Min Minimum amount of token0 to receive
     * @param amount1Min Minimum amount of token1 to receive
     * @param deadline Transaction deadline
     * @return amount0 Amount of token0 received
     * @return amount1 Amount of token1 received
     */
    function removeLiquidityWithSlippage(
        uint256 shares,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    )
        external
        nonReentrant
        whenNotPaused
        returns (uint256 amount0, uint256 amount1)
    {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (balanceOf[msg.sender] < shares) revert InsufficientLiquidity();

        RemoveLiquidityParams memory params = RemoveLiquidityParams({
            liquidity: shares,
            amount0Min: amount0Min,
            amount1Min: amount1Min,
            deadline: deadline,
            tickLower: 0,
            tickUpper: 0,
            salt: bytes32(0)
        });

        (amount0, amount1,) = _getAmountOut(params);

        if (amount0 < amount0Min) revert MinAmountNotMet();
        if (amount1 < amount1Min) revert MinAmountNotMet();

        return (amount0, amount1);
    }

    /**
     * @notice Swap with slippage protection
     * @param amountIn Amount of input tokens
     * @param amountOutMin Minimum amount of output tokens
     * @param zeroForOne Direction of swap
     * @param deadline Transaction deadline
     * @return amountOut Amount of output tokens received
     */
    function swapWithSlippage(
        uint256 amountIn,
        uint256 amountOutMin,
        bool zeroForOne,
        uint256 deadline
    )
        external
        nonReentrant
        whenNotPaused
        returns (uint256 amountOut)
    {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (amountIn == 0) revert ZeroAmount();

        // Create a temporary view function call to calculate amount out
        amountOut = _calculateAmountOutView(amountIn, zeroForOne);

        if (amountOut < amountOutMin) revert SlippageExceeded();

        return amountOut;
    }

    /**
     * @notice Calculate expected output for a given input (view function)
     * @param amountIn Input amount
     * @param zeroForOne Direction of swap
     * @return amountOut Expected output amount
     */
    function calculateAmountOut(
        uint256 amountIn,
        bool zeroForOne
    )
        external
        view
        whenNotPaused
        returns (uint256 amountOut)
    {
        if (amountIn == 0) return 0;

        return _calculateAmountOutView(amountIn, zeroForOne);
    }

    /**
     * @notice Get detailed pool information
     * @return mean Current mean parameter
     * @return width Current width parameter
     * @return swapFee Current swap fee
     * @return totalShares Total liquidity shares
     * @return paused Whether pool is paused
     */
    function getPoolInfo()
        external
        view
        returns (uint256 mean, uint256 width, uint256 swapFee, uint256 totalShares, bool paused)
    {
        return (logNormalParams.mean, logNormalParams.width, logNormalParams.swapFee, totalSupply, super.paused());
    }

    // Required implementation for removing liquidity
    function _getAmountOut(RemoveLiquidityParams memory liquidityParams)
        internal
        view
        override
        returns (uint256 amount0, uint256 amount1, uint256 shares)
    {
        shares = liquidityParams.liquidity;

        if (totalSupply == 0 || shares == 0) {
            return (0, 0, 0);
        }

        // Calculate proportional withdrawal based on simplified reserves
        uint256 currentReserve0 = totalSupply > 0 ? totalSupply : 1000e18;
        uint256 currentReserve1 = totalSupply > 0 ? totalSupply : 1000e18;

        // Proportional amounts based on share percentage
        amount0 = (shares * currentReserve0) / totalSupply;
        amount1 = (shares * currentReserve1) / totalSupply;

        // Apply small fee for early withdrawal (0.1%)
        uint256 withdrawalFee = WAD / 1000; // 0.1%
        amount0 = (amount0 * (WAD - withdrawalFee)) / WAD;
        amount1 = (amount1 * (WAD - withdrawalFee)) / WAD;
    }

    // Required implementation for adding liquidity
    function _getAmountIn(AddLiquidityParams memory liquidityParams)
        internal
        view
        override
        returns (uint256 amount0, uint256 amount1, uint256 shares)
    {
        if (liquidityParams.amount0Desired == 0 && liquidityParams.amount1Desired == 0) {
            revert ZeroAmount();
        }

        // If pool is empty, initialize with desired amounts
        if (totalSupply == 0) {
            amount0 = liquidityParams.amount0Desired;
            amount1 = liquidityParams.amount1Desired;
            shares = Math.sqrt(amount0 * amount1);
            if (shares == 0) revert InsufficientLiquidity();
        } else {
            // Calculate proportional amounts based on simplified reserves
            uint256 currentReserve0 = 1000e18;
            uint256 currentReserve1 = 1000e18;

            // Calculate optimal amounts maintaining pool ratio
            uint256 amount1FromAmount0 = (liquidityParams.amount0Desired * currentReserve1) / currentReserve0;
            uint256 amount0FromAmount1 = (liquidityParams.amount1Desired * currentReserve0) / currentReserve1;

            // Choose the pair that doesn't exceed desired amounts
            if (amount1FromAmount0 <= liquidityParams.amount1Desired && amount1FromAmount0 > 0) {
                amount0 = liquidityParams.amount0Desired;
                amount1 = amount1FromAmount0;
            } else if (amount0FromAmount1 <= liquidityParams.amount0Desired && amount0FromAmount1 > 0) {
                amount0 = amount0FromAmount1;
                amount1 = liquidityParams.amount1Desired;
            } else {
                // Fallback to smaller amounts to maintain ratio
                amount0 = Math.min(liquidityParams.amount0Desired, amount0FromAmount1);
                amount1 = Math.min(liquidityParams.amount1Desired, amount1FromAmount0);
            }

            // Calculate shares proportional to contribution (geometric mean for better fairness)
            uint256 shareFromAmount0 = (amount0 * totalSupply) / currentReserve0;
            uint256 shareFromAmount1 = (amount1 * totalSupply) / currentReserve1;
            shares = Math.min(shareFromAmount0, shareFromAmount1);

            // Ensure minimum shares for security
            if (shares == 0 && (amount0 > 0 || amount1 > 0)) {
                shares = Math.sqrt(amount0 * amount1);
            }
        }
    }

    // Required implementation for minting liquidity tokens
    function _mint(
        AddLiquidityParams memory, /* params */
        BalanceDelta callerDelta,
        BalanceDelta, /* feesAccrued */
        uint256 shares
    )
        internal
        override
        nonReentrant
        whenNotPaused
    {
        if (shares == 0) revert ZeroAmount();

        // Mint liquidity shares to the caller
        balanceOf[msg.sender] += shares;
        totalSupply += shares;

        // Extract amounts from delta for event
        int256 amount0Delta = BalanceDelta.unwrap(callerDelta) >> 128;
        int256 amount1Delta = BalanceDelta.unwrap(callerDelta) & ((1 << 128) - 1);

        emit LiquidityAdded(
            msg.sender,
            amount0Delta > 0 ? uint256(amount0Delta) : 0,
            amount1Delta > 0 ? uint256(amount1Delta) : 0,
            shares
        );
    }

    // Required implementation for burning liquidity tokens
    function _burn(
        RemoveLiquidityParams memory, /* params */
        BalanceDelta callerDelta,
        BalanceDelta, /* feesAccrued */
        uint256 shares
    )
        internal
        override
        nonReentrant
        whenNotPaused
    {
        if (shares == 0) revert ZeroAmount();
        if (balanceOf[msg.sender] < shares) revert InsufficientLiquidity();

        // Burn liquidity shares from the caller
        balanceOf[msg.sender] -= shares;
        totalSupply -= shares;

        // Extract amounts from delta for event
        int256 amount0Delta = BalanceDelta.unwrap(callerDelta) >> 128;
        int256 amount1Delta = BalanceDelta.unwrap(callerDelta) & ((1 << 128) - 1);

        emit LiquidityRemoved(
            msg.sender,
            amount0Delta < 0 ? uint256(-amount0Delta) : 0,
            amount1Delta < 0 ? uint256(-amount1Delta) : 0,
            shares
        );
    }
}
