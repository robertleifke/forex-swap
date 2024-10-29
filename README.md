# Numo 🟩 

[![Fuzz Testing](https://github.com/Uniswap/uniswap-v3-core/actions/workflows/fuzz-testing.yml/badge.svg)](https://github.com/numocash/numo/actions/workflows/fuzz-testing.yml)
[![npm version](https://img.shields.io/npm/v/@uniswap/v3-core/latest.svg)](https://www.npmjs.com/package/@numocash/numo/v/latest)

### A marketplace for options (e.g. sell EUROC/USDC calls).

Numo enables 24/7 option markets on any ERC-20 tokens. The smart contract suite is a Uniswap V4 hook and is inspired by @primitivefinance's open source [RMM-01](https://github.com/primitivefinance/rmm) implementation and the [replicating market makers](https://arxiv.org/abs/2103.14769) paper that first proved any option strategy can be constructed using CFMMs.

## Liquidity Providers

> ⚠️ **WARNING:** This code has not yet been audited. Use at your own risk.

Liquidity providers on Numo earn sustainable yield from selling [european-style call options](https://en.wikipedia.org/wiki/European_option). As in traditional options markets, **sellers** earn a premium upfront. These premiums are paid by buyers who enjoy the *right but not obligation* to exercise the call option if it is in the money. To optimize the premiums earned, a batch auction can be implemented to match buyers and sellers. 

Numo deploys a `market` instance for each pair. Each `market` can handle any two arbitrary ERC-20 token and follows the standard naming conventions seen in traditional FX markets (`base`/`quote`).

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
