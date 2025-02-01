/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {PYIndex, PYIndexLib} from "pendle/core/StandardizedYield/PYIndex.sol";
import {Test} from "forge-std/Test.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {IPPrincipalToken} from "pendle/interfaces/IPPrincipalToken.sol";
import {IPYieldToken} from "pendle/interfaces/IPYieldToken.sol";
import {BaseSplitCodeFactory} from "pendle/core/libraries/BaseSplitCodeFactory.sol";
import {PendleYieldTokenV2} from "pendle/core/YieldContractsV2/PendleYieldTokenV2.sol";
import {PendleYieldContractFactoryV2} from "pendle/core/YieldContractsV2/PendleYieldContractFactoryV2.sol";
import {PendleWstEthSY} from "pendle/core/StandardizedYield/implementations/PendleWstEthSY.sol";
import {WstETH} from "./WstETH.sol";
import {MockStETH} from "./mocks/MockStETH.sol";
import {RMM} from "./../src/RMM.sol";
import {MockRMM} from "./MockRMM.sol";
import "forge-std/console2.sol";

struct InitParams {
    address PT;
    uint256 priceX;
    uint256 amountX;
    uint256 strike;
    uint256 sigma;
    uint256 fee;
    address curator;
}

uint32 constant DEFAULT_NOW = 1719578346;
uint32 constant DEFAULT_EXPIRY = DEFAULT_NOW + 365 days;

string constant DEFAULT_NAME = "RMM-LP-TOKEN";
string constant DEFAULT_SYMBOL = "RMM-LPT";

// address constant wstETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0; //real wsteth
// address constant WETH_ADDRESS = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

contract SetUp is Test {
    using PYIndexLib for IPYieldToken;
    using PYIndexLib for PYIndex;

    // All the contracts that are needed for the tests.
    MockRMM public rmm;
    WETH public weth;
    PendleWstEthSY public SY;
    IPYieldToken public YT;
    IPPrincipalToken public PT;
    WstETH public wstETH;
    MockStETH public stETH;

    // Main setup functions.

    function setUpContracts(uint32 expiry) public {
        weth = new WETH();
        stETH = new MockStETH();
        wstETH = new WstETH(address(stETH));
        SY = new PendleWstEthSY("wstEthSY", "wstEthSY", address(weth), address(wstETH));

        vm.label(address(SY), "SY");
        vm.label(address(YT), "YT");
        vm.label(address(PT), "PT");
        vm.label(address(wstETH), "wstETH");
        vm.label(address(stETH), "stETH");

        (
            address creationCodeContractA,
            uint256 creationCodeSizeA,
            address creationCodeContractB,
            uint256 creationCodeSizeB
        ) = BaseSplitCodeFactory.setCreationCode(type(PendleYieldTokenV2).creationCode);

        PendleYieldContractFactoryV2 factory = new PendleYieldContractFactoryV2(
            creationCodeContractA, creationCodeSizeA, creationCodeContractB, creationCodeSizeB
        );

        factory.initialize(1, 2e17, 0, address(this));
        factory.createYieldContract(address(SY), expiry, true);

        YT = IPYieldToken(factory.getYT(address(SY), expiry));
        PT = IPPrincipalToken(factory.getPT(address(SY), expiry));
    }

    function setUp() public virtual {
        vm.warp(DEFAULT_NOW);
        setUpContracts(DEFAULT_EXPIRY);

        InitParams memory initParams = getDefaultParams();
        setUpRMM(initParams);
        initRMM(initParams);
    }

    function setUpRMM(InitParams memory initParams) public {
        rmm = new MockRMM(DEFAULT_NAME, DEFAULT_SYMBOL, initParams.PT, initParams.sigma, initParams.fee);

        vm.label(address(rmm), "RMM");

        weth.approve(address(rmm), type(uint256).max);
        wstETH.approve(address(rmm), type(uint256).max);
        SY.approve(address(rmm), type(uint256).max);
        PT.approve(address(rmm), type(uint256).max);
        YT.approve(address(rmm), type(uint256).max);
    }

    function initRMM(InitParams memory initParams) public {
        uint256 amount = 100_000 ether;
        mintSY(address(this), amount);
        mintPY(address(this), amount / 2);

        rmm.init(initParams.priceX, initParams.amountX, initParams.strike);
    }

    // Here are some utility functions, you can use them to set specific states inside of a test.

    function mintSY(address to, uint256 amount) public returns (uint256 amountSharesOut) {
        deal(address(this), amount);
        (uint256 stETHAmount) = stETH.submit{value: amount}(address(0));
        stETH.approve(address(SY), stETHAmount);
        amountSharesOut = SY.deposit(address(this), address(stETH), amount, 0);
        if (to != address(this)) SY.transfer(address(to), amountSharesOut);
    }

    function mintPY(address to, uint256 amount) public {
        uint256 amountSharesOut = mintSY(address(this), amount);
        SY.transfer(address(YT), amountSharesOut);
        YT.mintPY(to, to);
    }

    function getDefaultParams() internal view returns (InitParams memory) {
        return InitParams({
            priceX: 1.15 ether,
            amountX: 100 ether,
            strike: 1.15 ether,
            sigma: 0.02 ether,
            PT: address(PT),
            fee: 0.00016 ether,
            curator: address(0x55)
        });
    }

    // Here are some modifiers, you can use them as hooks to set up the environment before running a test.

    modifier useDefaultPool() {
        setUpRMM(getDefaultParams());
        initRMM(getDefaultParams());

        _;
    }

    modifier useSYPool() {
        InitParams memory initParams = InitParams({
            PT: address(PT),
            priceX: 1007488755655417383,
            amountX: 1311689788256138069842,
            strike: 1009671560073979390,
            sigma: 0.023 ether,
            fee: 0.0003 ether,
            curator: address(0x55)
        });

        setUpRMM(initParams);
        initRMM(initParams);

        _;
    }

    modifier withSY(address to, uint256 amount) {
        mintSY(address(to), amount);
        _;
    }

    modifier withPY(address to, uint256 amount) {
        mintPY(address(to), amount);
        _;
    }

    modifier withWETH(address to, uint256 amount) {
        deal(address(this), amount);
        weth.deposit{value: amount}();
        if (to != address(this)) weth.transfer(to, amount);
        _;
    }

    function skip() public {
        vm.skip(true);
    }

    function newIndex() public returns (PYIndex) {
        return YT.newIndex();
    }

    function syToAsset(uint256 amount) public returns (uint256) {
        return newIndex().syToAsset(amount);
    }

    function assetToSyUp(uint256 amount) public returns (uint256) {
        return newIndex().assetToSyUp(amount);
    }
}
