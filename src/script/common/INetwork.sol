// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {ISimpleV4Router} from "../../src/interfaces/ISimpleV4Router.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

interface INetwork {
    struct Config {
        IPoolManager poolManager;
        ISimpleV4Router router;
        PositionManager positionManager;
        IAllowanceTransfer permit2;
        address create2Deployer;
        address serviceManager;
        string policyId;
    }

    struct LiquidityPoolConfig {
        address token0;
        address token1;
        uint24 fee;
        int24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
        uint160 startingPrice;
        uint256 token0Amount;
        uint256 token1Amount;
    }

    struct TokenConfig {
        Currency USDL;
        Currency wUSDL;
        Currency USDC; // USDC
    }

    function config() external view returns (Config memory);
    function liquidityPoolConfig() external view returns (LiquidityPoolConfig memory);
    function tokenConfig() external view returns (TokenConfig memory);
}