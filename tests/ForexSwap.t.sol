// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/src/Test.sol";
import {console2} from "forge-std/src/console2.sol";
import {ForexSwap} from "../src/ForexSwap.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

contract ForexSwapHarness is ForexSwap {
    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint256 internal constant STRICT_EPS = 1e9;

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

    function poolValuePerShare() external view returns (uint256) {
        if (totalSupply == 0) return 0;
        uint256 price = this.currentPrice();
        uint256 totalValueInToken1 = (poolState.reserve0 * price) / 1e18 + poolState.reserve1;
        return totalValueInToken1 / totalSupply;
    }

    function poolValuePerShareWad() external view returns (uint256) {
        if (totalSupply == 0) return 0;
        uint256 price = this.currentPrice();
        uint256 totalValueInToken1 = (poolState.reserve0 * price) / 1e18 + poolState.reserve1;
        return (totalValueInToken1 * 1e18) / totalSupply;
    }

    function symmetricLocalPriceWad() external view returns (uint256) {
        if (poolState.liquidity == 0) return 0;

        uint256 probe0 = poolState.reserve0 / 10_000;
        if (probe0 < 1e12) probe0 = 1e12;
        uint256 maxProbe0 = poolState.liquidity / 1_000;
        if (probe0 > maxProbe0) probe0 = maxProbe0;

        uint256 probe1 = poolState.reserve1 / 10_000;
        if (probe1 < 1e12) probe1 = 1e12;
        uint256 maxProbe1 = _maxReserve1(poolState.liquidity) / 1_000;
        if (probe1 > maxProbe1) probe1 = maxProbe1;

        uint256 priceBid = this.currentPrice();
        uint256 priceAsk = priceBid;

        if (probe0 > 0) {
            uint256 out1 = _quoteExactInput0For1(probe0);
            if (out1 > 0) priceBid = (out1 * 1e18) / probe0;
        }

        if (probe1 > 0) {
            uint256 out0 = _quoteExactInput1For0(probe1);
            if (out0 > 0) priceAsk = (probe1 * 1e18) / out0;
        }

        return (priceBid + priceAsk) / 2;
    }

    function symmetricLocalValuePerShareWad() external view returns (uint256) {
        if (totalSupply == 0) return 0;
        uint256 price = this.symmetricLocalPriceWad();
        uint256 totalValueInToken1 = (poolState.reserve0 * price) / 1e18 + poolState.reserve1;
        return (totalValueInToken1 * 1e18) / totalSupply;
    }

    function inStrictDomain() external view returns (bool) {
        if (poolState.liquidity == 0) return true;
        return poolState.reserve0 > 0 && poolState.reserve0 < poolState.liquidity && poolState.reserve1 > 0
            && poolState.reserve1 < (poolState.liquidity * logNormalParams.mean) / 1e18;
    }

    function simulateAddLiquidity(uint256 amount0Desired, uint256 amount1Desired, address to)
        external
        returns (uint256 amount0, uint256 amount1, uint256 shares)
    {
        AddLiquidityPlan memory plan = _planAddLiquidity(
            SQRT_PRICE_1_1,
            AddLiquidityParams({
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: 0,
                amount1Min: 0,
                to: to,
                deadline: block.timestamp + 1,
                tickLower: 0,
                tickUpper: 0,
                salt: bytes32(0)
            })
        );

        poolState.reserve0 += plan.amount0;
        poolState.reserve1 += plan.amount1;
        poolState.liquidity += plan.deltaL;
        totalSupply += plan.shares;
        balanceOf[to] += plan.shares;

        return (plan.amount0, plan.amount1, plan.shares);
    }

    function simulateRemoveLiquidity(uint256 shares, address from) external returns (uint256 amount0, uint256 amount1) {
        RemoveLiquidityPlan memory plan = _planRemoveLiquidity(shares);
        balanceOf[from] -= shares;
        totalSupply -= shares;
        poolState.reserve0 -= plan.amount0;
        poolState.reserve1 -= plan.amount1;
        poolState.liquidity -= plan.deltaL;
        return (plan.amount0, plan.amount1);
    }

    function solveReserve1(uint256 reserve0_, uint256 liquidity_) external view returns (uint256) {
        return _solveReserve1(reserve0_, liquidity_);
    }

    function solveReserve0(uint256 reserve1_, uint256 liquidity_) external view returns (uint256) {
        return _solveReserve0(reserve1_, liquidity_);
    }

    function phiInvClosure(uint256 u) external pure returns (int256) {
        return int256(_phiWad(_invPhiWad(u))) - int256(u);
    }

    function currentYOverMuL() external view returns (uint256) {
        if (poolState.liquidity == 0) return 0;
        return (poolState.reserve1 * 1e18) / _maxReserve1(poolState.liquidity);
    }

    function residualForState(uint256 reserve0_, uint256 reserve1_, uint256 liquidity_) external view returns (int256) {
        if (liquidity_ == 0) return 0;
        return _residual(reserve0_, reserve1_, liquidity_);
    }

    function strictEps() external pure returns (uint256) {
        return STRICT_EPS;
    }

    function maxReserve1ForLiquidity(uint256 liquidity_) external view returns (uint256) {
        return _maxReserve1(liquidity_);
    }

    function previewPostSwapState(uint256 amountIn, bool zeroForOne)
        external
        view
        returns (uint256 reserve0_, uint256 reserve1_, uint256 liquidity_)
    {
        PoolState memory state = poolState;
        uint256 feeAmount = FullMath.mulDiv(amountIn, logNormalParams.swapFee, 1e18);
        uint256 effectiveIn = amountIn - feeAmount;

        if (zeroForOne) {
            uint256 xAfterFee = state.reserve0 + feeAmount;
            liquidity_ = _solveLiquidityFromReserves(xAfterFee, state.reserve1);
            reserve0_ = xAfterFee + effectiveIn;
            reserve1_ = _solveReserve1(reserve0_, liquidity_);
        } else {
            uint256 yAfterFee = state.reserve1 + feeAmount;
            liquidity_ = _solveLiquidityFromReserves(state.reserve0, yAfterFee);
            reserve1_ = yAfterFee + effectiveIn;
            reserve0_ = _solveReserve0(reserve1_, liquidity_);
        }
    }

    function expWadToUint(int256 exponent) external pure returns (uint256) {
        return _expWadToUint(exponent);
    }

    function toInt256(uint256 value) external pure returns (int256) {
        return _toInt256(value);
    }
}

contract ForexSwapCorrectTest is Test {
    struct TraceState {
        uint256 reserve0;
        uint256 reserve1;
        uint256 liquidity;
        uint256 xOverL;
        uint256 yOverMuL;
        int256 residual;
        uint256 price;
        uint256 valuePerShare;
        uint256 quoted;
        uint256 xReconError;
        uint256 yReconError;
        int256 xClosureError;
        int256 yClosureError;
    }

    ForexSwapHarness internal forexSwap;
    PoolManager internal poolManager;

    address internal alice = address(0x1111);
    address internal attacker = address(0x3333);
    uint256 internal constant DOMAIN_INTERIOR_EPS = 5e16;
    uint256 internal constant INVARIANT_DRIFT_ABS_TOLERANCE = 1e2;
    uint256 internal constant INVARIANT_DRIFT_REL_TOLERANCE = 1e2;
    uint256 internal constant MULTI_SWAP_DRIFT_ABS_TOLERANCE = 1e2;
    uint256 internal constant MULTI_SWAP_DRIFT_REL_TOLERANCE = 1e2;
    uint256 internal constant ROUND_TRIP_STATE_ABS_TOLERANCE = 5e12;

    function setUp() public {
        poolManager = new PoolManager();
        bytes memory initCode = abi.encodePacked(type(ForexSwapHarness).creationCode, abi.encode(poolManager));
        bytes32 initCodeHash = keccak256(initCode);
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );

        bytes32 salt;
        for (uint256 i = 0; i < 500_000; ++i) {
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

    function test_bootstrapPlanRejectsNearZeroXRatio() external {
        vm.expectRevert(ForexSwap.DomainExceeded.selector);
        forexSwap.planBootstrap(type(uint160).max, 1e18, type(uint128).max);
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

    function test_previewExactOutputZeroForOneReturnsLeastInput() external {
        _seedBalancedPool();

        uint256 targetOut = 1e16;
        uint256 amountIn = forexSwap.previewExactOutput(targetOut, true);

        assertGe(forexSwap.quoteExactInput(amountIn, true), targetOut);
        assertLt(forexSwap.quoteExactInput(amountIn - 1, true), targetOut);
    }

    function test_previewExactOutputOneForZeroReturnsLeastInput() external {
        _seedBalancedPool();

        uint256 targetOut = 1e16;
        uint256 amountIn = forexSwap.previewExactOutput(targetOut, false);

        assertGe(forexSwap.quoteExactInput(amountIn, false), targetOut);
        assertLt(forexSwap.quoteExactInput(amountIn - 1, false), targetOut);
    }

    function test_removePlanScalesWithShares() external {
        _seedBalancedPool();

        (uint256 amount0, uint256 amount1, uint256 deltaL) = forexSwap.planRemove(5e17);
        (uint256 reserve0, uint256 reserve1, uint256 liquidityL,) = _state();

        assertEq(deltaL, 5e17);
        assertEq(amount0, reserve0 / 2);
        assertEq(amount1, reserve1 / 2);
        assertEq(deltaL, liquidityL / 2);
    }

    function test_currentInvariantIsNearZeroOnSeededState() external {
        _seedBalancedPool();
        int256 invariantValue = forexSwap.currentInvariant();
        assertApproxEqAbs(invariantValue, 0, 1e15);
    }

    function test_tailSensitiveReadsRejectNearBoundaryState() external {
        uint256 liquidityL = 1e18;
        uint256 eps = forexSwap.strictEps();
        uint256 reserve0 = liquidityL - eps;
        uint256 reserve1 = forexSwap.maxReserve1ForLiquidity(liquidityL) - eps;

        forexSwap.seedState(reserve0, reserve1, liquidityL, 1e18, alice);

        vm.expectRevert(ForexSwap.DomainExceeded.selector);
        forexSwap.currentPrice();

        vm.expectRevert(ForexSwap.DomainExceeded.selector);
        forexSwap.currentInvariant();
    }

    function test_expWadToUintRejectsExponentBelowBound() external {
        vm.expectRevert(ForexSwap.ExponentOutOfBounds.selector);
        forexSwap.expWadToUint(-20e18 - 1);
    }

    function test_expWadToUintRejectsExponentAboveBound() external {
        vm.expectRevert(ForexSwap.ExponentOutOfBounds.selector);
        forexSwap.expWadToUint(20e18 + 1);
    }

    function test_toInt256RejectsOverflow() external {
        vm.expectRevert(ForexSwap.Int256CastOverflow.selector);
        forexSwap.toInt256(uint256(type(int256).max) + 1);
    }

    function test_checkedCastsAcceptBoundaryValues() external view {
        uint256 minExp = forexSwap.expWadToUint(-20e18);
        assertGt(minExp, 0);
        assertLt(minExp, 1e18);
        assertEq(forexSwap.expWadToUint(0), 1e18);
        assertEq(forexSwap.toInt256(uint256(type(int256).max)), type(int256).max);
    }

    function test_feeAccrualDoesNotReducePoolValuePerShare_zeroForOne() external {
        _seedBalancedPool();

        uint256 beforeValuePerShare = forexSwap.poolValuePerShare();
        forexSwap.executeExactInput(1e16, true);
        uint256 afterValuePerShare = forexSwap.poolValuePerShare();

        assertGe(afterValuePerShare, beforeValuePerShare);
    }

    function test_feeAccrualDoesNotReducePoolValuePerShare_oneForZero() external {
        _seedBalancedPool();

        uint256 beforeValuePerShare = forexSwap.poolValuePerShare();
        forexSwap.executeExactInput(1e16, false);
        uint256 afterValuePerShare = forexSwap.poolValuePerShare();

        assertGe(afterValuePerShare, beforeValuePerShare);
    }

    function testFuzz_feeAccrualDoesNotReducePoolValuePerShare_zeroForOne(
        uint256 reserve0Seed,
        uint256 liquiditySeed,
        uint256 amountInSeed
    ) external {
        uint256 liquidityL = bound(liquiditySeed, 5e17, 5e18);
        uint256 reserve0 = bound(reserve0Seed, liquidityL / 10, (liquidityL * 8) / 10);
        uint256 amountIn = bound(amountInSeed, 1e15, liquidityL / 50);

        forexSwap.seedConsistentState(reserve0, liquidityL, 1e18, alice);

        uint256 beforeValuePerShare = forexSwap.poolValuePerShare();
        uint256 quoted = forexSwap.quoteExactInput(amountIn, true);
        vm.assume(quoted > 0);

        forexSwap.executeExactInput(amountIn, true);
        uint256 afterValuePerShare = forexSwap.poolValuePerShare();

        assertGe(afterValuePerShare + 1, beforeValuePerShare);
    }

    function testFuzz_feeAccrualDoesNotReducePoolValuePerShare_oneForZero(
        uint256 reserve0Seed,
        uint256 liquiditySeed,
        uint256 amountInSeed
    ) external {
        uint256 liquidityL = bound(liquiditySeed, 5e17, 5e18);
        uint256 reserve0 = bound(reserve0Seed, liquidityL / 10, (liquidityL * 8) / 10);
        uint256 amountIn = bound(amountInSeed, 1e15, liquidityL / 50);

        forexSwap.seedConsistentState(reserve0, liquidityL, 1e18, alice);

        uint256 beforeValuePerShare = forexSwap.poolValuePerShare();
        uint256 quoted = forexSwap.quoteExactInput(amountIn, false);
        vm.assume(quoted > 0);

        forexSwap.executeExactInput(amountIn, false);
        uint256 afterValuePerShare = forexSwap.poolValuePerShare();

        assertGe(afterValuePerShare + 1, beforeValuePerShare);
    }

    function testFuzz_previewExactOutputZeroForOneReturnsLeastInput(
        uint256 reserve0Seed,
        uint256 liquiditySeed,
        uint256 amountInSeed
    ) external {
        uint256 liquidityL = bound(liquiditySeed, 5e17, 5e18);
        uint256 reserve0 = bound(reserve0Seed, liquidityL / 10, (liquidityL * 8) / 10);
        forexSwap.seedConsistentState(reserve0, liquidityL, 1e18, alice);

        uint256 quotedOut = forexSwap.quoteExactInput(bound(amountInSeed, 1e15, liquidityL / 50), true);
        vm.assume(quotedOut > 1);

        uint256 targetOut = bound(amountInSeed >> 16, 1, quotedOut - 1);
        try forexSwap.previewExactOutput(targetOut, true) returns (uint256 amountIn) {
            assertGe(forexSwap.quoteExactInput(amountIn, true), targetOut);
            assertLt(forexSwap.quoteExactInput(amountIn - 1, true), targetOut);
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), ForexSwap.NonMonotonicQuote.selector);
        }
    }

    function testFuzz_previewExactOutputOneForZeroReturnsLeastInput(
        uint256 reserve0Seed,
        uint256 liquiditySeed,
        uint256 amountInSeed
    ) external {
        uint256 liquidityL = bound(liquiditySeed, 5e17, 5e18);
        uint256 reserve0 = bound(reserve0Seed, liquidityL / 10, (liquidityL * 8) / 10);
        forexSwap.seedConsistentState(reserve0, liquidityL, 1e18, alice);

        uint256 quotedOut = forexSwap.quoteExactInput(bound(amountInSeed, 1e15, liquidityL / 50), false);
        vm.assume(quotedOut > 1);

        uint256 targetOut = bound(amountInSeed >> 16, 1, quotedOut - 1);
        try forexSwap.previewExactOutput(targetOut, false) returns (uint256 amountIn) {
            assertGe(forexSwap.quoteExactInput(amountIn, false), targetOut);
            assertLt(forexSwap.quoteExactInput(amountIn - 1, false), targetOut);
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), ForexSwap.NonMonotonicQuote.selector);
        }
    }

    function testFuzz_repeatedSwapsPreserveDomainInvariantAndClosure(
        uint256 reserve0Seed,
        uint256 liquiditySeed,
        uint256 randomness
    ) external {
        uint256 liquidityL = bound(liquiditySeed, 1e18, 8e18);
        uint256 reserve0 = bound(reserve0Seed, liquidityL / 8, (liquidityL * 7) / 10);
        forexSwap.seedConsistentState(reserve0, liquidityL, 1e18, alice);

        uint256 stateRand = randomness;
        uint256 steps = 5 + (stateRand % 16);

        for (uint256 i = 0; i < steps; ++i) {
            stateRand = uint256(keccak256(abi.encode(stateRand, i)));
            bool zeroForOne = (stateRand & 1) == 0;

            (, , uint256 currentLiquidity,) = _state();
            uint256 amountIn = bound(stateRand >> 8, 1e15, currentLiquidity / 40);

            try forexSwap.quoteExactInput(amountIn, zeroForOne) returns (uint256 quoted) {
                if (quoted == 0) continue;
            } catch {
                continue;
            }

            forexSwap.executeExactInput(amountIn, zeroForOne);

            assertTrue(forexSwap.inStrictDomain());
            assertApproxEqAbs(forexSwap.currentInvariant(), 0, 2e16);
        }
    }

    function testFuzz_singleSwapInvariantDriftStaysWithinTolerance(
        uint256 reserve0Seed,
        uint256 liquiditySeed,
        uint256 amountInSeed,
        bool zeroForOne
    ) external {
        uint256 liquidityL = bound(liquiditySeed, 1e18, 8e18);
        uint256 reserve0 = bound(reserve0Seed, liquidityL / 8, (liquidityL * 7) / 10);
        uint256 amountIn = bound(amountInSeed, 1e15, liquidityL / 50);
        forexSwap.seedConsistentState(reserve0, liquidityL, 1e18, alice);
        _assumeInteriorState();

        uint256 quoted;
        try forexSwap.quoteExactInput(amountIn, zeroForOne) returns (uint256 q) {
            quoted = q;
        } catch {
            return;
        }

        vm.assume(quoted > 0);

        int256 invariantBefore = forexSwap.currentInvariant();
        forexSwap.executeExactInput(amountIn, zeroForOne);
        int256 invariantAfter = forexSwap.currentInvariant();

        assertTrue(forexSwap.inStrictDomain());
        _assertInvariantDriftWithinTolerance(
            invariantBefore, invariantAfter, INVARIANT_DRIFT_ABS_TOLERANCE, INVARIANT_DRIFT_REL_TOLERANCE
        );
    }

    function testFuzz_repeatedSwapInvariantDriftStaysBounded(
        uint256 reserve0Seed,
        uint256 liquiditySeed,
        uint256 randomness
    ) external {
        uint256 liquidityL = bound(liquiditySeed, 1e18, 8e18);
        uint256 reserve0 = bound(reserve0Seed, liquidityL / 8, (liquidityL * 7) / 10);
        forexSwap.seedConsistentState(reserve0, liquidityL, 1e18, alice);
        _assumeInteriorState();

        int256 invariantStart = forexSwap.currentInvariant();
        uint256 stateRand = randomness;
        uint256 steps = 5 + (stateRand % 16);

        for (uint256 i = 0; i < steps; ++i) {
            stateRand = uint256(keccak256(abi.encode(stateRand, i)));
            bool zeroForOne = (stateRand & 1) == 0;

            (, , uint256 currentLiquidity,) = _state();
            uint256 amountIn = bound(stateRand >> 8, 1e15, currentLiquidity / 40);

            uint256 quoted;
            try forexSwap.quoteExactInput(amountIn, zeroForOne) returns (uint256 q) {
                quoted = q;
            } catch {
                continue;
            }
            if (quoted == 0) continue;

            int256 invariantBefore = forexSwap.currentInvariant();
            forexSwap.executeExactInput(amountIn, zeroForOne);
            int256 invariantAfter = forexSwap.currentInvariant();

            assertTrue(forexSwap.inStrictDomain());
            _assumeInteriorState();
            _assertInvariantDriftWithinTolerance(
                invariantBefore, invariantAfter, INVARIANT_DRIFT_ABS_TOLERANCE, INVARIANT_DRIFT_REL_TOLERANCE
            );
        }

        _assertInvariantDriftWithinTolerance(
            invariantStart, forexSwap.currentInvariant(), MULTI_SWAP_DRIFT_ABS_TOLERANCE, MULTI_SWAP_DRIFT_REL_TOLERANCE
        );
    }

    function testFuzz_previewAndExecuteInvariantDriftStayConsistent(
        uint256 reserve0Seed,
        uint256 liquiditySeed,
        uint256 amountInSeed,
        bool zeroForOne
    ) external {
        uint256 liquidityL = bound(liquiditySeed, 1e18, 8e18);
        uint256 reserve0 = bound(reserve0Seed, liquidityL / 8, (liquidityL * 7) / 10);
        uint256 amountIn = bound(amountInSeed, 1e15, liquidityL / 50);
        forexSwap.seedConsistentState(reserve0, liquidityL, 1e18, alice);
        _assumeInteriorState();

        uint256 quoted;
        try forexSwap.quoteExactInput(amountIn, zeroForOne) returns (uint256 q) {
            quoted = q;
        } catch {
            return;
        }
        vm.assume(quoted > 0);

        int256 invariantBefore = forexSwap.currentInvariant();
        (uint256 previewReserve0, uint256 previewReserve1, uint256 previewLiquidity) =
            forexSwap.previewPostSwapState(amountIn, zeroForOne);
        int256 previewInvariantAfter = forexSwap.residualForState(previewReserve0, previewReserve1, previewLiquidity);

        forexSwap.executeExactInput(amountIn, zeroForOne);
        int256 actualInvariantAfter = forexSwap.currentInvariant();

        assertTrue(forexSwap.inStrictDomain());
        _assertInvariantDriftWithinTolerance(
            previewInvariantAfter, actualInvariantAfter, INVARIANT_DRIFT_ABS_TOLERANCE, INVARIANT_DRIFT_REL_TOLERANCE
        );
        assertLe(
            _absDiffInt(invariantBefore, actualInvariantAfter),
            _absDiffInt(invariantBefore, previewInvariantAfter) + INVARIANT_DRIFT_ABS_TOLERANCE
        );
    }

    function testFuzz_roundTripSwapReturnsStateNearBaseline(
        uint256 reserve0Seed,
        uint256 liquiditySeed,
        uint256 amountInSeed,
        bool zeroForOne
    ) external {
        uint256 liquidityL = bound(liquiditySeed, 1e18, 8e18);
        uint256 reserve0 = bound(reserve0Seed, liquidityL / 8, (liquidityL * 7) / 10);
        forexSwap.seedConsistentState(reserve0, liquidityL, 1e18, alice);
        _assumeInteriorState();

        (uint256 mean, uint256 sigma,) = forexSwap.logNormalParams();
        forexSwap.updateLogNormalParams(mean, sigma, 0);

        (, , uint256 baseLiquidity,) = _state();
        uint256 amountIn = bound(amountInSeed, 1e15, baseLiquidity / 50);
        try forexSwap.quoteExactInput(amountIn, zeroForOne) returns (uint256 quoted) {
            vm.assume(quoted > 0);
        } catch {
            return;
        }
        uint256[3] memory baseline;
        (baseline[0], baseline[1], baseline[2],) = _state();
        int256 invariantBefore = forexSwap.currentInvariant();

        forexSwap.executeExactInput(amountIn, zeroForOne);

        uint256 unwindInput;
        try forexSwap.previewExactOutput(amountIn, !zeroForOne) returns (uint256 previewedInput) {
            unwindInput = previewedInput;
        } catch {
            return;
        }
        vm.assume(unwindInput > 0);
        uint256 unwindOutput = forexSwap.executeExactInput(unwindInput, !zeroForOne);
        assertGe(unwindOutput, amountIn);
        _assertRoundTripNearBaseline(baseline, invariantBefore);
    }

    function test_invariantTelemetryLogsWorstObservedDrift() external {
        uint256[4] memory reserve0Seeds = [uint256(2e17), 35e16, 5e17, 65e16];
        uint256[4] memory liquiditySeeds = [uint256(1e18), 2e18, 4e18, 8e18];

        uint256 maxStepDrift;
        uint256 maxCumulativeDrift;
        uint256 maxPreviewGap;

        for (uint256 scenario = 0; scenario < reserve0Seeds.length; ++scenario) {
            forexSwap.seedConsistentState(reserve0Seeds[scenario], liquiditySeeds[scenario], 1e18, alice);
            assertTrue(_isInteriorState());

            int256 invariantStart = forexSwap.currentInvariant();
            uint256 stateRand = uint256(keccak256(abi.encode(scenario, reserve0Seeds[scenario], liquiditySeeds[scenario])));
            uint256 steps = 20;

            for (uint256 i = 0; i < steps; ++i) {
                stateRand = uint256(keccak256(abi.encode(stateRand, i)));
                bool zeroForOne = (stateRand & 1) == 0;

                (, , uint256 currentLiquidity,) = _state();
                uint256 amountIn = bound(stateRand >> 8, 1e15, currentLiquidity / 40);
                (bool executed, uint256 stepDrift, uint256 cumulativeDrift, uint256 previewGap) =
                    _executeSwapAndMeasure(amountIn, zeroForOne, invariantStart);
                if (!executed) continue;

                if (stepDrift > maxStepDrift) maxStepDrift = stepDrift;
                if (cumulativeDrift > maxCumulativeDrift) maxCumulativeDrift = cumulativeDrift;
                if (previewGap > maxPreviewGap) maxPreviewGap = previewGap;

                assertTrue(forexSwap.inStrictDomain());
                if (!_isInteriorState()) break;
            }
        }

        console2.log("maxStepDrift", maxStepDrift);
        console2.log("maxCumulativeDrift", maxCumulativeDrift);
        console2.log("maxPreviewExecuteGap", maxPreviewGap);
    }

    function testFuzz_addRemoveRoundTripDoesNotCreateValue(
        uint256 reserve0Seed,
        uint256 liquiditySeed,
        uint256 addSeed
    ) external {
        uint256 liquidityL = bound(liquiditySeed, 1e18, 8e18);
        uint256 reserve0 = bound(reserve0Seed, liquidityL / 8, (liquidityL * 7) / 10);
        forexSwap.seedConsistentState(reserve0, liquidityL, 1e18, alice);

        (uint256 startReserve0, uint256 startReserve1,,) = _state();
        uint256 add0 = bound(addSeed, 1e15, startReserve0 / 20);
        uint256 add1 = (startReserve1 * add0) / startReserve0;

        uint256 startPrice = forexSwap.currentPrice();
        (uint256 spent0, uint256 spent1, uint256 shares) = forexSwap.simulateAddLiquidity(add0, add1, attacker);
        (uint256 out0, uint256 out1) = forexSwap.simulateRemoveLiquidity(shares, attacker);

        uint256 spentValue = (spent0 * startPrice) / 1e18 + spent1;
        uint256 receivedValue = (out0 * startPrice) / 1e18 + out1;

        assertLe(receivedValue, spentValue + 1e12);
        assertTrue(forexSwap.inStrictDomain());
    }

    function testFuzz_swapAddSwapRemoveCycleDoesNotCreateLargeWindfall(
        uint256 reserve0Seed,
        uint256 liquiditySeed,
        uint256 swapSeed1,
        uint256 addSeed,
        uint256 swapSeed2
    ) external {
        uint256 liquidityL = bound(liquiditySeed, 1e18, 8e18);
        uint256 reserve0 = bound(reserve0Seed, liquidityL / 8, (liquidityL * 7) / 10);
        forexSwap.seedConsistentState(reserve0, liquidityL, 1e18, alice);

        {
            bool firstZeroForOne = (swapSeed1 & 1) == 0;
            uint256 firstAmountIn = bound(swapSeed1 >> 8, 1e15, liquidityL / 50);
            try forexSwap.quoteExactInput(firstAmountIn, firstZeroForOne) returns (uint256 quoted1) {
                vm.assume(quoted1 > 0);
                forexSwap.executeExactInput(firstAmountIn, firstZeroForOne);
            } catch {
                return;
            }
        }

        (uint256 reserve0AfterFirst, uint256 reserve1AfterFirst,,) = _state();
        uint256 add0 = bound(addSeed, 1e15, reserve0AfterFirst / 25);
        uint256 add1 = (reserve1AfterFirst * add0) / reserve0AfterFirst;
        (uint256 spent0, uint256 spent1, uint256 shares) = forexSwap.simulateAddLiquidity(add0, add1, attacker);

        bool secondZeroForOne = (swapSeed2 & 1) == 0;
        uint256 secondAmountIn;
        uint256 beforeSecondPrice = forexSwap.currentPrice();
        {
            (, , uint256 liqBeforeSecond,) = _state();
            secondAmountIn = bound(swapSeed2 >> 8, 1e15, liqBeforeSecond / 50);
            try forexSwap.quoteExactInput(secondAmountIn, secondZeroForOne) returns (uint256 quoted2) {
                vm.assume(quoted2 > 0);
                forexSwap.executeExactInput(secondAmountIn, secondZeroForOne);
            } catch {
                return;
            }
        }

        (uint256 out0, uint256 out1) = forexSwap.simulateRemoveLiquidity(shares, attacker);
        uint256 finalPrice = forexSwap.currentPrice();
        (, , uint256 swapFee) = forexSwap.logNormalParams();

        uint256 spentValue = (spent0 * finalPrice) / 1e18 + spent1;
        uint256 receivedValue = (out0 * finalPrice) / 1e18 + out1;
        uint256 feeUpperBound =
            secondZeroForOne ? (secondAmountIn * beforeSecondPrice * swapFee) / 1e36 : (secondAmountIn * swapFee) / 1e18;

        assertLe(receivedValue, spentValue + feeUpperBound + 5e12);
        assertTrue(forexSwap.inStrictDomain());
    }

    function test_reserveSolveSelfConsistency() external {
        uint256 liquidityL = 1e18;
        uint256[5] memory xs = [uint256(2e17), 3e17, 4e17, 5e17, 6e17];
        for (uint256 i = 0; i < xs.length; ++i) {
            uint256 y = forexSwap.solveReserve1(xs[i], liquidityL);
            uint256 x2 = forexSwap.solveReserve0(y, liquidityL);
            assertApproxEqAbs(x2, xs[i], 10);
        }

        uint256 reserve0 = 4e17;
        uint256 reserve1 = forexSwap.solveReserve1(reserve0, liquidityL);
        uint256[5] memory ys = [reserve1 / 2, (reserve1 * 3) / 4, reserve1, (reserve1 * 5) / 4, (reserve1 * 3) / 2];
        for (uint256 i = 0; i < ys.length; ++i) {
            uint256 x = forexSwap.solveReserve0(ys[i], liquidityL);
            uint256 y2 = forexSwap.solveReserve1(x, liquidityL);
            assertApproxEqAbs(y2, ys[i], 10);
        }
    }

    function test_priceMatchesFiniteDifferenceSlope() external {
        uint256 liquidityL = 1e18;
        uint256 reserve0 = 4e17;
        forexSwap.seedConsistentState(reserve0, liquidityL, 1e18, alice);

        uint256 dx = 1e12;
        uint256 price = forexSwap.currentPrice();
        uint256 yBefore = forexSwap.solveReserve1(reserve0, liquidityL);
        uint256 yAfter = forexSwap.solveReserve1(reserve0 + dx, liquidityL);
        uint256 slope = ((yBefore - yAfter) * 1e18) / dx;

        assertApproxEqRel(slope, price, 5e15);
    }

    function test_quoteExecuteIdentityOnFrozenState() external {
        _seedBalancedPool();
        uint256 amountIn = 1e16;
        uint256 quote = forexSwap.quoteExactInput(amountIn, true);

        (uint256 beforeReserve0, uint256 beforeReserve1, uint256 beforeLiquidity,) = _state();
        uint256 executed = forexSwap.executeExactInput(amountIn, true);
        assertEq(executed, quote);

        (uint256 afterReserve0, uint256 afterReserve1, uint256 afterLiquidity,) = _state();
        assertEq(afterReserve0, beforeReserve0 + amountIn);
        assertLt(afterReserve1, beforeReserve1);
        assertGe(afterLiquidity, beforeLiquidity);
    }

    function test_traceKnownFailingRepeatedSwapSequence() external {
        uint256 liquidityL = 1e18;
        uint256 reserve0 = 707110000000000000;
        uint256 randomness = 15627;

        forexSwap.seedConsistentState(reserve0, liquidityL, 1e18, alice);

        uint256 stateRand = randomness;
        uint256 steps = 5 + (stateRand % 16);
        (uint256 mean,,) = forexSwap.logNormalParams();

        for (uint256 i = 0; i < steps; ++i) {
            stateRand = uint256(keccak256(abi.encode(stateRand, i)));
            bool zeroForOne = (stateRand & 1) == 0;
            (, , uint256 currentLiquidity,) = _state();
            uint256 amountIn = bound(stateRand >> 8, 1e15, currentLiquidity / 40);

            uint256 quoted;
            try forexSwap.quoteExactInput(amountIn, zeroForOne) returns (uint256 q) {
                quoted = q;
            } catch {
                console2.log("step", i, "quote reverted");
                continue;
            }
            if (quoted == 0) {
                console2.log("step", i, "zero quote");
                continue;
            }

            TraceState memory beforeState;
            (beforeState.reserve0, beforeState.reserve1, beforeState.liquidity,) = _state();
            beforeState.xOverL = (beforeState.reserve0 * 1e18) / beforeState.liquidity;
            beforeState.yOverMuL = (beforeState.reserve1 * 1e18) / ((mean * beforeState.liquidity) / 1e18);
            beforeState.residual = forexSwap.currentInvariant();
            beforeState.price = forexSwap.currentPrice();
            beforeState.valuePerShare = forexSwap.poolValuePerShareWad();
            beforeState.quoted = quoted;
            {
                uint256 y1 = forexSwap.solveReserve1(beforeState.reserve0, beforeState.liquidity);
                uint256 x2 = forexSwap.solveReserve0(y1, beforeState.liquidity);
                uint256 x1 = forexSwap.solveReserve0(beforeState.reserve1, beforeState.liquidity);
                uint256 y2 = forexSwap.solveReserve1(x1, beforeState.liquidity);
                beforeState.xReconError =
                    x2 > beforeState.reserve0 ? x2 - beforeState.reserve0 : beforeState.reserve0 - x2;
                beforeState.yReconError =
                    y2 > beforeState.reserve1 ? y2 - beforeState.reserve1 : beforeState.reserve1 - y2;
            }
            beforeState.xClosureError = forexSwap.phiInvClosure(beforeState.xOverL);
            beforeState.yClosureError = forexSwap.phiInvClosure(beforeState.yOverMuL);

            uint256 executed = forexSwap.executeExactInput(amountIn, zeroForOne);
            (uint256 r0After, uint256 r1After, uint256 lAfter,) = _state();
            int256 residualAfter = forexSwap.currentInvariant();
            uint256 vpsAfter = forexSwap.poolValuePerShareWad();

            console2.log("--- step ---", i);
            console2.log("dir", zeroForOne ? 0 : 1);
            console2.log("reserve0", beforeState.reserve0);
            console2.log("reserve1", beforeState.reserve1);
            console2.log("liquidity", beforeState.liquidity);
            console2.log("xOverL", beforeState.xOverL);
            console2.log("yOverMuL", beforeState.yOverMuL);
            console2.logInt(beforeState.residual);
            console2.log("price", beforeState.price);
            console2.log("valuePerShareWad", beforeState.valuePerShare);
            console2.log("quoted", beforeState.quoted);
            console2.log("executed", executed);
            console2.log("x-reconstruct-error", beforeState.xReconError);
            console2.log("y-reconstruct-error", beforeState.yReconError);
            console2.logInt(beforeState.xClosureError);
            console2.logInt(beforeState.yClosureError);
            console2.log("reserve0 after", r0After);
            console2.log("reserve1 after", r1After);
            console2.log("liquidity after", lAfter);
            console2.logInt(residualAfter);
            console2.log("valuePerShareWad after", vpsAfter);
        }
    }

    function test_traceKnownFailingSequence_GaussianClosure() external {
        uint256 liquidityL = 1e18;
        uint256 reserve0 = 707110000000000000;
        uint256 randomness = 15627;

        forexSwap.seedConsistentState(reserve0, liquidityL, 1e18, alice);

        uint256 stateRand = randomness;
        uint256 steps = 5 + (stateRand % 16);
        uint256 maxClosure;

        for (uint256 i = 0; i < steps; ++i) {
            stateRand = uint256(keccak256(abi.encode(stateRand, i)));
            bool zeroForOne = (stateRand & 1) == 0;
            (, , uint256 currentLiquidity,) = _state();
            uint256 amountIn = bound(stateRand >> 8, 1e15, currentLiquidity / 40);

            uint256 quote;
            try forexSwap.quoteExactInput(amountIn, zeroForOne) returns (uint256 q) {
                quote = q;
            } catch {
                continue;
            }
            if (quote == 0) continue;

            (uint256 r0, uint256 r1, uint256 l,) = _state();
            (uint256 mean,,) = forexSwap.logNormalParams();
            uint256 ux = (r0 * 1e18) / l;
            uint256 uy = (r1 * 1e18) / ((mean * l) / 1e18);

            uint256 errX = _absInt(forexSwap.phiInvClosure(ux));
            uint256 errY = _absInt(forexSwap.phiInvClosure(uy));
            uint256 closure = errX + errY;
            if (closure > maxClosure) maxClosure = closure;

            console2.log("step", i);
            console2.log("closure", closure);
            console2.log("errX", errX);
            console2.log("errY", errY);
            forexSwap.executeExactInput(amountIn, zeroForOne);
        }

        console2.log("maxClosure", maxClosure);
    }

    function test_knownFailingSequence_compareSpotValueVsSymmetricLocalValue() external {
        uint256 liquidityL = 1e18;
        uint256 reserve0 = 707110000000000000;
        uint256 randomness = 15627;

        forexSwap.seedConsistentState(reserve0, liquidityL, 1e18, alice);

        uint256 stateRand = randomness;
        uint256 steps = 5 + (stateRand % 16);

        for (uint256 i = 0; i < steps; ++i) {
            stateRand = uint256(keccak256(abi.encode(stateRand, i)));
            bool zeroForOne = (stateRand & 1) == 0;
            (, , uint256 currentLiquidity,) = _state();
            uint256 amountIn = bound(stateRand >> 8, 1e15, currentLiquidity / 40);

            uint256 quote;
            try forexSwap.quoteExactInput(amountIn, zeroForOne) returns (uint256 q) {
                quote = q;
            } catch {
                continue;
            }
            if (quote == 0) continue;

            uint256 spotBefore = forexSwap.poolValuePerShareWad();
            uint256 localBefore = forexSwap.symmetricLocalValuePerShareWad();
            forexSwap.executeExactInput(amountIn, zeroForOne);
            uint256 spotAfter = forexSwap.poolValuePerShareWad();
            uint256 localAfter = forexSwap.symmetricLocalValuePerShareWad();

            console2.log("step", i);
            console2.log("spotBefore", spotBefore);
            console2.log("spotAfter", spotAfter);
            console2.log("localBefore", localBefore);
            console2.log("localAfter", localAfter);
        }
    }

    function test_knownFailingSequenceHasNoClosureSpikes() external {
        uint256 liquidityL = 1e18;
        uint256 reserve0 = 707110000000000000;
        uint256 randomness = 15627;

        forexSwap.seedConsistentState(reserve0, liquidityL, 1e18, alice);

        uint256 stateRand = randomness;
        uint256 steps = 5 + (stateRand % 16);

        for (uint256 i = 0; i < steps; ++i) {
            stateRand = uint256(keccak256(abi.encode(stateRand, i)));
            bool zeroForOne = (stateRand & 1) == 0;
            (, , uint256 currentLiquidity,) = _state();
            uint256 amountIn = bound(stateRand >> 8, 1e15, currentLiquidity / 40);

            uint256 quote;
            try forexSwap.quoteExactInput(amountIn, zeroForOne) returns (uint256 q) {
                quote = q;
            } catch {
                continue;
            }
            if (quote == 0) continue;

            assertEq(_currentClosureMagnitude(), 0);
            forexSwap.executeExactInput(amountIn, zeroForOne);
            assertTrue(forexSwap.inStrictDomain());
            assertApproxEqAbs(forexSwap.currentInvariant(), 0, 2e16);
            assertEq(_currentClosureMagnitude(), 0);
        }
    }

    function test_closureSweep_yBranch() external {
        uint256 start = 20e16;
        uint256 end = 29e16;
        uint256 step = 5e14;

        uint256 maxErr;
        uint256 first1e3;
        uint256 first1e4;
        uint256 first1e5;
        uint256 first1e6;

        for (uint256 u = start; u <= end; u += step) {
            uint256 err = _absInt(forexSwap.phiInvClosure(u));
            if (err > maxErr) maxErr = err;

            if (first1e3 == 0 && err > 1e3) first1e3 = u;
            if (first1e4 == 0 && err > 1e4) first1e4 = u;
            if (first1e5 == 0 && err > 1e5) first1e5 = u;
            if (first1e6 == 0 && err > 1e6) first1e6 = u;
        }

        console2.log("maxErr", maxErr);
        console2.log("first>1e3", first1e3);
        console2.log("first>1e4", first1e4);
        console2.log("first>1e5", first1e5);
        console2.log("first>1e6", first1e6);
    }

    function test_knownFailingSequencePreservesDomainInvariantAndClosure() external {
        uint256 liquidityL = 1e18;
        uint256 reserve0 = 707110000000000000;
        uint256 randomness = 15627;

        forexSwap.seedConsistentState(reserve0, liquidityL, 1e18, alice);

        uint256 stateRand = randomness;
        uint256 steps = 5 + (stateRand % 16);

        for (uint256 i = 0; i < steps; ++i) {
            stateRand = uint256(keccak256(abi.encode(stateRand, i)));
            bool zeroForOne = (stateRand & 1) == 0;
            (, , uint256 currentLiquidity,) = _state();
            uint256 amountIn = bound(stateRand >> 8, 1e15, currentLiquidity / 40);

            uint256 quote;
            try forexSwap.quoteExactInput(amountIn, zeroForOne) returns (uint256 q) {
                quote = q;
            } catch {
                continue;
            }
            if (quote == 0) continue;

            forexSwap.executeExactInput(amountIn, zeroForOne);
            assertTrue(forexSwap.inStrictDomain());
            assertApproxEqAbs(forexSwap.currentInvariant(), 0, 2e16);
            assertEq(_currentClosureMagnitude(), 0);
        }
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

    function _currentClosureMagnitude() internal view returns (uint256) {
        (uint256 r0, uint256 r1, uint256 l,) = _state();
        (uint256 mean,,) = forexSwap.logNormalParams();
        uint256 ux = (r0 * 1e18) / l;
        uint256 uy = (r1 * 1e18) / ((mean * l) / 1e18);
        return _absInt(forexSwap.phiInvClosure(ux)) + _absInt(forexSwap.phiInvClosure(uy));
    }

    function _assumeInteriorState() internal view {
        vm.assume(_isInteriorState());
    }

    function _isInteriorState() internal view returns (bool) {
        (uint256 reserve0, uint256 reserve1, uint256 liquidityL,) = _state();
        (uint256 mean,,) = forexSwap.logNormalParams();
        uint256 xOverL = (reserve0 * 1e18) / liquidityL;
        uint256 yOverMuL = (reserve1 * 1e18) / ((mean * liquidityL) / 1e18);

        return xOverL > DOMAIN_INTERIOR_EPS && xOverL < 1e18 - DOMAIN_INTERIOR_EPS && yOverMuL > DOMAIN_INTERIOR_EPS
            && yOverMuL < 1e18 - DOMAIN_INTERIOR_EPS;
    }

    function _assertInvariantDriftWithinTolerance(int256 beforeValue, int256 afterValue, uint256 absTol, uint256 relTol)
        internal
        pure
    {
        uint256 diff = _absDiffInt(beforeValue, afterValue);
        if (diff <= absTol) return;

        uint256 scale = _maxUint(_absInt(beforeValue), 1e18);
        assertLe(diff, FullMath.mulDiv(relTol, scale, 1e18));
    }

    function _assertRoundTripNearBaseline(uint256[3] memory baseline, int256 invariantBefore) internal view {
        (uint256 reserve0After, uint256 reserve1After, uint256 liquidityAfter,) = _state();
        int256 invariantAfter = forexSwap.currentInvariant();

        assertTrue(forexSwap.inStrictDomain());
        assertLe(_absDiffUint(baseline[0], reserve0After), ROUND_TRIP_STATE_ABS_TOLERANCE);
        assertLe(_absDiffUint(baseline[1], reserve1After), ROUND_TRIP_STATE_ABS_TOLERANCE);
        assertLe(_absDiffUint(baseline[2], liquidityAfter), ROUND_TRIP_STATE_ABS_TOLERANCE);
        _assertInvariantDriftWithinTolerance(
            invariantBefore, invariantAfter, INVARIANT_DRIFT_ABS_TOLERANCE, INVARIANT_DRIFT_REL_TOLERANCE
        );
    }

    function _executeSwapAndMeasure(uint256 amountIn, bool zeroForOne, int256 invariantStart)
        internal
        returns (bool executed, uint256 stepDrift, uint256 cumulativeDrift, uint256 previewGap)
    {
        uint256 quoted;
        try forexSwap.quoteExactInput(amountIn, zeroForOne) returns (uint256 q) {
            quoted = q;
        } catch {
            return (false, 0, 0, 0);
        }
        if (quoted == 0) return (false, 0, 0, 0);

        int256 invariantBefore = forexSwap.currentInvariant();
        (uint256 previewReserve0, uint256 previewReserve1, uint256 previewLiquidity) =
            forexSwap.previewPostSwapState(amountIn, zeroForOne);
        int256 previewInvariantAfter = forexSwap.residualForState(previewReserve0, previewReserve1, previewLiquidity);

        forexSwap.executeExactInput(amountIn, zeroForOne);
        int256 actualInvariantAfter = forexSwap.currentInvariant();

        stepDrift = _absDiffInt(invariantBefore, actualInvariantAfter);
        cumulativeDrift = _absDiffInt(invariantStart, actualInvariantAfter);
        previewGap = _absDiffInt(previewInvariantAfter, actualInvariantAfter);
        return (true, stepDrift, cumulativeDrift, previewGap);
    }

    function _absInt(int256 value) internal pure returns (uint256) {
        return uint256(value >= 0 ? value : -value);
    }

    function _absDiffInt(int256 a, int256 b) internal pure returns (uint256) {
        return a >= b ? _absInt(a - b) : _absInt(b - a);
    }

    function _maxUint(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? a : b;
    }

    function _absDiffUint(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? a - b : b - a;
    }
}
