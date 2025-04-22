# Numo

> ⚠️ **WARNING:** This code has not yet been audited. Use at your own risk.

[![Fuzz Testing](https://github.com/Uniswap/uniswap-v3-core/actions/workflows/fuzz-testing.yml/badge.svg)](https://github.com/numotrade/numo/actions/workflows/fuzz-testing.yml)
[![npm version](https://img.shields.io/npm/v/@uniswap/v3-core/latest.svg)](https://www.npmjs.com/package/@numotrade/numo/v/latest)

<div align="center">
  <br />
  <a href="https://optimism.io"><img alt="Numo" src="./image/numo_readme.png" width=600></a>
  <br />
</div>


<div align="center">
<p style="font-size: 1.3em;"><a href="https://numosend.com">Numo</a> enables global peer-to-peer payments.</p>
</div>

## Overview

Numo is a **dynamic, automated market maker** that provides liquidity to onchain FX markets for **instant cross-border payments**. Compared to the lastest Uniswap market maker, Numo's log-normal curve can offer more efficient exchange of foregin currencies and market make a variety of derivative products on them such as futures, forwards, and exotic option instruments without oracles.

The log-normal curve is implemented in  `_getUnspecifiedAmount` and formalized as:

$$ \varphi(x, y, L; \mu, \sigma) = \Phi^{-1} \left(\frac{x}{L} \right) + \Phi^{-1} \left(\frac{y}{\mu L} \right) + \sigma $$

where:
- $\Phi^{-1}$ is the **inverse** Gaussian cumulative distribution function (CDF).
- $L$ represents the total liquidity of the pool.
- $x$ and $y$ represent the reserves scaled by liquidity.
- $\mu$, the mean and $\sigma$, the width define the distribution of liquidity.

As liquidity $L$ increases, both reserves scale proportionally, maintaining a log-normal liquidity distribution.

## Architecture

Numo is a Uniswap V4 hook that inherits OpenZeppelin's `BaseCustomCurve` contract from their `uniswap-hooks` library. Thus enabling Numo to interact with the V4 `PoolManager` for optimal routing and inherit much of their battle tested code while using a custom curve. After a user initiates a swap,

**1. amountSpecified (input) -> swapFee applied -> amountAfterFee**
- Applies 0.01% fee to input amount

**2. Calculate amountOut using SwapLib**
- For zeroForOne: computeAmountOutGivenAmountInX()
- For oneForZero: computeAmountOutGivenAmountInY()
- Uses log-normal curve formula to determine output amount

**3. Validate amountOut**
- Ensure sufficient liquidity exists
- Check amountOut <= reserves

**4. Update reserves**
- For zeroForOne:
  - reserve0 += amountAfterFee  // Increase token0 reserves
  - reserve1 -= amountOut       // Decrease token1 reserves
- For oneForZero:
  - reserve1 += amountAfterFee  // Increase token1 reserves  
  - reserve0 -= amountOut       // Decrease token0 reserves

**5. Create BeforeSwapDelta**
- For zeroForOne:
  - delta = (amountAfterFee, -amountOut)
- For oneForZero:  
  - delta = (-amountOut, amountAfterFee)

**6. Return to PoolManager**
- Returns beforeSwap selector
- Returns BeforeSwapDelta
- Returns 0 for fee (fees handled internally)

#### Acknowledgements

The smart contract suite is inspired by Primitive's Log-Normal [DFMM](https://github.com/primitivefinance/dfmm) implementation and the [replicating market makers](https://arxiv.org/abs/2103.14769) paper that first showed the relationship between liquidity and the trading curve of an AMM.


## Setup

Requires forge to be installed already.

```
forge install
```

## Testing

```
forge test -vvv
```

## Coverage

```
forge coverage --report lcov
cmd + shift + p -> Coverage Gutters: Display Coverage
```

## Gas benchmarks

### View gas usage

```
forge snapshot --gas-report
```

### Compare gas usage
```
forge snapshot --diff
```

#### Update dependencies

```bash
git submodule update --init --recursive
```

## Deployments

| Network  | Factory Address                                       |  
| -------- | ----------------------------------------------------- | 
| Base     | [0x82360b9a2076a09ea8abe2b3e11aed89de3a02d1](https://explorer.celo.org/mainnet/token/0x82360b9a2076a09ea8abe2b3e11aed89de3a02d1 ) |

---

