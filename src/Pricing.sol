// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

/// @title Functions for options pricing and calculations.
/// @notice This library contains functions for options pricing and calculations.
/// @dev All of the functions in this library are taken directly from RMMLib authored by Primitive.
///      Source: https://github.com/primitivefinance/rmm/blob/main/contracts/libraries/RMMLib.sol

import {Gaussian} from "solstat/Gaussian.sol";
import {FixedPointMathLib} from "lib/solstat/lib/solmate/src/utils/FixedPointMathLib.sol";
import {ERC20} from "lib/solmate/src/tokens/ERC20.sol";
import {ToUintOverflow, ToIntOverflow} from "./lib/Errors.sol";

using FixedPointMathLib for uint256;
using FixedPointMathLib for int256;


struct PoolPreCompute {
    uint256 reserveInAsset;
    uint256 strike_;
    uint256 tau_;
}

function computeLnSDivK(uint256 S, uint256 strike_) pure returns (int256) {
    return int256(S.divWadDown(strike_)).lnWad();
}

/// @dev Computes σ√τ given `sigma_` σ and `tau` τ.
function computeSigmaSqrtTau(uint256 sigma_, uint256 tau_) pure returns (uint256) {
    uint256 sqrtTau = FixedPointMathLib.sqrt(tau_) * 1e9; // 1e9 is the precision of the square root function
    return sigma_.mulWadUp(sqrtTau);
}

/// @dev Converts seconds (units of block.timestamp) into years in WAD units.
function computeTauWadYears(uint256 tauSeconds) pure returns (uint256) {
    return tauSeconds.mulDivDown(1e18, 365 days);
}

/// @dev k = Φ⁻¹(x/L) + Φ⁻¹(y/μL)  + σ√τ
function computeTradingFunction(
    uint256 base,
    uint256 quote,
    uint256 liquidity,
    uint256 strike_,
    uint256 sigma_,
    uint256 tau_
) pure returns (int256) {
    uint256 a_i = base * 1e18 / liquidity;
    uint256 b_i = quote * 1e36 / (strike_ * liquidity);

    int256 a = Gaussian.ppf(toInt(a_i));
    int256 b = Gaussian.ppf(toInt(b_i));
    int256 c = tau_ != 0 ? toInt(computeSigmaSqrtTau(sigma_, tau_)) : int256(0);
    return a + b + c;
}

/// @dev price(x) = μe^(Φ^-1(1 - x/L)σ√τ - 1/2σ^2τ)
/// @notice
/// * As lim_x->0, price(x) = +infinity for all `τ` > 0 and `σ` > 0.
/// * As lim_x->1, price(x) = 0 for all `τ` > 0 and `σ` > 0.
/// * If `τ` or `σ` is zero, price is equal to strike.
function computeSpotPrice(
    uint256 base,
    uint256 totalLiquidity_,
    uint256 strike_,
    uint256 sigma_,
    uint256 tau_
) pure returns (uint256) {
    int256 a = Gaussian.ppf(int256(1 ether - base.divWadDown(totalLiquidity_)));
    int256 b = toInt(computeSigmaSqrtTau(sigma_, tau_));
    int256 c = toInt(0.5 ether * sigma_ * sigma_ * tau_ / (1e18 ** 3));
    int256 exp = (a * b / 1 ether - c).expWad();
    return strike_.mulWadUp(uint256(exp));
}

/// @dev ~y = LKΦ(Φ⁻¹(1-x/L) - σ√τ)
function computeY(uint256 base, uint256 liquidity, uint256 strike_, uint256 sigma_, uint256 tau_)
    pure
    returns (uint256)
{
    int256 a = Gaussian.ppf(toInt(1 ether - base.divWadDown(liquidity)));
    int256 b = tau_ != 0 ? toInt(computeSigmaSqrtTau(sigma_, tau_)) : int256(0);
    int256 c = Gaussian.cdf(a - b);

    return liquidity * strike_ * toUint(c) / (1e18 ** 2);
}

/// @dev ~x = L(1 - Φ(Φ⁻¹(y/(LK)) + σ√τ))
function computeX(uint256 quote, uint256 liquidity, uint256 strike_, uint256 sigma_, uint256 tau_)
    pure
    returns (uint256)
{
    int256 a = Gaussian.ppf(toInt(quote * 1e36 / (liquidity * strike_)));
    int256 b = tau_ != 0 ? toInt(computeSigmaSqrtTau(sigma_, tau_)) : int256(0);
    int256 c = Gaussian.cdf(a + b);

    return liquidity * (1 ether - toUint(c)) / 1e18;
}

/// @dev ~L = x / (1 - Φ(Φ⁻¹(y/(LK)) + σ√τ))
function computeL(uint256 base, uint256 liquidity, uint256 sigma_, uint256 prevTau, uint256 newTau)
    pure
    returns (uint256)
{
    int256 a = Gaussian.ppf(toInt(base * 1 ether / liquidity));
    int256 c = Gaussian.cdf(
        (
            (a * toInt(computeSigmaSqrtTau(sigma_, prevTau)) / 1 ether)
                + toInt(sigma_ * sigma_ * prevTau / (2 ether * 1 ether))
                + toInt(sigma_ * sigma_ * newTau / (2 ether * 1 ether))
        ) * 1 ether / toInt(computeSigmaSqrtTau(sigma_, newTau))
    );

    return base * 1 ether / toUint(1 ether - c);
}

function computeLGivenYK(
    uint256 base,
    uint256 quote,
    uint256 liquidity,
    uint256 strike_,
    uint256 sigma_,
    uint256 newTau
) pure returns (uint256) {
    int256 a = Gaussian.ppf(toInt(quote * 1e36 / (liquidity * strike_)));
    int256 b = newTau != 0 ? toInt(computeSigmaSqrtTau(sigma_, newTau)) : int256(0);
    int256 c = Gaussian.cdf(a + b);

    return base * 1 ether / toUint(1 ether - c);
}

function computeLGivenX(uint256 base, uint256 S, uint256 strike_, uint256 sigma_, uint256 tau_)
    pure
    returns (uint256)
{
    int256 lnSDivK = computeLnSDivK(S, strike_);
    uint256 sigmaSqrtTau = computeSigmaSqrtTau(sigma_, tau_);
    uint256 halfSigmaSquaredTau = sigma_.mulWadDown(sigma_).mulWadDown(0.5 ether).mulWadDown(tau_);
    int256 d1 = 1 ether * (lnSDivK + int256(halfSigmaSquaredTau)) / int256(sigmaSqrtTau);
    uint256 cdf = uint256(Gaussian.cdf(d1));

    return base * 1 ether / (1 ether - cdf);
}

/// @dev x is independent variable, y and L are dependent variables.
function findX(bytes memory data, uint256 x) pure returns (int256) {
    (uint256 quote, uint256 liquidity, uint256 strike_, uint256 sigma_, uint256 tau_) =
        abi.decode(data, (uint256, uint256, uint256, uint256, uint256));

    return computeTradingFunction(x, quote, liquidity, strike_, sigma_, tau_);
}

/// @dev y is independent variable, x and L are dependent variables.
function findY(bytes memory data, uint256 y) pure returns (int256) {
    (uint256 base, uint256 liquidity, uint256 strike_, uint256 sigma_, uint256 tau_) =
        abi.decode(data, (uint256, uint256, uint256, uint256, uint256));

    return computeTradingFunction(base, y, liquidity, strike_, sigma_, tau_);
}

/// @dev L is independent variable, x and y are dependent variables.
function findL(bytes memory data, uint256 liquidity) pure returns (int256) {
    (uint256 base, uint256 quote, uint256 strike_, uint256 sigma_, uint256 tau_) =
        abi.decode(data, (uint256, uint256, uint256, uint256, uint256));

    return computeTradingFunction(base, quote, liquidity, strike_, sigma_, tau_);
}

/// todo: figure out what happens when result of trading function is negative or positive.
function solveX(uint256 quote, uint256 liquidity, uint256 strike_, uint256 sigma_, uint256 tau_)
    pure
    returns (uint256 base_)
{
    bytes memory args = abi.encode(quote, liquidity, strike_, sigma_, tau_);
    uint256 initialGuess = computeX(quote, liquidity, strike_, sigma_, tau_);
    // at maturity the `initialGuess` will == L therefore we must reduce it by 1 wei
    base_ = findRootNewX(args, tau_ != 0 ? initialGuess : initialGuess - 1, 20, 10);
}

function solveY(uint256 base, uint256 liquidity, uint256 strike_, uint256 sigma_, uint256 tau_)
    pure
    returns (uint256 quote_)
{
    bytes memory args = abi.encode(base, liquidity, strike_, sigma_, tau_);
    uint256 initialGuess = computeY(base, liquidity, strike_, sigma_, tau_);
    // at maturity the `initialGuess` will == LK (K == WAD, K*L == L) therefore we must reduce it by 1 wei
    quote_ = findRootNewY(args, tau_ != 0 ? initialGuess : initialGuess - 1, 20, 10);
}

function solveL(PoolPreCompute memory comp, uint256 initialLiquidity, uint256 quote, uint256 sigma_)
    pure
    returns (uint256 liquidity_)
{
    bytes memory args = abi.encode(comp.reserveInAsset, quote, comp.strike_, sigma_, comp.tau_);
    uint256 initialGuess =
        computeLGivenYK(comp.reserveInAsset, quote, initialLiquidity, comp.strike_, sigma_, comp.tau_);
    liquidity_ = findRootNewLiquidity(args, initialGuess, 20, 10);
}

function computeDeltaLXIn(
    uint256 amountIn,
    uint256 base,
    uint256 quote,
    uint256 totalLiquidity,
    uint256 exerciseFee,
    uint256 strike,
    uint256 sigma,
    uint256 tau
) pure returns (uint256 deltaL) {
    uint256 fees = exerciseFee.mulWadUp(amountIn);
    uint256 px = computeSpotPrice(base, totalLiquidity, strike, sigma, tau);
    deltaL = px.mulWadUp(totalLiquidity).mulWadUp(fees).divWadDown(px.mulWadDown(base) + quote);
}

function computeDeltaLYOut(
    uint256 amountOut,
    uint256 base,
    uint256 quote,
    uint256 totalLiquidity,
    uint256 exerciseFee,
    uint256 strike,
    uint256 sigma,
    uint256 tau
) pure returns (uint256 deltaL) {
    uint256 fees = exerciseFee.mulWadUp(amountOut);
    uint256 px = computeSpotPrice(base, totalLiquidity, strike, sigma, tau);
    deltaL = px.mulWadUp(totalLiquidity).mulWadUp(fees).divWadDown(px.mulWadDown(base) + quote);
}

function computeDeltaLYIn(
    uint256 amountIn,
    uint256 base,
    uint256 quote,
    uint256 totalLiquidity,
    uint256 exerciseFee,
    uint256 strike,
    uint256 sigma,
    uint256 tau
) pure returns (uint256 deltaL) {
    uint256 fees = exerciseFee.mulWadUp(amountIn);
    uint256 px = computeSpotPrice(base, totalLiquidity, strike, sigma, tau);
    deltaL = totalLiquidity.mulWadUp(fees).divWadDown(px.mulWadDown(base) + quote);
}

function findRootNewLiquidity(bytes memory args, uint256 initialGuess, uint256 maxIterations, uint256 tolerance)
    pure
    returns (uint256 L)
{
    L = initialGuess;
    int256 L_next;
    int256 toleranceInt = int256(tolerance);
    for (uint256 i = 0; i < maxIterations; i++) {
        int256 dfx = computeTfDL(args, L);
        int256 fx = findL(args, L);

        if (dfx == 0) {
            // Handle division by zero
            break;
        }
        L_next = int256(L) - (fx * 1e18) / dfx;

        int256 diff = int256(L) - L_next;
        if (diff <= toleranceInt && diff >= -toleranceInt || fx <= toleranceInt && fx >= -toleranceInt) {
            L = uint256(L_next);
            break;
        }

        L = uint256(L_next);
    }
}

function findRootNewX(bytes memory args, uint256 initialGuess, uint256 maxIterations, uint256 tolerance)
    pure
    returns (uint256 base_)
{
    base_ = initialGuess;
    int256 base_next;
    for (uint256 i = 0; i < maxIterations; i++) {
        int256 dfx = computeTfDReserveX(args, base_);
        int256 fx = findX(args, base_);

        if (dfx == 0) {
            // Handle division by zero
            break;
        }

        base_next = int256(base_) - fx * 1e18 / dfx;

        if (abs(int256(base_) - base_next) <= int256(tolerance) || abs(fx) <= int256(tolerance)) {
            base_ = uint256(base_next);
            break;
        }

        base_ = uint256(base_next);
    }
}

function findRootNewY(bytes memory args, uint256 initialGuess, uint256 maxIterations, uint256 tolerance)
    pure
    returns (uint256 quote_)
{
    quote_ = initialGuess;
    int256 quote_next;
    for (uint256 i = 0; i < maxIterations; i++) {
        int256 fx = findY(args, quote_);
        int256 dfx = computeTfDReserveY(args, quote_);

        if (dfx == 0) {
            // Handle division by zero
            break;
        }

        quote_next = int256(quote_) - fx * 1e18 / dfx;

        if (abs(int256(quote_) - quote_next) <= int256(tolerance) || abs(fx) <= int256(tolerance)) {
            quote_ = uint256(quote_next);
            break;
        }

        quote_ = uint256(quote_next);
    }
}

function computeTfDL(bytes memory args, uint256 L) pure returns (int256) {
    (uint256 base, uint256 quote, uint256 K,,) = abi.decode(args, (uint256, uint256, uint256, uint256, uint256));
    int256 x = int256(base);
    int256 y = int256(quote);
    int256 mu = int256(K);
    int256 L_squared = int256(L.mulWadDown(L));

    int256 a = Gaussian.ppf(int256(base.divWadUp(L)));
    int256 b = Gaussian.ppf(int256(quote.divWadUp(L.mulWadUp(K))));

    int256 pdf_a = Gaussian.pdf(a);
    int256 pdf_b = Gaussian.pdf(b);

    int256 term1 = x * 1 ether / (int256(L_squared) * (pdf_a) / 1 ether);

    int256 term2a = mu * int256(L_squared) / 1 ether;
    int256 term2b = term2a * pdf_b / 1 ether;
    int256 term2 = y * 1 ether / term2b;

    return -term1 - term2;
}

function computeTfDReserveX(bytes memory args, uint256 base) pure returns (int256) {
    (, uint256 L,,,) = abi.decode(args, (uint256, uint256, uint256, uint256, uint256));
    int256 a = Gaussian.ppf(toInt(base * 1e18 / L));
    int256 pdf_a = Gaussian.pdf(a);
    int256 result = 1e36 / (int256(L) * pdf_a / 1e18);
    return result;
}

function computeTfDReserveY(bytes memory args, uint256 quote) pure returns (int256) {
    (, uint256 L, uint256 K,,) = abi.decode(args, (uint256, uint256, uint256, uint256, uint256));
    int256 KL = int256(K * L / 1e18);
    int256 a = Gaussian.ppf(int256(quote) * 1e18 / KL);
    int256 pdf_a = Gaussian.pdf(a);
    int256 result = 1e36 / (KL * pdf_a / 1e18);
    return result;
}

function calcMaxPtIn(
    uint256 base,
    uint256 quote,
    uint256 totalLiquidity_,
    uint256 strike_
) pure returns (uint256) {
    uint256 low = 0;
    uint256 high = quote - 1;

    while (low != high) {
        uint256 mid = (low + high + 1) / 2;
        if (calcSlope(base, quote, totalLiquidity_, strike_, int256(mid)) < 0) {
            high = mid - 1;
        } else {
            low = mid;
        }
    }

    return low;
}

function calcSlope(
    uint256 base,
    uint256 quote,
    uint256 totalLiquidity_,
    uint256 strike_,
    int256 ptToMarket
) pure returns (int256) {
    uint256 newQuote = quote + uint256(ptToMarket);
    uint256 b_i = newQuote * 1e36 / (strike_ * totalLiquidity_);

    if (b_i > 1e18) {
        return -1;
    }
    
    int256 b = Gaussian.ppf(toInt(b_i));
    int256 pdf_b = Gaussian.pdf(b);
    
    int256 slope = (int256(strike_ * totalLiquidity_) * pdf_b / 1e36);
    
    int256 dxdy = computedBaseQuote(base, newQuote);
    
    return slope + dxdy;
}

function calcMaxPtOut(
    uint256 base,
    uint256 quote,
    uint256 totalLiquidity_,
    uint256 strike_,
    uint256 sigma_,
    uint256 tau_
) pure returns (uint256) {
    int256 currentTF = computeTradingFunction(base, quote, totalLiquidity_, strike_, sigma_, tau_);
    
    uint256 maxProportion = uint256(int256(1e18) - currentTF) * 1e18 / (2 * 1e18);
    
    uint256 maxPtOut = quote * maxProportion / 1e18;
    
    return (maxPtOut * 999) / 1000;
}

function computedBaseQuote(
    uint256 base,
    uint256 quote
) pure returns (int256) {
    return -int256(base) * 1e18 / int256(quote);
}

/// @dev Casts an unsigned integer to a signed integer, reverting if `x` is too large.
function toInt(uint256 x) pure returns (int256) {
    // Safe cast below because `type(int256).max` is positive.
    if (x <= uint256(type(int256).max)) {
        return int256(x);
    } else {
        revert ToIntOverflow();
    }
}

/// @dev Sums an unsigned integer with a signed integer, reverting if the result overflows.
function sum(uint256 a, int256 b) pure returns (uint256) {
    if (b < 0) {
        if (a >= uint256(-b)) {
            return a - uint256(-b);
        } else {
            revert ToUintOverflow();
        }
    } else {
        if (a + uint256(b) >= a) {
            return a + uint256(b);
        } else {
            revert ToUintOverflow();
        }
    }
}

/// @dev Converts native decimal amount to WAD amount, rounding down.
function upscale(uint256 amount, uint256 scalingFactor) pure returns (uint256) {
    return FixedPointMathLib.mulWadDown(amount, scalingFactor);
}

/// @dev Converts a WAD amount to a native DECIMAL amount, rounding down.
function downscaleDown(uint256 amount, uint256 scalar_) pure returns (uint256) {
    return FixedPointMathLib.divWadDown(amount, scalar_);
}

/// @dev Converts a WAD amount to a native DECIMAL amount, rounding up.
function downscaleUp(uint256 amount, uint256 scalar_) pure returns (uint256) {
    return FixedPointMathLib.divWadUp(amount, scalar_);
}

/// @dev Casts a positived signed integer to an unsigned integer, reverting if `x` is negative.
function toUint(int256 x) pure returns (uint256) {
    if (x < 0) {
        revert ToUintOverflow();
    }
    return uint256(x);
}

function abs(int256 x) pure returns (int256) {
    if (x < 0) {
        return -x;
    } else {
        return x;
    }
}

/// @dev Computes the scalar to multiply to convert between WAD and native units.
function scalar(address token) view returns (uint256) {
    uint256 decimals = ERC20(token).decimals();
    uint256 difference = 18 - decimals;
    return FixedPointMathLib.WAD * 10 ** difference;
}

function isASmallerApproxB(uint256 a, uint256 b, uint256 eps) pure returns (bool) {
    return a <= b && a >= b.mulWadDown(1e18 - eps);
}


