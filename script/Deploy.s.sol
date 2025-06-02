// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import { Numo } from "../src/Numo.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";

import { BaseScript } from "./Base.s.sol";

contract Deploy is BaseScript {
    function run() public broadcast returns (Numo numo) {
        // Mock pool manager for deployment - replace with actual pool manager address
        IPoolManager poolManager = IPoolManager(address(0x1234567890123456789012345678901234567890));
        numo = new Numo(poolManager);
    }
}
