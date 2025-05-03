// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PositionManager} from "lib/v4-periphery/src/PositionManager.sol";
import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployPermit2} from "./forks/DeployPermit2.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {IPositionDescriptor} from "lib/v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "lib/v4-periphery/src/interfaces/external/IWETH9.sol";
import {EasyPosm} from "./EasyPosm.sol";
import {V4SwapRouter} from "../../src/V4SwapRouter.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "lib/solmate/src/test/utils/mocks/MockERC20.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

contract PoolSetup is DeployPermit2 {
    using EasyPosm for IPositionManager;

    // Global variables
    IPoolManager public manager;
    IPositionManager public posm;
    PoolModifyLiquidityTest public lpRouter;
    V4SwapRouter public swapRouter;

    // -----------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------

    function _initPool(
        Currency currency0,
        Currency currency1,
        IHooks hooks,
        uint24 fee,
        int24 tickSpacing,
        uint160 sqrtPriceX96
    ) internal returns (PoolKey memory key) {
        key = PoolKey(currency0, currency1, fee, tickSpacing, hooks);
        manager.initialize(key, sqrtPriceX96);
    }

    function _deployPoolManager() internal virtual {
        manager = IPoolManager(new PoolManager(address(this)));
    }

    function _deployRouters() internal virtual {
        require(address(manager) != address(0), "Manager not deployed");
        lpRouter = new PoolModifyLiquidityTest(manager);
        swapRouter = new V4SwapRouter(manager);
    }

    function _deployPosm() internal virtual {
        require(address(permit2) != address(0), "Permit2 not deployed");
        require(address(manager) != address(0), "Manager not deployed");
        etchPermit2();
        posm = IPositionManager(
            new PositionManager(manager, permit2, 300_000, IPositionDescriptor(address(0)), IWETH9(address(0)))
        );
    }

    function _approvePosmCurrency(
        Currency currency
    ) internal {
        // Because POSM uses permit2, we must execute 2 permits/approvals.
        // 1. First, the caller must approve permit2 on the token.
        IERC20(Currency.unwrap(currency)).approve(address(permit2), type(uint256).max);
        // 2. Then, the caller must approve POSM as a spender of permit2
        permit2.approve(Currency.unwrap(currency), address(posm), type(uint160).max, type(uint48).max);
    }

    function _deployTokens() internal returns (MockERC20 token0, MockERC20 token1) {
        MockERC20 tokenA = new MockERC20("MockA", "A", 6);
        MockERC20 tokenB = new MockERC20("MockB", "B", 6);
        if (uint160(address(tokenA)) < uint160(address(tokenB))) {
            token0 = tokenA;
            token1 = tokenB;
        } else {
            token0 = tokenB;
            token1 = tokenA;
        }
    }

    function _deployAndMintTokens(
        address sender,
        uint256 amount
    ) internal returns (Currency currency0, Currency currency1) {
        (MockERC20 token0, MockERC20 token1) = _deployTokens();
        token0.mint(sender, amount);
        token1.mint(sender, amount);
        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));
    }

    function _deployAndMintToken(address sender, uint256 amount) internal returns (Currency currency) {
        (MockERC20 token) = _deployToken();
        token.mint(sender, amount);
        currency = Currency.wrap(address(token));
    }

    function _deployToken() internal returns (MockERC20 token) {
        token = new MockERC20("MockToken", "MT", 6);
    }

    function _provisionLiquidity(
        uint160 sqrtPriceX96,
        int24 tickSpacing,
        PoolKey memory poolKey,
        address sender,
        uint256 amount0Max,
        uint256 amount1Max
    ) internal {
        bytes memory ZERO_BYTES = new bytes(0);

        int24 currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        int24 tickLower = (currentTick - 600) - ((currentTick - 600) % tickSpacing);
        int24 tickUpper = (currentTick + 600) - ((currentTick + 600) % tickSpacing);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0Max,
            amount1Max
        );

        posm.mint(
            poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, sender, block.timestamp + 300, ZERO_BYTES
        );
    }

    function _setTokenApprovalForRouters(
        Currency currency0
    ) internal {
        // approve the tokens to the routers
        IERC20 token0 = IERC20(Currency.unwrap(currency0));
        token0.approve(address(lpRouter), type(uint256).max);
        token0.approve(address(swapRouter), type(uint256).max);
        _approvePosmCurrency(currency0);
    }
}