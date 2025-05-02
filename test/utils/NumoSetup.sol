// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {Numo} from "../../src/Numo.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "./HookMiner.sol";
import {PoolSetup} from "./PoolSetup.sol";
import {PositionManager} from "v4-periphery/src/PositionManager.sol";

contract NumoSetup is PoolSetup {
    Numo public numo;
    Currency public currency0;
    Currency public currency1;
    PoolKey public poolKey;

    function _setUpNumo(
        address _liquidityProvider,
        uint256 _mean,
        uint256 _width,
        IPoolManager _manager,
        IHooks _hooks
    ) internal {
        address _owner = makeAddr("owner");
        _deployPoolManager();
        _deployRouters();
        _deployPosm();
        (currency0, currency1) = _deployAndMintTokens(_liquidityProvider, 100_000e6);
        vm.startPrank(_liquidityProvider);
        _setTokenApprovalForRouters(currency0);
        _setTokenApprovalForRouters(currency1);
        vm.stopPrank();
        
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                | Hooks.BEFORE_DONATE_FLAG
        );
    }
}