// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script } from "forge-std/src/Script.sol";
import { console } from "forge-std/src/console.sol";
import { IHooks } from "v4-core/src/interfaces/IHooks.sol";
import { Hooks } from "v4-core/src/libraries/Hooks.sol";
import { PoolManager } from "v4-core/src/PoolManager.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { PoolModifyLiquidityTest } from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import { PoolSwapTest } from "v4-core/src/test/PoolSwapTest.sol";
import { PoolDonateTest } from "v4-core/src/test/PoolDonateTest.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol"; // solhint-disable-line import-path-check
import { Constants } from "v4-core/test/utils/Constants.sol";
import { TickMath } from "v4-core/src/libraries/TickMath.sol";
import { Currency } from "v4-core/src/types/Currency.sol";
import { Numo } from "../src/Numo.sol";
import { HookMiner } from "v4-periphery/src/utils/HookMiner.sol";

/// @notice Forge script for deploying Numo & basic v4 ecosystem to **anvil**
contract AnvilScript is Script {
    error HookAddressMismatch();
    error InvalidChainId();

    address public constant CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

    IPoolManager public manager;
    PoolModifyLiquidityTest public lpRouter;
    PoolSwapTest public swapRouter;

    function setUp() public {
        // Setup function required by Script base contract
        // This function is called before run() to initialize the script

        // Validate that we're in a test environment
        if (block.chainid != 31_337) {
            revert InvalidChainId();
        }
    }

    function run() public {
        // Deploy PoolManager
        vm.broadcast();
        manager = deployPoolManager();

        // Mine hook address with required permissions
        uint160 permissions = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );

        // Mine a salt that will produce a hook address with the correct permissions
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, permissions, type(Numo).creationCode, abi.encode(address(manager)));

        // Deploy the Numo hook using CREATE2
        vm.broadcast();
        Numo numo = new Numo{ salt: salt }(manager);
        if (address(numo) != hookAddress) {
            revert HookAddressMismatch();
        }

        // Deploy test routers for interacting with the pool
        vm.startBroadcast();
        (lpRouter, swapRouter,) = deployRouters(manager);
        vm.stopBroadcast();

        // Test the lifecycle (create pool, add liquidity, swap)
        vm.startBroadcast();
        testLifecycle(address(numo));
        vm.stopBroadcast();

        // Log deployed addresses
        console.log("=== Deployed Addresses ===");
        console.log("PoolManager:", address(manager));
        console.log("Numo Hook:", address(numo));
        console.log("LiquidityRouter:", address(lpRouter));
        console.log("SwapRouter:", address(swapRouter));
    }

    // -----------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------
    function deployPoolManager() internal returns (IPoolManager) {
        return IPoolManager(address(new PoolManager(address(0))));
    }

    function deployRouters(IPoolManager _manager)
        internal
        returns (PoolModifyLiquidityTest _lpRouter, PoolSwapTest _swapRouter, PoolDonateTest _donateRouter)
    {
        _lpRouter = new PoolModifyLiquidityTest(_manager);
        _swapRouter = new PoolSwapTest(_manager);
        _donateRouter = new PoolDonateTest(_manager);
    }

    function deployTokens() internal returns (MockERC20 token0, MockERC20 token1) {
        MockERC20 tokenA = new MockERC20("MockA", "MOCKA", 18);
        MockERC20 tokenB = new MockERC20("MockB", "MOCKB", 18);
        if (uint160(address(tokenA)) < uint160(address(tokenB))) {
            token0 = tokenA;
            token1 = tokenB;
        } else {
            token0 = tokenB;
            token1 = tokenA;
        }
    }

    function testLifecycle(address hook) internal {
        (MockERC20 token0, MockERC20 token1) = deployTokens();
        token0.mint(msg.sender, 100_000 ether);
        token1.mint(msg.sender, 100_000 ether);

        console.log("=== Test Tokens ===");
        console.log("Token0:", address(token0));
        console.log("Token1:", address(token1));

        // Initialize the pool
        int24 tickSpacing = 60;
        PoolKey memory poolKey =
            PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 3000, tickSpacing, IHooks(hook));
        manager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        console.log("Pool initialized with hook:", hook);

        // Approve the tokens to the hook and swap router
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);

        // Add full range liquidity to the pool
        int24 tickLower = TickMath.minUsableTick(tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(tickSpacing);
        _exampleAddLiquidity(poolKey, tickLower, tickUpper, hook);

        // Swap some tokens (disabled due to currency balance issues)
        // _exampleSwap(poolKey);

        console.log("Lifecycle test completed successfully!");
        console.log(
            "Note: Swap functionality is disabled in this deployment due to currency balance management complexity."
        );
    }

    function _exampleAddLiquidity(
        PoolKey memory poolKey, // solhint-disable-line no-unused-vars
        int24 tickLower, // solhint-disable-line no-unused-vars
        int24 tickUpper, // solhint-disable-line no-unused-vars
        address hookAddress
    )
        internal
    {
        // Add liquidity using Numo's native function
        Numo numoHook = Numo(hookAddress);
        uint256 deadline = block.timestamp + 300; // 5 minutes
        numoHook.addLiquidityWithSlippage(
            50 ether, // amount0Desired
            50 ether, // amount1Desired
            45 ether, // amount0Min (10% slippage)
            45 ether, // amount1Min (10% slippage)
            deadline
        );

        console.log("Added liquidity to pool via Numo hook");
    }

    function _exampleSwap(PoolKey memory poolKey) internal {
        bool zeroForOne = true;
        int256 amountSpecified = 1 ether;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1 // unlimited
                // impact
         });
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false });
        swapRouter.swap(poolKey, params, testSettings, "");

        console.log("Performed swap in pool");
    }
}
