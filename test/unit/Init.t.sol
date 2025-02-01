/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {SetUp, RMM, InitParams, DEFAULT_EXPIRY} from "../SetUp.sol";
import {Init} from "../../src/lib/RmmEvents.sol";
import {InvalidStrike, AlreadyInitialized} from "../../src/lib/RmmErrors.sol";

contract InitTest is SetUp {
    function test_init_MintsLiquidity()
        public
        withSY(address(this), 2000000 ether)
        withPY(address(this), 1000000 ether)
    {
        InitParams memory initParams = getDefaultParams();
        setUpRMM(initParams);

        (uint256 totalLiquidity,) =
            rmm.prepareInit(initParams.priceX, initParams.amountX, initParams.strike, initParams.sigma, newIndex());

        rmm.init(initParams.priceX, initParams.amountX, initParams.strike);

        assertEq(rmm.totalLiquidity(), totalLiquidity);
        assertEq(rmm.balanceOf(address(this)), totalLiquidity - 1000);
        assertEq(rmm.balanceOf(address(0)), 1000);
    }

    function test_init_AdjustsPool() public withSY(address(this), 2000000 ether) withPY(address(this), 1000000 ether) {
        InitParams memory initParams = getDefaultParams();
        setUpRMM(initParams);

        (, uint256 amountY) =
            rmm.prepareInit(initParams.priceX, initParams.amountX, initParams.strike, initParams.sigma, newIndex());
        rmm.init(initParams.priceX, initParams.amountX, initParams.strike);

        assertEq(rmm.lastTimestamp(), block.timestamp, "lastTimestamp");
        assertEq(rmm.reserveX(), initParams.amountX, "reserveX");
        assertEq(rmm.reserveY(), amountY, "reserveY");
        assertEq(rmm.strike(), initParams.strike);
    }

    function test_init_TransfersTokens()
        public
        withSY(address(this), 2000000 ether)
        withPY(address(this), 1000000 ether)
    {
        InitParams memory initParams = getDefaultParams();
        setUpRMM(initParams);

        (, uint256 amountY) =
            rmm.prepareInit(initParams.priceX, initParams.amountX, initParams.strike, initParams.sigma, newIndex());

        uint256 thisPreBalanceSY = SY.balanceOf(address(this));
        uint256 thisPreBalancePT = PT.balanceOf(address(this));
        uint256 rmmPreBalanceSY = SY.balanceOf(address(rmm));
        uint256 rmmPreBalancePT = PT.balanceOf(address(rmm));

        rmm.init(initParams.priceX, initParams.amountX, initParams.strike);

        assertEq(SY.balanceOf(address(this)), thisPreBalanceSY - initParams.amountX);
        assertEq(PT.balanceOf(address(this)), thisPreBalancePT - amountY);
        assertEq(SY.balanceOf(address(rmm)), rmmPreBalanceSY + initParams.amountX);
        assertEq(PT.balanceOf(address(rmm)), rmmPreBalancePT + amountY);
    }

    function test_init_EmitsInitEvent()
        public
        withSY(address(this), 2000000 ether)
        withPY(address(this), 1000000 ether)
    {
        InitParams memory initParams = getDefaultParams();
        setUpRMM(initParams);

        (uint256 totalLiquidity, uint256 amountY) =
            rmm.prepareInit(initParams.priceX, initParams.amountX, initParams.strike, initParams.sigma, newIndex());

        vm.expectEmit();

        emit Init(
            address(this),
            address(SY),
            address(PT),
            initParams.amountX,
            amountY,
            totalLiquidity,
            initParams.strike,
            initParams.sigma,
            initParams.fee,
            DEFAULT_EXPIRY
        );

        rmm.init(initParams.priceX, initParams.amountX, initParams.strike);
    }

    function test_init_RevertsIfAlreadyInitialized()
        public
        useDefaultPool
        withSY(address(this), 2000000 ether)
        withPY(address(this), 1000000 ether)
    {
        InitParams memory initParams = getDefaultParams();

        vm.expectRevert(AlreadyInitialized.selector);
        rmm.init(initParams.priceX, initParams.amountX, initParams.strike);
    }

    function test_init_RevertsIfInvalidStrike()
        public
        withSY(address(this), 2000000 ether)
        withPY(address(this), 1000000 ether)
    {
        InitParams memory initParams = getDefaultParams();
        setUpRMM(initParams);

        vm.expectRevert(InvalidStrike.selector);
        rmm.init(initParams.priceX, initParams.amountX, 1 ether);
    }

    function test_init_RevertsWhenLocked()
        public
        withSY(address(this), 2000000 ether)
        withPY(address(this), 1000000 ether)
    {
        vm.skip(true);
    }
}
