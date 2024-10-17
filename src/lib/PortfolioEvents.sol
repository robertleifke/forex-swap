// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.13;

/// @dev Emitted on pool creation.
event Init(
    address caller,
    address indexed tokenX,
    address indexed tokenY,
    uint256 reserveX,
    uint256 reserveY,
    uint256 totalLiquidity,
    uint256 strike,
    uint256 sigma,
    uint256 fee,
    uint256 maturity
);

/// @dev Emitted on swaps.
event Swap(
    address caller,
    address indexed to,
    address indexed tokenIn,
    address indexed tokenOut,
    uint256 amountIn,
    uint256 amountOut,
    int256 deltaLiquidity
);

/// @dev Emitted on allocatess.
event Allocate(address indexed caller, address indexed to, uint256 deltaX, uint256 deltaY, uint256 deltaLiquidity);

/// @dev Emitted on deallocates.
event Deallocate(address indexed caller, address indexed to, uint256 deltaX, uint256 deltaY, uint256 deltaLiquidity);