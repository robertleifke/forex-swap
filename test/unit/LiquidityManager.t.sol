// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console2} from "forge-std/Test.sol";
import {RMM, upscale, downscaleDown, scalar, sum, abs, PoolPreCompute} from "../../src/RMM.sol";
import {LiquidityManager, RMM} from "../../src/LiquidityManager.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {IPMarket} from "pendle/interfaces/IPMarket.sol";
import "pendle/core/Market/MarketMathCore.sol";
import "pendle/interfaces/IPAllActionV3.sol";
import {IPPrincipalToken} from "pendle/interfaces/IPPrincipalToken.sol";
import {IStandardizedYield} from "pendle/interfaces/IStandardizedYield.sol";
import {IPYieldToken} from "pendle/interfaces/IPYieldToken.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

IPAllActionV3 constant router = IPAllActionV3(0x00000000005BBB0EF59571E58418F9a4357b68A0);
IPMarket constant market = IPMarket(0x9eC4c502D989F04FfA9312C9D6E3F872EC91A0F9);
address constant wstETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0; //real wsteth
address constant WETH_ADDRESS = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

uint256 constant eps = 0.005 ether;

uint256 constant impliedRateTime = 365 * 86400;

contract ForkRMMTest is Test {
    using MarketMathCore for MarketState;
    using MarketMathCore for int256;
    using MarketMathCore for uint256;
    using FixedPointMathLib for uint256;
    using FixedPointMathLib for int256;
    using PYIndexLib for IPYieldToken;
    using PYIndexLib for PYIndex;
    using MarketApproxPtInLib for MarketState;

    RMM public __subject__;
    LiquidityManager public __liquidityManager__;
    MockERC20 public tokenX;
    MockERC20 public tokenY;

    IStandardizedYield public SY;
    IPPrincipalToken public PT;
    IPYieldToken public YT;

    uint256 timeToExpiry;

    function setUp() public {
        vm.createSelectFork({urlOrAlias: "mainnet", blockNumber: 17_162_783});

        __liquidityManager__ = new LiquidityManager();

        vm.label(address(__subject__), "RMM");
        (SY, PT, YT) = IPMarket(market).readTokens();
        __subject__ = new RMM("LPToken", "LPT", address(PT), 0.025 ether, 0.0003 ether);
        (MarketState memory ms,) = getPendleMarketData();
        timeToExpiry = ms.expiry - block.timestamp;

        deal(wstETH, address(this), 1_000_000e18);

        mintSY(100_000 ether);
        mintPtYt(50_000 ether);

        IERC20(wstETH).approve(address(subject()), type(uint256).max);
        IERC20(SY).approve(address(subject()), type(uint256).max);
        IERC20(PT).approve(address(subject()), type(uint256).max);
        IERC20(YT).approve(address(subject()), type(uint256).max);

        IERC20(wstETH).approve(address(router), type(uint256).max);
        IERC20(SY).approve(address(router), type(uint256).max);
        IERC20(PT).approve(address(router), type(uint256).max);
        IERC20(YT).approve(address(router), type(uint256).max);
        IERC20(market).approve(address(router), type(uint256).max);
        IERC20(market).approve(address(router), type(uint256).max);

        IERC20(SY).approve(address(liquidityManager()), type(uint256).max);
        IERC20(PT).approve(address(liquidityManager()), type(uint256).max);
        IERC20(YT).approve(address(liquidityManager()), type(uint256).max);

        vm.label(address(SY), "SY");
        vm.label(address(YT), "YT");
        vm.label(address(PT), "PT");
    }

    function getPendleMarketData() public returns (MarketState memory ms, MarketPreCompute memory mp) {
        PYIndex index = YT.newIndex();
        ms = market.readState(address(router));
        mp = ms.getMarketPreCompute(index, block.timestamp);
    }

    function subject() public view returns (RMM) {
        return __subject__;
    }

    function liquidityManager() public view returns (LiquidityManager) {
        return __liquidityManager__;
    }

    function balanceNative(address token, address account) internal view returns (uint256) {
        if (token == address(0)) {
            return address(this).balance;
        }

        return MockERC20(token).balanceOf(account);
    }

    function getPtExchangeRate() internal returns (int256) {
        (MarketState memory ms, MarketPreCompute memory mp) = getPendleMarketData();
        return ms.totalPt._getExchangeRate(mp.totalAsset, mp.rateScalar, mp.rateAnchor, 0);
    }

    function balanceWad(address token, address account) internal view returns (uint256) {
        return upscale(balanceNative(token, account), scalar(token));
    }

    function mintSY(uint256 amount) public {
        IERC20(wstETH).approve(address(SY), type(uint256).max);
        SY.deposit(address(this), address(wstETH), amount, 1);
    }

    function mintPtYt(uint256 amount) public returns (uint256 amountPY) {
        SY.transfer(address(YT), amount);
        amountPY = YT.mintPY(address(this), address(this));
    }

    modifier basic_sy() {
        (MarketState memory ms, MarketPreCompute memory mp) = getPendleMarketData();
        uint256 price = uint256(getPtExchangeRate());
        subject().init({priceX: price, amountX: uint256(ms.totalSy - 100 ether), strike_: uint256(mp.rateAnchor)});

        _;
    }

    function test_compute_sy_to_pt_to_add_liquidity() public basic_sy {
        PYIndex index = YT.newIndex();

        uint256 rX = subject().reserveX();
        uint256 rY = subject().reserveY();
        uint256 maxSyToSwap = 1 ether;

        (uint256 syToSwap, uint256 ptOut) = liquidityManager().computeSyToPtToAddLiquidity(
            LiquidityManager.ComputeArgs({
                rmm: address(subject()),
                rX: rX,
                rY: rY,
                index: index,
                maxIn: maxSyToSwap,
                blockTime: block.timestamp,
                initialGuess: 0,
                epsilon: 10_000
            })
        );
        console2.log("syToSwap", syToSwap);
        console2.log("ptOut", ptOut);
    }

    function test_compute_pt_to_sy_to_add_liquidity() public basic_sy {
        PYIndex index = YT.newIndex();

        uint256 rX = subject().reserveX();
        uint256 rY = subject().reserveY();
        uint256 maxPtToSwap = 1 ether;

        (uint256 ptToSwap, uint256 syOut) = liquidityManager().computePtToSyToAddLiquidity(
            LiquidityManager.ComputeArgs({
                rmm: address(subject()),
                rX: rX,
                rY: rY,
                index: index,
                maxIn: maxPtToSwap,
                blockTime: block.timestamp,
                initialGuess: 0,
                epsilon: 10_000
            })
        );
        console2.log("ptToSwap", ptToSwap);
        console2.log("syOut", syOut);
    }

    function test_zap_from_sy() public basic_sy {
        PYIndex index = YT.newIndex();

        // initial balances
        uint256 rX = subject().reserveX();
        uint256 rY = subject().reserveY();
        uint256 maxSyToSwap = 1 ether;

        (uint256 syToSwap, uint256 ptOut) = liquidityManager().computeSyToPtToAddLiquidity(
            LiquidityManager.ComputeArgs({
                rmm: address(subject()),
                rX: rX,
                rY: rY,
                index: index,
                maxIn: maxSyToSwap,
                blockTime: block.timestamp,
                initialGuess: 0,
                epsilon: 10_000
            })
        );
        uint256 dx = maxSyToSwap - syToSwap;
        uint256 dy = ptOut;

        (,, uint256 minLiquidityDelta,) = subject().prepareAllocate(true, dx);
        liquidityManager().allocateFromSy(
            LiquidityManager.AllocateArgs(address(subject()), maxSyToSwap, ptOut, minLiquidityDelta, syToSwap, eps)
        );

        assertEq(subject().reserveX(), rX + maxSyToSwap, "unexpected rX balance after zap");
        assertEq(subject().reserveY(), rY, "unexpected rY balance after zap");
    }

    function test_zap_from_pt() public basic_sy {
        PYIndex index = YT.newIndex();

        uint256 rX = subject().reserveX();
        uint256 rY = subject().reserveY();
        uint256 maxPtToSwap = 1 ether;

        (uint256 ptToSwap, uint256 syOut) = liquidityManager().computePtToSyToAddLiquidity(
            LiquidityManager.ComputeArgs(address(subject()), rX, rY, index, maxPtToSwap, block.timestamp, 0, 10_000)
        );

        uint256 dy = maxPtToSwap - ptToSwap;
        uint256 dx = syOut;

        (,, uint256 minLiquidityDelta,) = subject().prepareAllocate(false, dy);
        liquidityManager().allocateFromPt(
            LiquidityManager.AllocateArgs(
                address(subject()), maxPtToSwap, syOut, minLiquidityDelta.mulDivDown(95, 100), ptToSwap, eps
            )
        );
        assertEq(subject().reserveY(), rY + maxPtToSwap, "unexpected rY balance after zap");
        assertEq(subject().reserveX(), rX, "unexpected rX balance after zap");
    }
}
