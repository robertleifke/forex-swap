// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {Numo} from "../../src/Numo.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "./HookMiner.sol";
import {PoolSetup} from "./PoolSetup.sol";
import {PositionManager} from "v4-periphery/src/PositionManager.sol";

contract NumoSetup is PoolSetup {
    Numo public numo;
    Currency public currency0;
    Currency public currency1;
    PoolKey public poolKey;

    function _setUpNumo(address liquidityProvider) internal {
        _deployPoolManager();
        _deployRouters();
        _deployPosm();

        (currency0, currency1) = _deployAndMintTokens(liquidityProvider, 100_000e6);

        vm.startPrank(liquidityProvider);
        _setTokenApprovalForRouters(currency0);
        _setTokenApprovalForRouters(currency1);
        vm.stopPrank();

        uint256 mean = 1e18;
        uint256 width = 1e17;
        numo = new Numo(manager, mean, width);

        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
            Hooks.BEFORE_INITIALIZE_FLAG
        );

        address hookAddress = HookMiner.findHookAddress(address(numo), flags);

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(hookAddress)
        });

        uint160 sqrtPriceX96 = 2**96; // price = 1 in Q64.96
        vm.prank(liquidityProvider);
        manager.initialize(poolKey, sqrtPriceX96);

        _provisionLiquidity(
            sqrtPriceX96,
            poolKey.tickSpacing,
            poolKey,
            liquidityProvider,
            1000e6,
            1000e6
        );
    }
}
