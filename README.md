# Numo

> ⚠️ **WARNING:** This code has not yet been audited. Use at your own risk.

[![Fuzz Testing](https://github.com/Uniswap/uniswap-v3-core/actions/workflows/fuzz-testing.yml/badge.svg)](https://github.com/numotrade/numo/actions/workflows/fuzz-testing.yml)
[![npm version](https://img.shields.io/npm/v/@uniswap/v3-core/latest.svg)](https://www.npmjs.com/package/@numotrade/numo/v/latest)

<div align="center">
  <br />
  <a href="https://optimism.io"><img alt="Numo" src="./image/numo_readme.png" width=600></a>
  <br />
</div>

#### Automated market maker for hedging on-chain FX markets. 

## Overview

Automated market makers enable [instant cross-border payments](https://app.uniswap.org/OnchainFX.pdf) (e.g. USDC -> EUROC), but currently can't hedge the exchange rate risk for conditional one such as recurring or future payments, a critical problem for businesses and global remittances. For anyone looking to lock in a specific exchange rate for a specific time, Numo can do so for any FX pair without needing to find a counterparty.

### FX Forwards

Numo is is a log-normal AMM that is built as a [Uniswap V4](https://docs.uniswap.org/contracts/v4/overview) hook. It's trading curve enables the construction of synthetic derivative exposures, with cash-settled FX forwards being the most powerful application. Forwards allow anyone to lock in an exchange rate for a specific time. Under the hood, each forward is a liquidity provider (LP) position in Numo repersented as an `ERC-20`. Arbitrageurs then rebalance the LP position so that the desired payoff of a forward is always maintained. In other words, the exhange rate is always maintained. This process is known as *payoff replication* and typically done by sophicated market makers when their is an illiquid market.  Similar to traditional forwards, users set a pair of `strikes` and an `expiry` to match their needs.  

### Advantages 

- ✅ No exchange rate risk
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
