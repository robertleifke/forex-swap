// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {INetwork} from "./INetwork.sol";
import {NetworkSelector} from "./NetworkSelector.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ISimpleV4Router} from "../../src/interfaces/ISimpleV4Router.sol";

contract CreatePoolAndAddLiquidityScript is Script {
    using CurrencyLibrary for Currency;

    Currency private currency0;
    Currency private currency1;
    IERC20 private token0;
    IERC20 private token1;
    PositionManager private posm;
    IAllowanceTransfer private permit2;
    ISimpleV4Router private swapRouter;

    INetwork private _env;
    address private hookAddress;

    function _init() internal {
        bool networkExists = vm.envExists("NETWORK");
        bool hookAddressExists = vm.envExists("HOOK_ADDRESS");
        require(networkExists && hookAddressExists, "All environment variables must be set if any are specified");
        string memory _network = vm.envString("NETWORK");
        _env = new NetworkSelector().select(_network);
        hookAddress = vm.envAddress("HOOK_ADDRESS");
    }

    /////////////////////////////////////

    function run() external {
        _init();
        INetwork.Config memory config = _env.config();
        INetwork.LiquidityPoolConfig memory poolConfig = _env.liquidityPoolConfig();

        // --------------------------------- //
        posm = config.positionManager;
        permit2 = config.permit2;
        currency0 = Currency.wrap(poolConfig.token0);
        currency1 = Currency.wrap(poolConfig.token1);
        token0 = IERC20(poolConfig.token0);
        token1 = IERC20(poolConfig.token1);
        swapRouter = config.router;

        // tokens should be sorted
        PoolKey memory pool = PoolKey({
            currency0: Currency.wrap(poolConfig.token0),
            currency1: Currency.wrap(poolConfig.token1),
            fee: poolConfig.fee,
            tickSpacing: poolConfig.tickSpacing,
            hooks: IHooks(hookAddress)
        });
        bytes memory hookData = new bytes(0);

        // --------------------------------- //

        // Converts token amounts to liquidity units
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            poolConfig.startingPrice,
            TickMath.getSqrtPriceAtTick(poolConfig.tickLower),
            TickMath.getSqrtPriceAtTick(poolConfig.tickUpper),
            poolConfig.token0Amount,
            poolConfig.token1Amount
        );

        // slippage limits
        uint256 amount0Max = poolConfig.token0Amount + 1 wei;
        uint256 amount1Max = poolConfig.token1Amount + 1 wei;

        (bytes memory actions, bytes[] memory mintParams) = _mintLiquidityParams(
            pool, poolConfig.tickLower, poolConfig.tickUpper, liquidity, amount0Max, amount1Max, address(this), hookData
        );

        // multicall parameters
        bytes[] memory params = new bytes[](2);

        // initialize pool
        params[0] = abi.encodeWithSelector(posm.initializePool.selector, pool, poolConfig.startingPrice, hookData);

        // mint liquidity
        params[1] = abi.encodeWithSelector(
            posm.modifyLiquidities.selector, abi.encode(actions, mintParams), block.timestamp + 60
        );

        // if the pool is an ETH pair, native tokens are to be transferred
        // uint256 valueToPass = currency0.isAddressZero() ? amount0Max : 0;

        vm.startBroadcast();
        tokenApprovals();
        vm.stopBroadcast();

        // vm.broadcast();
        // multicall to atomically create pool & add liquidity
        // posm.multicall{value: valueToPass}(params);
    }

    /// @dev helper function for encoding mint liquidity operation
    /// @dev does NOT encode SWEEP, developers should take care when minting liquidity on an ETH pair
    function _mintLiquidityParams(
        PoolKey memory poolKey,
        int24 _tickLower,
        int24 _tickUpper,
        uint256 liquidity,
        uint256 amount0Max,
        uint256 amount1Max,
        address recipient,
        bytes memory hookData
    ) internal pure returns (bytes memory, bytes[] memory) {
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(poolKey, _tickLower, _tickUpper, liquidity, amount0Max, amount1Max, recipient, hookData);
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1);
        return (actions, params);
    }

    function tokenApprovals() public {
        if (!currency0.isAddressZero()) {
            token0.approve(address(permit2), type(uint256).max);
            permit2.approve(address(token0), address(posm), type(uint160).max, type(uint48).max);
            token0.approve(address(swapRouter), type(uint256).max);
        }
        if (!currency1.isAddressZero()) {
            token1.approve(address(permit2), type(uint256).max);
            permit2.approve(address(token1), address(posm), type(uint160).max, type(uint48).max);
            token1.approve(address(swapRouter), type(uint256).max);
        }
    }
}