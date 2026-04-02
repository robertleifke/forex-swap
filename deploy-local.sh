#!/bin/bash

# Deploy ForexSwap to local Anvil node (no fork)
# Usage: ./deploy-local.sh

set -e

# Kill any existing anvil processes
echo "🧹 Cleaning up existing Anvil processes..."
pkill -f anvil || true
sleep 2

echo "🔧 Starting local Anvil node..."
anvil --host 127.0.0.1 --port 8545 > anvil.log 2>&1 &
ANVIL_PID=$!

# Wait for anvil to start and test connection
echo "⏳ Waiting for Anvil to start..."
for i in {1..30}; do
    if curl -s -X POST -H "Content-Type: application/json" \
       --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
       http://localhost:8545 > /dev/null 2>&1; then
        echo "✅ Anvil is ready!"
        break
    fi
    if [ $i -eq 30 ]; then
        echo "❌ Anvil failed to start after 30 seconds"
        echo "📋 Anvil log:"
        cat anvil.log 2>/dev/null || echo "No log file found"
        exit 1
    fi
    sleep 1
done

echo "🚀 Deploying ForexSwap to local Anvil..."

# Deploy using the Anvil script
forge script script/Anvil.s.sol:AnvilScript \
    --rpc-url http://localhost:8545 \
    --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
    --broadcast -vvv

if [ $? -eq 0 ]; then
    echo "✅ Deployment complete!"
    echo "📝 Check the console output above for deployed contract addresses"
    echo "🔗 Anvil node running at http://localhost:8545"
    echo "📋 Anvil log file: anvil.log"
    echo "💀 To stop Anvil, run: kill $ANVIL_PID"
    echo ""
    echo "🎯 To interact with the deployed contracts, use the addresses shown above"
    echo "📊 You can also view the anvil log with: tail -f anvil.log"
else
    echo "❌ Deployment failed!"
    echo "📋 Check anvil.log for details"
    kill $ANVIL_PID
    exit 1
fi

# Keep the script running so anvil stays alive
echo "🔄 Keeping Anvil running... Press Ctrl+C to stop"
wait $ANVIL_PID
