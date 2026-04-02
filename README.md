# ForexSwap

> WARNING: This code has not been audited. Treat it as experimental.

ForexSwap is a Uniswap v4 hook prototype for FX-style pools. It plugs custom accounting into the v4 swap and liquidity
lifecycle so the pool can use a custom curve instead of the default concentrated-liquidity math.

The implementation in this repo follows the v4 architecture described in the official overview:

- `PoolManager` is the singleton that owns pool state and calls hooks.
- Hooks are permissioned contracts whose callback surface is encoded into the hook address.
- Dynamic fees are pool-level behavior in v4, but the fee policy itself is application-defined.
- Flash accounting is handled by v4; this repo focuses on custom accounting and curve logic.

Official reference:

- [Uniswap v4 overview](https://docs.uniswap.org/contracts/v4/overview)

## Repo Layout

- [`src/ForexSwap.sol`](src/ForexSwap.sol): main `ForexSwap` hook contract
- [`tests/ForexSwap.t.sol`](tests/ForexSwap.t.sol): Foundry tests
- [`script/Anvil.s.sol`](script/Anvil.s.sol): local Anvil deployment and lifecycle script
- [`script/Deploy.s.sol`](script/Deploy.s.sol): minimal non-local deploy stub

## Contract Model

`ForexSwap` inherits `BaseCustomCurve`, so it opts into v4 custom accounting rather than implementing a standalone pool.
The important contract responsibilities are:

- custom swap math via `_getUnspecifiedAmount`, `_computeAmountOut`, and `_computeAmountIn`
- owner-managed parameters for `mean`, `width`, and `swapFee`
- pause and unpause controls
- hook-local liquidity share accounting for deposits and withdrawals

The current implementation is intentionally conservative. It uses simplified reserve assumptions and approximations
rather than a production-ready statistical engine.

## Prerequisites

This repo expects git submodules to be present. A plain clone is not enough.

```sh
git clone https://github.com/robertleifke/forex-swap
cd forex-swap
git submodule update --init --recursive
bun install
forge build
```

If `forge build` fails with missing imports under `lib/`, the submodules were not initialized correctly.

## Local Development

The quickest path is a local Anvil deployment:

```sh
anvil
forge script script/Anvil.s.sol:AnvilScript \
  --rpc-url http://localhost:8545 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  --broadcast -vv
```

Or use:

```sh
./deploy-local.sh
```

The Anvil script deploys:

- a local v4 `PoolManager`
- the `ForexSwap` hook at a mined address with the required hook permission bits
- test routers
- mock ERC20s
- a sample pool and initial liquidity

## Using the Hook

Example setup:

```solidity
IPoolManager poolManager = /* deployed v4 PoolManager */;
ForexSwap forexSwap = new ForexSwap(poolManager);

PoolKey memory poolKey = PoolKey({
    currency0: Currency.wrap(address(token0)),
    currency1: Currency.wrap(address(token1)),
    fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
    tickSpacing: 60,
    hooks: forexSwap
});

poolManager.initialize(poolKey, TickMath.getSqrtPriceAtTick(0));

forexSwap.updateLogNormalParams(
    1.1e18, // mean
    2.5e17, // width
    5e15    // 0.5% swap fee
);
```

Two important v4-specific notes:

- The hook address must be mined so its low bits advertise the enabled callbacks.
- `PoolManager` owns execution. The hook is not a standalone AMM contract.

## Testing

```sh
forge test
forge test -vvv
forge test --gas-report
forge test --match-contract ForexSwapCorrectTest -vv
```

## Current Caveats

- The non-local deploy script uses a placeholder `PoolManager` address and is not production-ready.
- The pricing logic is simplified. It should be treated as a prototype, not a validated FX curve.

## License

MIT. See [`LICENSE.md`](LICENSE.md).
