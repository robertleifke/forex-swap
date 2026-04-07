// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/src/console.sol";
import {BaseScript} from "./Base.s.sol";
import {ForexSwap} from "../src/ForexSwap.sol";
import {BaseCustomAccounting} from "uniswap-hooks/src/base/BaseCustomAccounting.sol";

interface IERC20Like {
    function balanceOf(address account) external view returns (uint256);
}

contract BaseSepoliaCNGNRemoveLiquidity is BaseScript {
    address internal constant DEFAULT_HOOK = 0xffC59B86a8b87F621ab25E06184640b6eA94Aa88;
    address internal constant USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address internal constant CNGN = 0xe2387F04d3858e7Cb64Ef5Ed6617f9B2fcEEAfa2;
    int24 internal constant TICK_LOWER = -120;
    int24 internal constant TICK_UPPER = 120;

    function run() public broadcast {
        address hookAddress = vm.envOr("HOOK", DEFAULT_HOOK);
        ForexSwap hook = ForexSwap(hookAddress);
        IERC20Like usdc = IERC20Like(USDC);
        IERC20Like cngn = IERC20Like(CNGN);

        uint256 shares = hook.balanceOf(broadcaster);
        require(shares > 0, "no LP shares");

        uint256 usdcBefore = usdc.balanceOf(broadcaster);
        uint256 cngnBefore = cngn.balanceOf(broadcaster);
        (uint256 reserve0Before, uint256 reserve1Before, uint256 liquidityBefore, uint256 priceBefore,) = hook.getPoolInfo();

        hook.removeLiquidity(
            BaseCustomAccounting.RemoveLiquidityParams({
                liquidity: shares,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1 hours,
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                salt: ZERO_SALT
            })
        );

        uint256 sharesAfter = hook.balanceOf(broadcaster);
        uint256 usdcAfter = usdc.balanceOf(broadcaster);
        uint256 cngnAfter = cngn.balanceOf(broadcaster);
        (uint256 reserve0After, uint256 reserve1After, uint256 liquidityAfter, uint256 priceAfter,) = hook.getPoolInfo();

        console.log("Hook:", hookAddress);
        console.log("Removed shares:", shares);
        console.log("Shares after:", sharesAfter);
        console.log("USDC before:", usdcBefore);
        console.log("USDC after:", usdcAfter);
        console.log("USDC returned:", usdcAfter - usdcBefore);
        console.log("cNGN before:", cngnBefore);
        console.log("cNGN after:", cngnAfter);
        console.log("cNGN returned:", cngnAfter - cngnBefore);
        console.log("Reserve0 before:", reserve0Before);
        console.log("Reserve0 after:", reserve0After);
        console.log("Reserve1 before:", reserve1Before);
        console.log("Reserve1 after:", reserve1After);
        console.log("Liquidity before:", liquidityBefore);
        console.log("Liquidity after:", liquidityAfter);
        console.log("Price before:", priceBefore);
        console.log("Price after:", priceAfter);
    }
}
