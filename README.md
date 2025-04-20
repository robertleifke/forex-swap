# Numo

> ⚠️ **WARNING:** This code has not yet been audited. Use at your own risk.

[![Fuzz Testing](https://github.com/Uniswap/uniswap-v3-core/actions/workflows/fuzz-testing.yml/badge.svg)](https://github.com/numotrade/numo/actions/workflows/fuzz-testing.yml)
[![npm version](https://img.shields.io/npm/v/@uniswap/v3-core/latest.svg)](https://www.npmjs.com/package/@numotrade/numo/v/latest)

<div align="center">
  <br />
  <a href="https://optimism.io"><img alt="Numo" src="./image/numo_readme.png" width=600></a>
  <br />
</div>

## Overview

Numo is a dynamic, automated market maker that provides continuous liquidity to onchain FX markets. Numo's specialized curve can offer more efficient exchange of FX and market make a variety of derivative products such as futures, forwards, and exotic option instruments without oracles.

Try it out at [numosend.com](numosend.com)! Send money from one currency to another at the best rates  without waiting or amount limits. 

### Advantages 

- ✅ Any FX pair
- 🌍 Globally accessible
- 🤝 Instant settlement

## Architecture

Numo is a Uniswap V4 hook that inherits OpenZeppelin's `BaseCustomCurve` contract from their `uniswap-hooks` library. Thus enabling Numo to interact with the V4 poolmanager for optimal routing and inherit much of their battle tested code without needing use the concentrated liquidity logic. 

#### Log-Normal Market Maker

A log-normal curve is beter suited for FX over hyperbolic curves implemented by Uniswap as FX exchange rates exhbit log-normal behavior. Instead of overriding `beforeSwap` completey, Numo uses  `_getUnspecifiedAmount` to implement the curve defined as:

$$ \varphi(x, y, L; \mu, \sigma) = \Phi^{-1} \left(\frac{x}{L} \right) + \Phi^{-1} \left(\frac{y}{\mu L} \right) + \sigma $$

where:
- $\Phi^{-1}$ is the **inverse** Gaussian cumulative distribution function (CDF).
- $L$ represents the total liquidity of the pool.
- $x$ and $y$ represent the reserves scaled by liquidity.
- $\mu$, the mean and $\sigma$, the width define the distribution of liquidity.

As liquidity $L$ increases, both reserves scale proportionally, maintaining a log-normal liquidity distribution.

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

