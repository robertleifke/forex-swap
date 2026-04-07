// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import { Test } from "forge-std/src/Test.sol";
import { ForexSwap } from "../src/ForexSwap.sol";
import { BaseCustomAccounting } from "uniswap-hooks/src/base/BaseCustomAccounting.sol";
import { CurrencySettler } from "uniswap-hooks/src/utils/CurrencySettler.sol";
import { PoolManager } from "@uniswap/v4-core/src/PoolManager.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";

contract SimplePoolSwapRouter {
    using CurrencySettler for Currency;

    IPoolManager internal immutable manager;

    struct CallbackData {
        address sender;
        PoolKey key;
        SwapParams params;
    }

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    function swap(PoolKey memory key, SwapParams memory params) external returns (BalanceDelta delta) {
        delta = abi.decode(manager.unlock(abi.encode(CallbackData({ sender: msg.sender, key: key, params: params }))), (BalanceDelta));
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(manager));

        CallbackData memory data = abi.decode(rawData, (CallbackData));
        BalanceDelta delta = manager.swap(data.key, data.params, "");

        if (delta.amount0() < 0) {
            data.key.currency0.settle(manager, data.sender, uint256(int256(-delta.amount0())), false);
        } else if (delta.amount0() > 0) {
            data.key.currency0.take(manager, data.sender, uint256(int256(delta.amount0())), false);
        }

        if (delta.amount1() < 0) {
            data.key.currency1.settle(manager, data.sender, uint256(int256(-delta.amount1())), false);
        } else if (delta.amount1() > 0) {
            data.key.currency1.take(manager, data.sender, uint256(int256(delta.amount1())), false);
        }

        return abi.encode(delta);
    }
}

contract ForexSwapAdminFeeIntegrationTest is Test {
    using PoolIdLibrary for PoolKey;

    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;

    PoolManager internal manager;
    SimplePoolSwapRouter internal swapRouter;
    ForexSwap internal hook;

    Currency internal currency0;
    Currency internal currency1;
    PoolKey internal key;
    PoolId internal poolId;

    address internal alice = address(0x1111);
    address internal attacker = address(0x3333);

    function setUp() public {
        manager = new PoolManager(address(this));
        swapRouter = new SimplePoolSwapRouter(manager);

        MockERC20 tokenA = new MockERC20("TESTA", "TA", 18);
        MockERC20 tokenB = new MockERC20("TESTB", "TB", 18);
        tokenA.mint(address(this), type(uint128).max);
        tokenB.mint(address(this), type(uint128).max);

        (currency0, currency1) = address(tokenA) < address(tokenB)
            ? (Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)))
            : (Currency.wrap(address(tokenB)), Currency.wrap(address(tokenA)));

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        hook = ForexSwap(payable(address(uint160(flags))));
        deployCodeTo("src/ForexSwap.sol:ForexSwap", abi.encode(manager), address(hook));

        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1);

        hook.addLiquidity(
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: 4e17,
                amount1Desired: 5e17,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1,
                tickLower: 0,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );
    }

    function test_adminFeeZeroDoesNotAccrueAndKeepsOutputUnchanged() external {
        uint256 amountIn = 1e16;
        uint256 grossOutput = hook.calculateAmountOut(amountIn, true);

        BalanceDelta delta = _swapExactInput(true, amountIn);

        assertEq(uint128(delta.amount1()), grossOutput);
        assertEq(hook.accruedAdminFees(poolId, key.currency1), 0);
        assertEq(hook.accruedAdminFees(poolId, key.currency0), 0);
    }

    function test_nonzeroAdminFeeReducesZeroForOneOutputAndAccruesExactAmount() external {
        uint256 amountIn = 1e16;
        hook.setAdminFee(poolId, 50);

        uint256 grossOutput = hook.calculateAmountOut(amountIn, true);
        uint256 adminFee = grossOutput * 50 / 10_000;

        BalanceDelta delta = _swapExactInput(true, amountIn);

        assertEq(uint128(delta.amount1()), grossOutput - adminFee);
        assertEq(hook.accruedAdminFees(poolId, key.currency1), adminFee);
        assertEq(hook.accruedAdminFees(poolId, key.currency0), 0);
    }

    function test_adminFeeChargesCurrency0OnOneForZeroSwap() external {
        uint256 amountIn = 1e16;
        hook.setAdminFee(poolId, 50);

        uint256 grossOutput = hook.calculateAmountOut(amountIn, false);
        uint256 adminFee = grossOutput * 50 / 10_000;

        BalanceDelta delta = _swapExactInput(false, amountIn);

        assertEq(uint128(delta.amount0()), grossOutput - adminFee);
        assertEq(hook.accruedAdminFees(poolId, key.currency0), adminFee);
        assertEq(hook.accruedAdminFees(poolId, key.currency1), 0);
    }

    function test_withdrawAdminFeesTransfersFundsAndDecrementsAccrual() external {
        uint256 amountIn = 1e16;
        hook.setAdminFee(poolId, 50);

        uint256 grossOutput = hook.calculateAmountOut(amountIn, true);
        uint256 adminFee = grossOutput * 50 / 10_000;

        _swapExactInput(true, amountIn);

        uint256 balanceBefore = MockERC20(Currency.unwrap(key.currency1)).balanceOf(alice);
        hook.withdrawAdminFees(poolId, key.currency1, alice, adminFee);

        assertEq(hook.accruedAdminFees(poolId, key.currency1), 0);
        assertEq(MockERC20(Currency.unwrap(key.currency1)).balanceOf(alice), balanceBefore + adminFee);
    }

    function test_partialThenFullWithdrawKeepsClaimsAndAccrualInSync() external {
        hook.setAdminFee(poolId, 50);

        uint256 firstGrossOutput = hook.calculateAmountOut(1e16, true);
        uint256 firstAdminFee = firstGrossOutput * 50 / 10_000;
        _swapExactInput(true, 1e16);

        uint256 secondGrossOutput = hook.calculateAmountOut(2e16, true);
        uint256 secondAdminFee = secondGrossOutput * 50 / 10_000;
        _swapExactInput(true, 2e16);

        uint256 totalAccrued = firstAdminFee + secondAdminFee;
        uint256 half = totalAccrued / 2;

        assertEq(hook.accruedAdminFees(poolId, key.currency1), totalAccrued);

        hook.withdrawAdminFees(poolId, key.currency1, alice, half);
        assertEq(hook.accruedAdminFees(poolId, key.currency1), totalAccrued - half);

        hook.withdrawAdminFees(poolId, key.currency1, alice, totalAccrued - half);
        assertEq(hook.accruedAdminFees(poolId, key.currency1), 0);
    }

    function test_withdrawAdminFeesEnforcesOwnerAccess() external {
        hook.setAdminFee(poolId, 50);
        _swapExactInput(true, 1e16);

        vm.expectRevert();
        vm.prank(attacker);
        hook.withdrawAdminFees(poolId, key.currency1, attacker, 1);
    }

    function test_withdrawAdminFeesRevertsWhenAmountExceedsAccrued() external {
        hook.setAdminFee(poolId, 50);
        _swapExactInput(true, 1e16);

        uint256 accrued = hook.accruedAdminFees(poolId, key.currency1);

        vm.expectRevert(ForexSwap.InsufficientAdminFees.selector);
        hook.withdrawAdminFees(poolId, key.currency1, alice, accrued + 1);
    }

    function test_tinySwapCanRoundAdminFeeDownToZero() external {
        hook.setAdminFee(poolId, 50);

        uint256 amountIn = _findTinyExecutableSwapAmount(true);
        uint256 grossOutput = hook.calculateAmountOut(amountIn, true);
        assertLt(grossOutput, 200);

        BalanceDelta delta = _swapExactInput(true, amountIn);

        assertEq(uint128(delta.amount1()), grossOutput);
        assertEq(hook.accruedAdminFees(poolId, key.currency1), 0);
    }

    function test_feeConservationMatchesTraderReductionAndClaimMint() external {
        uint256 amountIn = 1e16;
        hook.setAdminFee(poolId, 50);

        uint256 grossOutput = hook.calculateAmountOut(amountIn, true);
        uint256 adminFee = grossOutput * 50 / 10_000;
        uint256 traderToken1Before = MockERC20(Currency.unwrap(key.currency1)).balanceOf(address(this));

        BalanceDelta delta = _swapExactInput(true, amountIn);

        uint256 traderToken1After = MockERC20(Currency.unwrap(key.currency1)).balanceOf(address(this));

        assertEq(uint128(delta.amount1()), grossOutput - adminFee);
        assertEq(traderToken1After, traderToken1Before + grossOutput - adminFee);
        assertEq(hook.accruedAdminFees(poolId, key.currency1), adminFee);
    }

    function test_consecutiveSwapsResetCachedFeeBasis() external {
        hook.setAdminFee(poolId, 50);

        uint256 firstGrossOutput = hook.calculateAmountOut(1e16, true);
        uint256 firstAdminFee = firstGrossOutput * 50 / 10_000;
        _swapExactInput(true, 1e16);
        assertEq(hook.accruedAdminFees(poolId, key.currency1), firstAdminFee);

        uint256 secondGrossOutput = hook.calculateAmountOut(2e16, false);
        uint256 secondAdminFee = secondGrossOutput * 50 / 10_000;
        _swapExactInput(false, 2e16);

        assertEq(hook.accruedAdminFees(poolId, key.currency1), firstAdminFee);
        assertEq(hook.accruedAdminFees(poolId, key.currency0), secondAdminFee);
    }

    function test_setAdminFeeEnforcesCap() external {
        uint24 overCap = hook.MAX_ADMIN_FEE_BPS() + 1;
        vm.expectRevert(ForexSwap.FeeTooHigh.selector);
        hook.setAdminFee(poolId, overCap);
    }

    function _swapExactInput(bool zeroForOne, uint256 amountIn) internal returns (BalanceDelta) {
        return swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );
    }

    function _findTinyExecutableSwapAmount(bool zeroForOne) internal view returns (uint256 amountIn) {
        for (uint256 probe = 1; probe < 1_000; ++probe) {
            uint256 grossOutput = hook.calculateAmountOut(probe, zeroForOne);
            if (grossOutput > 0 && grossOutput < 200) return probe;
        }

        revert("no tiny executable swap found");
    }
}
