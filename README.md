# Numo

> ⚠️ **WARNING:** This code has not yet been audited. Use at your own risk.

[![Fuzz Testing](https://github.com/Uniswap/uniswap-v3-core/actions/workflows/fuzz-testing.yml/badge.svg)](https://github.com/numotrade/numo/actions/workflows/fuzz-testing.yml)
[![npm version](https://img.shields.io/npm/v/@uniswap/v3-core/latest.svg)](https://www.npmjs.com/package/@numotrade/numo/v/latest)

<div align="center">
  <br />
  <a href="https://optimism.io"><img alt="Numo" src="./image/numo_readme.png" width=600></a>
  <br />
</div>

#### A log-normal automated market maker for efficient swapping of on-chain FX. 

## Overview
The most intresting application built on top of Numo's log-normal curve are cash settled forwards for currency hedging. Under the hood, each forward would be repersented as a liquidity provider position in Numo, a [Uniswap V4 hook](https://github.com/Uniswap/v4-core). The synthetic `forward` uses arbitrageurs to rebalance the position so that the the desired payoff of a cash-settled forward is always maintained. This process is known as *replicating a portfolio with options* and typical done by sophicated market maker to hedge illiquid FX pairs.  Similar to traditional forwards, users can set a pair of `strikes` and an `expiry` to match their needs.  

### Advantages 

- No exchange rate risk
- Globally accessible
- No reliance on counterparties
- Customizability 

#### Acknowledgements

The smart contract suite is inspired by Primitive's open source [RMM](https://github.com/primitivefinance/rmm) and the [replicating market makers](https://arxiv.org/abs/2103.14769) paper that first proved the replicated portfolio of any option strategy can be constructed using AMMs.

## Usage

```
forge install
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
