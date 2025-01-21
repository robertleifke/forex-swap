# Numo

[![Fuzz Testing](https://github.com/Uniswap/uniswap-v3-core/actions/workflows/fuzz-testing.yml/badge.svg)](https://github.com/numotrade/numo/actions/workflows/fuzz-testing.yml)
[![npm version](https://img.shields.io/npm/v/@uniswap/v3-core/latest.svg)](https://www.npmjs.com/package/@numotrade/numo/v/latest)

> ⚠️ **WARNING:** This code has not yet been audited. Use at your own risk.

Cash-settled forwards on FX stablecoins (e.g. EUROC-USDC pair) so any business can hedge their currency risk.

## Overview
Under the hood, each forward is repersented as a liquidity provider position in Numo, a [Uniswap V4 hook](https://github.com/Uniswap/v4-core). The synthetic `forward` uses arbitrageurs to rebalance the position so that the the desired payoff of a cash-settled forward is always maintained. This process is known as *replicating a portfolio with options* and typical done by sophicated market maker to hedge illiquid FX pairs.  Similar to traditional forwards, users can set a pair of `strikes` and an `expiry` to match their needs.  

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

## Deployment

**TODO:** Add Deployed Addresses

---
