// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library MarketUtils {
    uint256 public constant POOL_PRECISION_DECIMALS = 18;
    uint256 public constant MAX_SWAP_FEE = 1e17; // 10%
    uint256 public constant MAX_ADMIN_FEE = 1e17; // 10%
} 