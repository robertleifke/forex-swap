# Numo 🟩 

[![Fuzz Testing](https://github.com/Uniswap/uniswap-v3-core/actions/workflows/fuzz-testing.yml/badge.svg)](https://github.com/numocash/numo/actions/workflows/fuzz-testing.yml)
[![npm version](https://img.shields.io/npm/v/@uniswap/v3-core/latest.svg)](https://www.npmjs.com/package/@numocash/numo/v/latest)

### A market maker for options on stablecoins (e.g. USDC/USDT).

The smart contract suite is a Uniswap V4 hook and is inspired by @primitivefinance's open source [RMM-01](https://github.com/primitivefinance/rmm) implementation and the [replicating market makers](https://arxiv.org/abs/2103.14769) paper that first proved any option strategy can be constructed using CFMMs.

## Liquidity Providers

> ⚠️ **WARNING:** This code has not yet been audited. Use at your own risk.

Liquidity providers on Numo earn sustainable yield from selling [european-style call options](https://en.wikipedia.org/wiki/European_option). As in traditional options markets, **sellers** earn a premium upfront. These premiums are paid by arbitrageurs who enjoy the *right but not obligation* to rebalance the underlying liquidity, potentially earning profits from the arbitrage a.k.a exercising the option. To optimize the premiums earned, a batch auction can be implemented to match buyers and sellers. Numo could also directly integrate with exisiting options exhanges (e.g. CME).

Numo deploys a `market` instance for each stablecoin pair. Each `market` can handle any two arbitrary ERC-20 token and follows the standard naming conventions seen in traditional FX markets (`base`/`quote`).

## Set up

*requires [foundry](https://book.getfoundry.sh)*

```
forge install
forge test
```

#### Updating to v4 dependencies

```bash
forge install v4-core
```

## Deployment

For testing on your local machine, deploy on Anvil.

```bash
# start anvil, a local EVM chain
anvil

# in a new terminal
forge script script/Anvil.s.sol \
    --rpc-url http://localhost:8545 \
    --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
    --broadcast
```

---
