# Numo

> ⚠️ **WARNING:** This code has not yet been audited. Use at your own risk.

[![Fuzz Testing](https://github.com/Uniswap/uniswap-v3-core/actions/workflows/fuzz-testing.yml/badge.svg)](https://github.com/numotrade/numo/actions/workflows/fuzz-testing.yml)
[![npm version](https://img.shields.io/npm/v/@uniswap/v3-core/latest.svg)](https://www.npmjs.com/package/@numotrade/numo/v/latest)

<div align="center">
  <br />
  <a href="https://optimism.io"><img alt="Numo" src="./image/numo_readme.png" width=600></a>
  <br />
</div>

#### Automated market maker for FX derivatives on the EVM.

## Overview

Automated market makers (AMM) can quickly bootstrap liquidity on any market without external prices. Numo, a specialized AMM is designed to do just that for a host of hedging products such as futures, forwards, and exotic option instruments. A useful application of Numo is hedging FX risk on long-tail currencies where Numo uses option premiums to peg a FX pair to a desired exchange rate (e.g. USD/EUR 1:1.2). Unlocking savings for cross-border lending, payments, and exchange.

### Advantages 

- ✅ Any derivative exposure
- 🌍 Globally accessible
- 🤝 No reliance on counterparties
- 🛠️ Customizability 

## Architecture

Numo is a Uniswap V4 hook that inherits OpenZeppelin's `BaseCustomCurve` contract from their `uniswap-hooks` library. Thus enabling Numo to interact with the V4 poolmanager for optimal routing and inherit much of their battle tested code without needing use the concentrated liquidity logic. Instead of calling `beforeSwap` directly, Numo.sol implements its custom curve in `_getUnspecifiedAmount` to support the replication of derivatives. Each call and put is repersented as a `ERC-6909` token. 

#### Trading curve

The trading curve in Numo determines the price and behavior of the AMM. Unlike a traditional AMM like in Uniswap V2, Numo implements a log-normal curve to adjust prices dynamically based on volatility (σ), strike (K), and time to maturity (τ). It allows users to swap assets at implied vol-adjusted prices, mimicking an options market.***The formula***:

<img src="./image/formula.png" alt="Formula" width="300"/>

Implemented in `computeTradingFunction(...)` with the following parameters:

- Reserve balances `reserveX`, `reserveY`
- Liquidity `totalLiquidity`
- Strike price `strike`
- Implied volatility `sigma`
- Time to maturity `tau`

#### Acknowledgements

The smart contract suite is inspired by Primitive's [RMM](https://github.com/primitivefinance/rmm) implementation and the [replicating market makers](https://arxiv.org/abs/2103.14769) paper that first proved that any synethic derivative expsoure can be constructed using AMMs without needing a liquid options market. 


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
| Unichain Sepolia     | [0x82360b9a2076a09ea8abe2b3e11aed89de3a02d1](https://explorer.celo.org/mainnet/token/0x82360b9a2076a09ea8abe2b3e11aed89de3a02d1 ) |

---
