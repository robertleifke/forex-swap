// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Numo} from "../src/Numo.sol";
import {NumoSetup} from "./utils/NumoSetup.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {V4SwapRouter} from "../src/V4SwapRouter.sol";
import {Test} from "forge-std/Test.sol";

contract NumoTest is Test, NumoSetup {
    address public liquidityProvider;
    address public user;

    function setUp() public override {
        liquidityProvider = makeAddr("liquidityProvider");
        user = makeAddr("user");
        super.setUp();
        _setUpNumo(liquidityProvider);

        // Mint tokens for user and approve router
        (address token0, address token1) = (
            Currency.unwrap(currency0),
            Currency.unwrap(currency1)
        );

        vm.startPrank(user);
        IERC20(token0).approve(address(swapRouter), type(uint256).max);
        IERC20(token1).approve(address(swapRouter), type(uint256).max);
        MockERC20(token0).mint(user, 10_000e6);
        MockERC20(token1).mint(user, 10_000e6);
        vm.stopPrank();
    }

    function testSwapZeroForOne() public {
        uint256 amountIn = 1000e6;

        vm.prank(user);
        swapRouter.swap({
            poolKey: poolKey,
            zeroForOne: true,
            amountSpecified: int256(amountIn),
            sqrtPriceLimitX96: 0,
            recipient: user,
            deadline: block.timestamp + 1,
            refundTo: user
        });

        assertLt(IERC20(Currency.unwrap(currency0)).balanceOf(user), 10_000e6);
        assertGt(IERC20(Currency.unwrap(currency1)).balanceOf(user), 10_000e6);
    }

    function testSwapOneForZero() public {
        uint256 amountIn = 1000e6;

        vm.prank(user);
        swapRouter.swap({
            poolKey: poolKey,
            zeroForOne: false,
            amountSpecified: int256(amountIn),
            sqrtPriceLimitX96: 0,
            recipient: user,
            deadline: block.timestamp + 1,
            refundTo: user
        });

        assertLt(IERC20(Currency.unwrap(currency1)).balanceOf(user), 10_000e6);
        assertGt(IERC20(Currency.unwrap(currency0)).balanceOf(user), 10_000e6);
    }

    function testLiquidityWasProvisioned() public {
        assertGt(numo.totalLiquidity(), 0);
        assertGt(numo.reserve0(), 0);
        assertGt(numo.reserve1(), 0);
    }
}
