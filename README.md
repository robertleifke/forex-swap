# Puffin 

[![Fuzz Testing](https://github.com/Uniswap/uniswap-v3-core/actions/workflows/fuzz-testing.yml/badge.svg)](https://github.com/numotrade/numo/actions/workflows/fuzz-testing.yml)
[![npm version](https://img.shields.io/npm/v/@uniswap/v3-core/latest.svg)](https://www.npmjs.com/package/@numotrade/numo/v/latest)

<p align="center">
  <img src="./image/Puffin_3.png" alt="Puffin Logo" width="800">
</p>

The smart contract suite is a Uniswap V4 hook and is inspired by Primitive's open source [RMM](https://github.com/primitivefinance/rmm) and the [replicating market makers](https://arxiv.org/abs/2103.14769) paper that first proved the replicated portfolio of any option strategy can be constructed using AMMs.

### FX collars

The Uniswap v4 hook is a replicated portfolio of an european-style, "zero-cost" collar for FX pairs (e.g. EUROC/USDC). This enables SMEs to hedge their FX risk with a low cost alternative that is non-custodial and doesn't require a sophisticated market maker as a counterparty.

## Hedgers

> ⚠️ **WARNING:** This code has not yet been audited. Use at your own risk.

Hedgers buy a FX collar by providing a desired notional amount of `EUROC` and `USDC` into Puffin as well as set the cap and the floor for which the exchange rate should stay. Lastly hedgers can opt for an expiry to meet their specific needs (e.g. geopolitical event). Unlike traditional FX collars, there is no need for a direct counterparty. Instead the expected returns of a FX collar are provided from fees on spot volume for the `EUROC/USDC` pair on Uniswap. You can think of fees on swaps as the premium paid by the option buyers who enjoy the *right but not obligation* to exercise the provided option if it is in the money. To keep the rebalancing fees low, a batch auction can be implemented to increase competition between arbitrageurs who rebalance the FX collar for the hedger. 

Puffin in theory deploy a `collar` instance for each pair. Each `collar` can handle any two arbitrary ERC-20 tokens but has its premium/fee optimized for FX pairs.

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
