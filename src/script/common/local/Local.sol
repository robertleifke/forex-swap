// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import "../common/INetwork.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {ISimpleV4Router} from "../../src/interfaces/ISimpleV4Router.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

contract Local is INetwork {
    address public constant USDL = address(0x959922bE3CAee4b8Cd9a407cc3ac1C251C2007B1);
    address public constant WUSDL = address(0x9A9f2CCfdE556A7E9Ff0848998Aa4a0CFD8863AE);
    address public constant USDC = address(0x68B1D87F95878fE05B998F19b66F4baba5De1aed);

    function config() external pure override returns (Config memory) {
        return Config({
            poolManager: IPoolManager(address(0x2279B7A0a67DB372996a5FaB50D91eAA73d2eBe6)),
            router: ISimpleV4Router(address(0x8A791620dd6260079BF849Dc5567aDC3F2FdC318)),
            positionManager: PositionManager(payable(address(0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0))), // not used
            permit2: IAllowanceTransfer(address(0x1f98407aaB862CdDeF78Ed252D6f557aA5b0f00d)), // not used
            create2Deployer: address(0x4e59b44847b379578588920cA78FbF26c0B4956C),
            serviceManager: address(0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0),
            policyId: "local-test-policy"
        });
    }

    function liquidityPoolConfig() external pure override returns (LiquidityPoolConfig memory) {
        return LiquidityPoolConfig({
            token0: USDC,
            token1: WUSDL,
            fee: 3000,
            tickSpacing: 60,
            tickLower: -600,
            tickUpper: 600,
            startingPrice: 79_228_162_514_264_337_593_543_950_336,
            token0Amount: 1e18,
            token1Amount: 1e18
        });
    }

    function tokenConfig() external pure override returns (TokenConfig memory) {
        return TokenConfig({USDL: Currency.wrap(USDL), wUSDL: Currency.wrap(WUSDL), USDC: Currency.wrap(USDC)});
    }
}