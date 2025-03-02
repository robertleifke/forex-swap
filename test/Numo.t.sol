// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestSetup} from "./helpers/TestSetup.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

contract NumoTest is TestSetup {
    function setUp() public override {
        super.setUp();
    }

    function test_SpotPriceAtMaturity() public {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(1)),
            fee: 0,
            tickSpacing: 1,
            hooks: hook
        });

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: 1e18,
            sqrtPriceLimitX96: 0
        });

        bytes memory hookData = "";

        hook.beforeSwap(address(0), key, params, hookData);

        vm.warp(maturity);
        vm.roll(maturity);

        uint256 price = hook.getSpotPrice();
        assertEq(price, strike, "Price should equal strike at maturity");

        hook.beforeSwap(address(0), key, params, hookData);
    }
}