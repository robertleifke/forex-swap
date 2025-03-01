// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Numo} from "../../src/Numo.sol";
import {HookMiner} from "../utils/HookMiner.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

abstract contract TestSetup is Test {
    IPoolManager public poolManager;
    Numo public hook;

    uint256 public sigma;
    uint256 public strike;
    uint256 public maturity;

    function setUp() public virtual {
        sigma = 1e18;      
        strike = 2000e18;  
        maturity = block.timestamp + 7 days; 

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | 
            Hooks.AFTER_INITIALIZE_FLAG |
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
            Hooks.AFTER_ADD_LIQUIDITY_FLAG |
            Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG |
            Hooks.AFTER_REMOVE_LIQUIDITY_FLAG |
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.AFTER_SWAP_FLAG |
            Hooks.BEFORE_DONATE_FLAG |
            Hooks.AFTER_DONATE_FLAG |
            Hooks.BEFORE_SWAP_RETURN_DELTA_FLAG |
            Hooks.AFTER_SWAP_RETURN_DELTA_FLAG |
            Hooks.AFTER_ADD_LIQUIDITY_RETURN_DELTA_FLAG |
            Hooks.AFTER_REMOVE_LIQUIDITY_RETURN_DELTA_FLAG
        );
        bytes memory constructorArgs = abi.encode(poolManager, sigma, strike, maturity);
        
        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            flags,                  
            type(Numo).creationCode,
            constructorArgs        
        );

        hook = new Numo{salt: salt}(poolManager, sigma, strike, maturity);
        require(address(hook) == hookAddress, "Hook deployment failed");
    }
}