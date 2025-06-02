#!/bin/bash

# Deploy Numo to local Anvil node
# Usage: ./deploy-anvil.sh

set -e

echo "🔧 Starting Anvil node in background..."
anvil --fork-url https://eth-mainnet.alchemyapi.io/v2/YOUR_ALCHEMY_KEY --fork-block-number 18500000 &
ANVIL_PID=$!

# Wait for anvil to start
sleep 3

echo "🚀 Deploying Numo to Anvil..."

# Deploy using the Anvil script
forge script script/Anvil.s.sol:AnvilScript --rpc-url http://localhost:8545 --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 --broadcast -vvv

echo "✅ Deployment complete!"
echo "📝 Check the console output above for deployed contract addresses"
echo "🔗 Anvil node running at http://localhost:8545"
echo "💀 To stop Anvil, run: kill $ANVIL_PID"

# Keep the script running so anvil stays alive
wait $ANVIL_PID