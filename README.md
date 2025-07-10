# Numo

[gitpod]: https://gitpod.io/#https://github.com/robertleifke/numo2
[gitpod-badge]: https://img.shields.io/badge/Gitpod-Open%20in%20Gitpod-FFB45B?logo=gitpod
[gha]: https://github.com/robertleifke/numo2/actions
[gha-badge]: https://github.com/robertleifke/numo2/actions/workflows/ci.yml/badge.svg
[foundry]: https://getfoundry.sh/
[foundry-badge]: https://img.shields.io/badge/Built%20with-Foundry-FFDB1C.svg
[license]: https://opensource.org/licenses/MIT
[license-badge]: https://img.shields.io/badge/License-MIT-blue.svg

> ⚠️ **WARNING:** This code has not yet been audited. Use at your own risk.

<div align="center">
  <br />
  <a href="https://optimism.io"><img alt="Numo" src="./image/numo_readme.png" width=600></a>
  <br />
</div>

<div align="center">
<p style="font-size: 1.3em;"><a href="https://numosend.com">Numo</a> enables anyone to hedge currency risk.</p>
</div>

## Overview

Numo is an automated system for portfolio replication to boostrap liquidity for derivatives on foreign exchange, specifically, letting users lock in FX rates using a fully collateralized, onchain instrument with no banks, no counterparties, and no credit risk.

## Quick Start

Clone and set up the project:

```sh
$ git clone https://github.com/robertleifke/numo
$ cd numo
$ bun install
$ forge build
```

## 🔧 Architecture

### Core Components

1. **BaseCustomCurve Integration**: Extends Uniswap V4's custom curve framework
2. **Numo State Management**: Tracks invariant k, total liquidity L, and reserves
3. **Mathematical Engine**: Implements inverse normal CDF and iterative solving
4. **Liquidity Management**: Handles minting/burning with proper ratio maintenance
5. **Swap Execution**: Both exact input/output swaps with Numo pricing

### Mathematical Implementation

```solidity
// Core Numo invariant
invariantK = inverseNormalCDF(x/L) + inverseNormalCDF(y/L)

// Configurable parameters
struct NumoParams {
    uint256 mu;      // Mean of log-normal distribution (default: 1.0)
    uint256 sigma;   // Standard deviation/volatility (default: 0.2)
    uint256 swapFee; // Swap fee percentage (default: 0.3%)
}
```

Deploy the Numo market maker:

```solidity
// Deploy to your Uniswap V4 pool
IPoolManager poolManager = // ... your pool manager
Numo numoHook = new Numo(poolManager);

// Initialize with pool key
PoolKey memory poolKey = PoolKey({
    currency0: Currency.wrap(address(token0)),
    currency1: Currency.wrap(address(token1)),
    fee: 0,
    tickSpacing: 0,
    hooks: IHooks(address(numoHook))
});
numoHook.initializePool(poolKey);

// Configure Numo parameters
numoHook.updateNumoParams(
    1.1e18,  // mu = 1.1 (10% mean premium)
    2.5e17,  // sigma = 0.25 (25% volatility)
    5e15     // swapFee = 0.5%
);
```

## Core Functions

### Liquidity Management

```solidity
// Add liquidity with slippage protection
function addLiquidity(
    uint256 amount0Desired,
    uint256 amount1Desired,
    uint256 amount0Min,
    uint256 amount1Min,
    address to,
    uint256 deadline
) external returns (uint256 shares);

// Remove liquidity
function removeLiquidity(
    uint256 shares,
    uint256 amount0Min,
    uint256 amount1Min,
    address to,
    uint256 deadline
) external returns (uint256 amount0, uint256 amount1);
```

### Trading Interface

```solidity
// Execute swaps with Numo pricing
function swap(
    uint256 amountIn,
    uint256 amountOutMin,
    bool zeroForOne,
    address to,
    uint256 deadline
) external returns (uint256 amountOut);

// Get quote for swap
function getAmountOut(uint256 amountIn, bool zeroForOne)
    external view returns (uint256 amountOut);
```

### State Monitoring

```solidity
// Get current Numo state
function getNumoState() external view returns (
    int256 currentK,           // Current invariant value
    uint256 currentLiquidity,  // Total liquidity L
    uint256 reserve0,          // Currency0 reserves
    uint256 reserve1,          // Currency1 reserves
    uint256 mu,               // Mean parameter
    uint256 sigma,            // Volatility parameter
    uint256 swapFee           // Swap fee
);
```

## 🧪 Testing

Run comprehensive tests for the Numo implementation:

```sh
# Run all tests
$ forge test

# Run with detailed output
$ forge test -vvv

# Run gas reporting
$ forge test --gas-report

# Run specific Numo tests
$ forge test --match-contract Numo -vv
```

Key test scenarios:

- Invariant preservation across swaps
- Liquidity addition/removal mechanics
- Mathematical precision of inverse normal CDF
- Edge case handling and error conditions
- Gas optimization verification

## Mathematical Details

### Inverse Normal CDF Implementation

Numo uses the Beasley-Springer-Moro algorithm for computing Φ⁻¹(u):

```solidity
function _improvedInverseNormalCDF(uint256 u) internal pure returns (int256) {
    // Handles edge cases and symmetry
    // Uses rational approximation for high precision
    // Bounded to [-6σ, +6σ] for numerical stability
}
```

### Newton-Raphson Iteration

For swap calculations, Numo employs iterative solving:

```solidity
function _solveExactInputNumoWithLiquidity(...) internal view returns (...) {
    // Initial guess using constant product
    // Newton-Raphson iteration to solve: Φ⁻¹(x'/L) + Φ⁻¹(y'/L) = k
    // Convergence threshold: 1e-6 in WAD precision
    // Maximum iterations: 50
}
```

### Fallback Mechanisms

When iterative solving fails, Numo provides robust fallbacks:

```solidity
function _calculateLogNormalAdjustment(uint256 currentPrice) internal view returns (uint256) {
    // Adjusts constant product formula using log-normal principles
    // Based on deviation from mean (μ) and volatility (σ)
    // Provides smooth price curves even in extreme conditions
}
```

## Parameters

### Curve Parameters

- **mu (μ)**: Mean of log-normal distribution (default: 1.0 = no bias)
- **sigma (σ)**: Volatility parameter (default: 0.2 = 20% volatility)
- **swapFee**: Trading fee percentage (default: 0.3%, max: 10%)

### Safety Bounds

- **Convergence Threshold**: 1e-6 for numerical precision
- **Maximum Iterations**: 50 for gas efficiency
- **CDF Bounds**: [-6σ, +6σ] for mathematical stability
- **Minimum Liquidity**: 1000 wei to prevent edge cases

## Commands

### Build

```sh
$ forge build
```

### Testing

```sh
# All tests
$ forge test

# Coverage report
$ forge coverage

# Gas report
$ forge test --gas-report
```

### Deployment

```sh
# Deploy to Anvil
$ forge script script/Deploy.s.sol --broadcast --fork-url http://localhost:8545

# Deploy to testnet (requires MNEMONIC env var)
$ forge script script/Deploy.s.sol --broadcast --fork-url $TESTNET_RPC_URL
```

### Code Quality

```sh
# Format contracts
$ forge fmt

# Lint contracts
$ bun run lint

# Test coverage with HTML report
$ bun run test:coverage:report
```

## Related Projects

- **[Primitive Finance DFMM](https://github.com/primitivefinance/DFMM)** - Original LogNormal AMM inspiration
- **[Uniswap V4 Core](https://github.com/Uniswap/v4-core)** - Next-generation AMM protocol
- **[Uniswap V4 Hooks](https://github.com/Uniswap/v4-periphery)** - Hook development framework
- **[BaseCustomCurve](https://github.com/uniswap-hooks/base-custom-curve)** - Custom curve base implementation

## Mathematical Background

### Research Papers

- **[DFMM: Log-Normal Market Maker](https://github.com/primitivefinance/DFMM/blob/main/src/LogNormal/README.md)** - Log
  Normal Market Maker from DFMM protocol
- **[Replicating Market Makers](https://arxiv.org/pdf/2103.14769v1.pdf)** - Replicating Portfolios with CFMMs
- **[Log-Normal Distribution Properties](https://en.wikipedia.org/wiki/Log-normal_distribution)** - Statistical modeling
  basis

## AUDITORS: Security Considerations

### Implemented Protections

- **Reentrancy Guards**: All external functions protected
- **Slippage Protection**: Minimum amount checks on all trades
- **Deadline Enforcement**: Time-bound transaction execution
- **Emergency Pause**: Owner can halt operations if needed
- **Input Validation**: Comprehensive parameter checking
- **Numerical Stability**: Bounded calculations with overflow protection

## 📄 License

This project is licensed under MIT - see the [LICENSE](LICENSE) file for details.

---
