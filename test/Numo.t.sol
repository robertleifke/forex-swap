// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Numo} from "src/Numo.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

contract NumoTest is Test {
    Numo numo;

    address user = address(0xBEEF);

    function setUp() public {
        poolManager = new MockPoolManager();
        numo = new Numo(IPoolManager(address(poolManager)), 1e18, 0.1e18); // mean=1, width=0.1
    }

    function testAddLiquidity() public {
        vm.prank(user);
        (uint256 amount0, uint256 amount1, uint256 shares) = numo._getAmountIn(
            Numo.AddLiquidityParams(1000e18, 1000e18, 0, 0)
        );

        assertGt(shares, 0);
        assertEq(numo.totalLiquidity(), shares);
        assertEq(numo.reserve0(), amount0);
        assertEq(numo.reserve1(), amount1);
    }

    function testRemoveLiquidity() public {
        vm.startPrank(user);
        numo._getAmountIn(Numo.AddLiquidityParams(1000e18, 1000e18, 0, 0));
        vm.stopPrank();

        uint256 prevLiquidity = numo.totalLiquidity();

        vm.prank(user);
        (uint256 amount0, uint256 amount1, uint256 shares) = numo._getAmountOut(
            Numo.RemoveLiquidityParams(prevLiquidity)
        );

        assertEq(numo.reserve0(), 0);
        assertEq(numo.reserve1(), 0);
        assertEq(numo.totalLiquidity(), 0);
    }

    function testSimpleSwapZeroForOne() public {
        vm.startPrank(user);
        numo._getAmountIn(Numo.AddLiquidityParams(1000e18, 1000e18, 0, 0));
        vm.stopPrank();

        vm.prank(user);
        (,,uint24 fee) = numo._beforeSwap(user, PoolKey({
            currency0: IPoolManager.Currency.wrap(address(0)),
            currency1: IPoolManager.Currency.wrap(address(1)),
            fee: 0,
            tickSpacing: 1
        }), IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: int256(10e18),
            sqrtPriceLimitX96: 0
        }), "");

        assertEq(fee, 0);
        assertGt(numo.reserve0(), 1000e18);
        assertLt(numo.reserve1(), 1000e18);
    }

    function testSimpleSwapOneForZero() public {
        vm.startPrank(user);
        numo._getAmountIn(Numo.AddLiquidityParams(1000e18, 1000e18, 0, 0));
        vm.stopPrank();

        vm.prank(user);
        (,,uint24 fee) = numo._beforeSwap(user, PoolKey({
            currency0: IPoolManager.Currency.wrap(address(0)),
            currency1: IPoolManager.Currency.wrap(address(1)),
            fee: 0,
            tickSpacing: 1
        }), IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: int256(10e18),
            sqrtPriceLimitX96: 0
        }), "");

        assertEq(fee, 0);
        assertGt(numo.reserve1(), 1000e18);
        assertLt(numo.reserve0(), 1000e18);
    }
}