// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/src/Test.sol";
import {ForexSwap} from "../src/ForexSwap.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

contract ForexSwapHarness is ForexSwap {
    constructor(IPoolManager manager) ForexSwap(manager) {}

    function seedState(uint256 reserve0, uint256 reserve1, uint256 liquidityL, uint256 supply, address holder) external {
        poolState = PoolState({reserve0: reserve0, reserve1: reserve1, liquidity: liquidityL});
        totalSupply = supply;
        if (holder != address(0) && supply > 0) balanceOf[holder] = supply;
    }

    function seedConsistentState(uint256 reserve0, uint256 liquidityL, uint256 supply, address holder) external {
        uint256 reserve1 = _solveReserve1(reserve0, liquidityL);
        poolState = PoolState({reserve0: reserve0, reserve1: reserve1, liquidity: liquidityL});
        totalSupply = supply;
        if (holder != address(0) && supply > 0) balanceOf[holder] = supply;
    }

    function quoteExactInput(uint256 amountIn, bool zeroForOne) external view returns (uint256) {
        return zeroForOne ? _quoteExactInput0For1(amountIn) : _quoteExactInput1For0(amountIn);
    }

    function executeExactInput(uint256 amountIn, bool zeroForOne) external returns (uint256) {
        return zeroForOne ? _executeExactInput0For1(amountIn) : _executeExactInput1For0(amountIn);
    }

    function planRemove(uint256 shares) external view returns (uint256 amount0, uint256 amount1, uint256 deltaL) {
        RemoveLiquidityPlan memory plan = _planRemoveLiquidity(shares);
        return (plan.amount0, plan.amount1, plan.deltaL);
    }

    function planBootstrap(uint160 sqrtPriceX96, uint256 amount0Desired, uint256 amount1Desired)
        external
        view
        returns (uint256 amount0, uint256 amount1, uint256 shares, uint256 deltaL)
    {
        AddLiquidityPlan memory plan = _planAddLiquidity(
            sqrtPriceX96,
            AddLiquidityParams({
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: 0,
                amount1Min: 0,
                to: address(this),
                deadline: block.timestamp + 1,
                tickLower: 0,
                tickUpper: 0,
                salt: bytes32(0)
            })
        );

        return (plan.amount0, plan.amount1, plan.shares, plan.deltaL);
    }
}

contract ForexSwapCorrectTest is Test {
    ForexSwapHarness internal forexSwap;
    PoolManager internal poolManager;

    address internal alice = address(0x1111);

    function setUp() public {
        poolManager = new PoolManager();
        bytes memory initCode = abi.encodePacked(type(ForexSwapHarness).creationCode, abi.encode(poolManager));
        bytes32 initCodeHash = keccak256(initCode);
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );

        bytes32 salt;
        for (uint256 i = 0; i < 50_000; ++i) {
            salt = bytes32(i);
            address predicted = vm.computeCreate2Address(salt, initCodeHash, address(this));
            if ((uint160(predicted) & ((1 << 14) - 1)) == flags) {
                forexSwap = new ForexSwapHarness{salt: salt}(poolManager);
                return;
            }
        }

        revert("failed to mine hook address");
    }

    function _seedBalancedPool() internal {
        forexSwap.seedConsistentState(4e17, 1e18, 1e18, alice);
    }

    function test_owner() external view {
        assertEq(forexSwap.owner(), address(this));
    }

    function test_pauseFunctionality() external {
        forexSwap.emergencyPause();
        assertTrue(forexSwap.paused());

        forexSwap.emergencyUnpause();
        assertFalse(forexSwap.paused());
    }

    function test_updateLogNormalParams() external {
        forexSwap.updateLogNormalParams(12e17, 3e17, 4e15);
        (uint256 mu, uint256 sigma, uint256 swapFee) = forexSwap.logNormalParams();
        assertEq(mu, 12e17);
        assertEq(sigma, 3e17);
        assertEq(swapFee, 4e15);
    }

    function test_bootstrapPlanUsesPoolPriceAndReturnsLPShares() external view {
        (uint256 amount0, uint256 amount1, uint256 shares, uint256 deltaL) =
            forexSwap.planBootstrap(79_228_162_514_264_337_593_543_950_336, 4e17, 5e17);

        assertEq(amount0, 4e17);
        assertGt(amount1, 0);
        assertEq(shares, deltaL);
        assertGt(deltaL, 0);
    }

    function test_quoteAndExecuteExactInputZeroForOneMoveState() external {
        _seedBalancedPool();

        uint256 quote = forexSwap.quoteExactInput(1e16, true);
        assertGt(quote, 0);

        uint256 beforeReserve0;
        uint256 beforeReserve1;
        uint256 beforeLiquidity;
        (beforeReserve0, beforeReserve1, beforeLiquidity,) = _state();

        uint256 amountOut = forexSwap.executeExactInput(1e16, true);
        assertEq(amountOut, quote);

        (uint256 reserve0, uint256 reserve1, uint256 liquidityL,) = _state();
        assertEq(reserve0, beforeReserve0 + 1e16);
        assertEq(reserve1 + amountOut, beforeReserve1);
        assertGe(liquidityL, beforeLiquidity);
    }

    function test_quoteAndExecuteExactInputOneForZeroMoveState() external {
        _seedBalancedPool();

        uint256 quote = forexSwap.quoteExactInput(1e16, false);
        assertGt(quote, 0);

        uint256 beforeReserve0;
        uint256 beforeReserve1;
        uint256 beforeLiquidity;
        (beforeReserve0, beforeReserve1, beforeLiquidity,) = _state();

        uint256 amountOut = forexSwap.executeExactInput(1e16, false);
        assertEq(amountOut, quote);

        (uint256 reserve0, uint256 reserve1, uint256 liquidityL,) = _state();
        assertEq(reserve1, beforeReserve1 + 1e16);
        assertEq(reserve0 + amountOut, beforeReserve0);
        assertGe(liquidityL, beforeLiquidity);
    }

    function test_removePlanScalesWithShares() external {
        _seedBalancedPool();

        (uint256 amount0, uint256 amount1, uint256 deltaL) = forexSwap.planRemove(5e17);

        assertEq(deltaL, 5e17);
        assertEq(amount0, 2e17);
        assertEq(amount1, 258_111_562_965_281_393);
    }

    function test_currentInvariantIsNearZeroOnSeededState() external {
        _seedBalancedPool();
        int256 invariantValue = forexSwap.currentInvariant();
        assertApproxEqAbs(invariantValue, 0, 1e15);
    }

    function test_nonOwnerCannotUpdateParams() external {
        vm.prank(alice);
        vm.expectRevert();
        forexSwap.updateLogNormalParams(1e18, 5e17, 3e15);
    }

    function _state() internal view returns (uint256 reserve0, uint256 reserve1, uint256 liquidityL, uint256 supply) {
        (reserve0, reserve1, liquidityL) = forexSwap.poolState();
        supply = forexSwap.totalSupply();
    }
}
