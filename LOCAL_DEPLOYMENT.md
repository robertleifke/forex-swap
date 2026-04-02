# ForexSwap Local Deployment Guide

## Context

ForexSwap is a Uniswap v4 hook, not a standalone pool contract. In v4, `PoolManager` is the singleton that owns pool state and invokes hooks during pool initialization, liquidity changes, swaps, and donations. This repo's local deployment flow sets up a minimal v4 environment around the hook.

Reference:
- [Uniswap v4 overview](https://docs.uniswap.org/contracts/v4/overview)

## Prerequisites

- Foundry installed
- Bun installed
- git submodules initialized

```sh
git submodule update --init --recursive
bun install
```

Without the submodules, Foundry cannot resolve the v4 and OpenZeppelin hook dependencies under `lib/`.

## Recommended Local Flow

1. Start Anvil:

```sh
anvil
```

2. In another terminal, deploy the local v4 stack:

```sh
forge script script/Anvil.s.sol:AnvilScript \
  --rpc-url http://localhost:8545 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  --broadcast -vv
```

You can also use:

```sh
./deploy-local.sh
```

## What the Script Deploys

[`script/Anvil.s.sol`](script/Anvil.s.sol) currently deploys:

- `PoolManager`
- `ForexSwap`
- `PoolModifyLiquidityTest`
- `PoolSwapTest`
- `PoolDonateTest`
- two mock ERC20 tokens

It then:

- mines a CREATE2 salt so the hook address has the required permission flags
- initializes a pool
- adds initial liquidity through the hook

## Important v4 Details

- Hook permissions are encoded into the hook address, so `ForexSwap` must be deployed at a mined address.
- `PoolManager` owns lifecycle execution. The hook supplies logic but does not own pool state the way a standalone AMM would.
- Flash accounting is a v4 execution optimization handled by core contracts, not by this deployment script.

## Current Limitations

- The script is designed for local development on chain ID `31337`.
- The sample swap path in the script is currently disabled.
- [`script/Deploy.s.sol`](script/Deploy.s.sol) is only a stub for non-local deployment because it uses a placeholder `PoolManager` address.

## Troubleshooting

If `forge build` or `forge script` fails with missing imports:

```sh
git submodule update --init --recursive
```

If the hook deployment fails with an address mismatch, the CREATE2 salt mining step did not produce the required permission bits.
