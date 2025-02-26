# Numo

> ⚠️ **WARNING:** This code has not yet been audited. Use at your own risk.

[![Fuzz Testing](https://github.com/Uniswap/uniswap-v3-core/actions/workflows/fuzz-testing.yml/badge.svg)](https://github.com/numotrade/numo/actions/workflows/fuzz-testing.yml)
[![npm version](https://img.shields.io/npm/v/@uniswap/v3-core/latest.svg)](https://www.npmjs.com/package/@numotrade/numo/v/latest)

<div align="center">
  <br />
  <a href="https://optimism.io"><img alt="Numo" src="./image/numo_readme.png" width=600></a>
  <br />
</div>

#### Automated market maker for on-chain derivatives

## Overview

Automated market makers (AMMs) have revolutionized spot markets by bootstrapping liquidity without relying on external price feeds. As the token economy expands, this mechanism has proven invaluable. Yet, no equivalent solution exists for derivatives. Bootstrapping liquidity for derivative markets without established prices is a fundamentally harder problem. As a result, derivative markets are limited to a small subset of tokens. Numo changes this. By leveraging the novelty of AMMs, Numo enables derivative exposure on any token—without requiring a counterparty or oracles. 

### Applications

- **Perpetual Futures:** "Perps" are the most traded cryptocurrency deriative. With Numo, traders can replicate perpetual future exposure on long-tail cryptocurrencies.  

- **Forwards:** For cross-border lending, payments, and exchange, Numo can replicate an FX forward so users can lock in an exchange rate for a specific time. 

### Advantages 

- ✅ Any derivative exposure
- 🌍 Globally accessible
- 🤝 No reliance on counterparties
- 🛠️ Customizability 

## Architecture

Numo is a Uniswap V4 hook that inherits OpenZeppelin's `BaseCustomCurve` contract from their `uniswap-hooks` library. Thus enabling Numo to inherit much of the security guarantees of Uniswap V4 battle tested code while overriding the concentrated liquidity logic to support the replication of deriatives. Instead of calling `beforeSwap` directly, Numo.sol implements its custom trading curve logic in `_getUnspecifiedAmount` to support the replication of derivatives. Each call and put is repersented as a `ERC-6909` token. 

#### Trading curve

The trading curve in Numo determines the price and behavior of the AMM. Unlike a traditional constant product AMM like in Uniswap V2, Numo implements a log-normal model to adjusts prices dynamically based on volatility (σ), strike (K), and time to maturity (τ). It allows users to swap assets at implied vol-adjusted prices, mimicking an options market. The formula:

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
