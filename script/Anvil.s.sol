// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/src/Script.sol";
import {console} from "forge-std/src/console.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {ForexSwap} from "../src/ForexSwap.sol";

/// @notice Minimal Anvil script that deploys PoolManager and ForexSwap.
/// @dev Hook-address mining was removed from this repo snapshot because the helper dependency is missing.
contract AnvilScript is Script {
    IPoolManager public manager;

    function run() public {
        vm.startBroadcast();
        manager = IPoolManager(address(new PoolManager()));
        ForexSwap forexSwap = new ForexSwap(manager);
        vm.stopBroadcast();

        console.log("PoolManager:", address(manager));
        console.log("ForexSwap:", address(forexSwap));
        console.log("Note: pool initialization requires a hook address whose low bits advertise the enabled callbacks.");
    }
}
