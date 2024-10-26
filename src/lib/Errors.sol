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
/// @dev Thrown when a swap does not mint sufficient SY tokens given the minimum amount.
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
/// @dev Thrown when a token passed to `mintSY` is not valid
error InvalidTokenIn(address tokenIn);
/// @dev Thrown when an external call is made within the same frame as another.
error Reentrancy();

error MaturityReached();

error ToIntOverflow();
error ToUintOverflow();