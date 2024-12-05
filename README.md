# Puffin 

[![Fuzz Testing](https://github.com/Uniswap/uniswap-v3-core/actions/workflows/fuzz-testing.yml/badge.svg)](https://github.com/numotrade/numo/actions/workflows/fuzz-testing.yml)
[![npm version](https://img.shields.io/npm/v/@uniswap/v3-core/latest.svg)](https://www.npmjs.com/package/@numotrade/numo/v/latest)

<p align="center">
  <img src="./image/Puffin_3.png" alt="Puffin Logo" width="800">
</p>

### FX collars on EUROC/USDC.

The smart contract suite is a Uniswap V4 hook and is inspired by @primitivefinance's open source [implementation](https://github.com/primitivefinance/rmm) and the [replicating market makers](https://arxiv.org/abs/2103.14769) paper that first proved any option strategy can be constructed using AMMs.

## Hedgers

> ⚠️ **WARNING:** This code has not yet been audited. Use at your own risk.

Hedgers buy a FX collar by providing liquidity in EUROC/USDC on Puffin. Unlike in traditional options markets, **sellers** earn a premium perpetually. These premiums are paid by buyers who enjoy the *right but not obligation* to exercise the call option if it is in the money. To optimize the premiums earned, a batch auction can be implemented to match buyers and sellers. 

Puffin in theory deploy a `market` instance for each pair. Each `market` can handle any two arbitrary ERC-20 tokens.

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
