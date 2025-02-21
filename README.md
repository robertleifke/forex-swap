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
