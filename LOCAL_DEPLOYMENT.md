# Numo Deployment Guide

## Local Development with Anvil

This repository includes scripts for deploying the Numo hook contract to a local Anvil node for development and testing.

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) installed
- Anvil (comes with Foundry)

### Quick Start

**Manual Deployment (Recommended):**

1. **Start Anvil in one terminal:**

   ```bash
   anvil
   ```

2. **In another terminal, deploy:**

   ```bash
   # Set required environment variable
   export API_KEY_ETHERSCAN="not_needed_for_local"

   # Deploy the complete ecosystem
   forge script script/Anvil.s.sol:AnvilScript \
     --rpc-url http://localhost:8545 \
     --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
     --broadcast -vv
   ```

**Alternative: Use deployment script (if your terminal supports it):**

```bash
./deploy-local.sh
```

### What Gets Deployed

The `Anvil.s.sol` script deploys a complete Uniswap V4 ecosystem including:

- **PoolManager** - Core V4 pool management contract
- **Numo Hook** - Your hook contract (deployed with proper address mining)
- **PositionManager** - For managing liquidity positions
- **Test Routers** - For liquidity and swap operations
- **Permit2** - For token approvals
- **Mock Tokens** - ERC20 tokens for testing

### Testing the Deployment

The script automatically:

1. Creates a pool with the Numo hook
2. Adds initial liquidity
3. Performs a test swap
4. Logs all deployed contract addresses

### Manual Deployment

If you prefer to deploy manually:

```bash
# Start Anvil
anvil

# In another terminal, deploy
forge script script/Anvil.s.sol:AnvilScript \
  --rpc-url http://localhost:8545 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  --broadcast -vvv
```

### Environment Variables

For mainnet or testnet deployments, you can use:

```bash
# Using mnemonic
export MNEMONIC="your twelve word mnemonic phrase here"

# Or using specific address
export ETH_FROM="0xYourAddressHere"

# Then deploy
forge script script/Deploy.s.sol:Deploy --rpc-url $RPC_URL --broadcast
```

### Deployed Addresses

After deployment, you'll see output like:

```
=== Deployed Addresses ===
PoolManager: 0x5FbDB2315678afecb367f032d93F642f64180aa3
Numo Hook: 0x[computed_hook_address]
PositionManager: 0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0
LiquidityRouter: 0x[router_address]
SwapRouter: 0x[swap_router_address]
Permit2: 0x000000000022D473030F116dDEE9F6B43aC78BA3
```

### Troubleshooting

1. **Hook address mismatch error**: This means the CREATE2 mining didn't work correctly. The script should handle this
   automatically.

2. **Permit2 deployment issues**: The script tries to use the canonical Permit2 address first, then deploys a local
   version if needed.

3. **Transaction failures**: Make sure Anvil is running and you're using the correct RPC URL.

### Next Steps

After deployment, you can:

- Interact with your hook through the deployed routers
- Test different scenarios with the mock tokens
- Develop additional functionality using the deployed addresses
