// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestSetup} from "./helpers/TestSetup.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BaseCustomAccounting} from "@uniswap-hooks/base/BaseCustomAccounting.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

contract NumoTest is TestSetup {
    PoolKey internal key;
    bytes internal emptyHookData;

    function setUp() public override {
        super.setUp();

        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(1)),
            fee: 0,
            tickSpacing: 1,
            hooks: hook
        });

        emptyHookData = "";
    }

    function test_SpotPriceAtMaturity() public {
        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 1e18, sqrtPriceLimitX96: 0});

        uint256 preBefore = hook.getSpotPrice();
        hook.beforeSwap(address(0), key, params, emptyHookData);
        uint256 preAfter = hook.getSpotPrice();
        assertGt(preBefore, 0, "Price should be non-zero before maturity");

        vm.warp(maturity);
        vm.roll(maturity);

        uint256 price = hook.getSpotPrice();
        assertEq(price, strike, "Price should equal strike at maturity");
    }

    function test_AddLiquidity() public {
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: -1,
            tickUpper: 1,
            liquidityDelta: int256(1e18),
            salt: bytes32(0)
        });

        uint256 totalLiquidityBefore = hook.totalLiquidity();
        hook.beforeAddLiquidity(address(this), key, params, "");
        uint256 totalLiquidityAfter = hook.totalLiquidity();

        assertGt(totalLiquidityAfter, totalLiquidityBefore, "Liquidity should increase");
    }

    function test_RemoveLiquidity() public {
        IPoolManager.ModifyLiquidityParams memory addParams = IPoolManager.ModifyLiquidityParams({
            tickLower: -1,
            tickUpper: 1,
            liquidityDelta: int256(1e18),
            salt: bytes32(0)
        });
        hook.beforeAddLiquidity(address(this), key, addParams, "");

        IPoolManager.ModifyLiquidityParams memory removeParams = IPoolManager.ModifyLiquidityParams({
            tickLower: -1,
            tickUpper: 1,
            liquidityDelta: -int256(1e18),
            salt: bytes32(0)
        });

        uint256 totalLiquidityBefore = hook.totalLiquidity();
        hook.beforeRemoveLiquidity(address(this), key, removeParams, "");
        uint256 totalLiquidityAfter = hook.totalLiquidity();

        assertLt(totalLiquidityAfter, totalLiquidityBefore, "Liquidity should decrease");
    }

    function test_PrepareInit() public {
        uint256 priceX = 1000e18; // $1000
        uint256 amountX = 1e18; // 1 token

        (uint256 totalLiquidity_, uint256 amountY) = hook.prepareInit(priceX, amountX, strike, sigma);

        assertGt(totalLiquidity_, 0, "Total liquidity should be non-zero");
        assertGt(amountY, 0, "Amount Y should be non-zero");
    }

    function test_RevertAfterMaturity() public {
        vm.warp(maturity + 1);

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: -1,
            tickUpper: 1,
            liquidityDelta: int256(1e18),
            salt: bytes32(0)
        });

        vm.expectRevert("Expired, Cannot Add Liquidity");
        hook.beforeAddLiquidity(address(this), key, params, "");
    }

    function test_GetUnspecifiedAmount() public {
        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 1e18, sqrtPriceLimitX96: 0});

        (bytes4 selector, BeforeSwapDelta delta,) = hook.beforeSwap(address(0), key, params, emptyHookData);
        assertEq(selector, hook.beforeSwap.selector, "Should return correct selector");

        vm.warp(maturity);
        (selector, delta,) = hook.beforeSwap(address(0), key, params, emptyHookData);
        assertEq(selector, hook.beforeSwap.selector, "Should return correct selector at maturity");
    }
}
