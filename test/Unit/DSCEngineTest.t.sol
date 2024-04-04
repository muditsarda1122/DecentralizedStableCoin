//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentalizedStableCoin} from "../../src/DecentalizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "../../lib/openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";
import {MockFailedTransferFrom} from "../Mocks/MockFailedtransferFrom.sol";
import {MockV3Aggregator} from "../Mocks/MockV3Aggregator.sol";
import {MockFailedMintDSC} from "../Mocks/MockFailedMintDsc.sol";
import {MockFailedTransfer} from "../Mocks/MockFailedTransfer.sol";
import "forge-std/console.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentalizedStableCoin public dsc;
    DSCEngine public dsce;
    HelperConfig public config;

    address public ethUsdPriceFeed;
    address public btcUsdPriceFeed;
    address public weth;
    address public wbtc;
    uint256 public deployerKey;

    address public USER = makeAddr("user");
    address public LIQUIDATOR = makeAddr("liquidator");

    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    // uint256 public constant AMOUNT_DSC = 4 ether;
    uint256 public constant AMOUNT_DSC = 10000 ether;
    uint8 public constant DECIMALS = 8;
    int256 public constant MOCKDSC_USD_PRICE = 1000e8;

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    modifier collateralDepositedAndDscMinted() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        dsce.mintDsc(AMOUNT_DSC);
        vm.stopPrank();
        _;
    }

    modifier liquidation() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        dsce.mintDsc(AMOUNT_DSC);
        vm.stopPrank();

        ERC20Mock(weth).mint(LIQUIDATOR, 50 ether);
        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(dsce), 50 ether);
        dsce.depositCollateral(weth, 50 ether);
        dsce.mintDsc(20000 ether);
        ERC20Mock(address(dsc)).approve(address(dsce), 20000 ether);
        vm.stopPrank();
        _;
    }

    function setUp() external {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc, deployerKey) = config
            .activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
        ERC20Mock(wbtc).mint(USER, STARTING_ERC20_BALANCE);

        if (block.chainid == 31337) {
            vm.deal(USER, STARTING_ERC20_BALANCE);
        }
    }

    //////////////////////////////
    // Constructor Tests /////////
    //////////////////////////////
    address[] tokenAddresses;
    address[] priceFeedAddresses;

    function testTokenAddressAndPriceFeedAddressAreNotOfSameLength() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(
            DSCEngine
                .DSCEngine__TokenAddressAndPriceFeedAddressMustBeSameLength
                .selector
        );
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsce));
    }

    ////////////////////////
    // Price Tests /////////
    ////////////////////////
    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18;
        // 15e18 * 3460 = 51900e18
        uint256 expectedUsdValue = 51900e18;
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);
        assertEq(expectedUsdValue, actualUsd);
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmountInWei = 1730e18;
        uint256 expectedTokens = 5e17;
        uint256 actualToken = dsce.getTokenAmountFromUsd(weth, usdAmountInWei);
        assertEq(expectedTokens, actualToken);
    }

    ////////////////////////////////////
    // depositCollateral Tests /////////
    ////////////////////////////////////
    function testRevertIfZeroCollateralDepositCollateral() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testReverIfTokenNotAllowedDepositCollateral() public {
        ERC20Mock random = new ERC20Mock(
            "RANDOM",
            "RAND",
            USER,
            AMOUNT_COLLATERAL
        );
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dsce.depositCollateral(address(random), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testRevertsIfTransferFromFailedDepositCollateral() public {
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransferFrom mockDsc = new MockFailedTransferFrom();

        tokenAddresses = [address(mockDsc)];
        priceFeedAddresses = [ethUsdPriceFeed];

        // vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(
            tokenAddresses,
            priceFeedAddresses,
            address(mockDsc)
        );

        vm.startPrank(owner);
        mockDsc.mint(USER, AMOUNT_COLLATERAL);
        mockDsc.transferOwnership(address(mockDsce));
        vm.stopPrank();

        vm.startPrank(USER);
        ERC20Mock(address(mockDsc)).approve(
            address(mockDsce),
            AMOUNT_COLLATERAL
        );
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        mockDsce.depositCollateral(address(mockDsc), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testDepositCollateral() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        // ERC20Mock(wbtc).approve(address(dsce), AMOUNT_COLLATERAL);

        uint256 DepositedCollateralBefore = dsce.getCollateralDeposited(
            USER,
            address(weth)
        );

        vm.expectEmit();
        emit DSCEngine.CollateralDeposited(
            address(USER),
            address(weth),
            AMOUNT_COLLATERAL
        );
        dsce.depositCollateral(address(weth), AMOUNT_COLLATERAL);

        uint256 DepositedCollateralAfter = dsce.getCollateralDeposited(
            USER,
            address(weth)
        );

        assertEq(
            DepositedCollateralAfter - DepositedCollateralBefore,
            AMOUNT_COLLATERAL
        );
    }

    //////////////////////////
    // mintDsc Tests /////////
    //////////////////////////
    function testMoreThanZeroMintDsc() public depositedCollateral {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedMoreThanZero.selector);
        dsce.mintDsc(0);
    }

    function testHealthFactorBreaksWhenMinting() public depositedCollateral {
        (, int256 price, , , ) = MockV3Aggregator(ethUsdPriceFeed)
            .latestRoundData();
        uint256 collateralValueInUsd = (AMOUNT_COLLATERAL *
            (uint256(price) * dsce.getAdditionalPrecision())) /
            dsce.getPrecision();
        uint256 amountToMint = collateralValueInUsd + 10;
        vm.expectRevert(DSCEngine.DSCEngine__BreaksHealthFactor.selector);
        dsce.mintDsc(amountToMint);
    }

    function testRevertsWhenMintFails() public {
        uint256 amountToMint = 100 ether;

        vm.prank(USER);
        MockFailedMintDSC mockDsc = new MockFailedMintDSC();

        tokenAddresses = [weth];
        priceFeedAddresses = [ethUsdPriceFeed];

        DSCEngine mockDsce = new DSCEngine(
            tokenAddresses,
            priceFeedAddresses,
            address(mockDsc)
        );
        vm.startPrank(USER);
        mockDsc.transferOwnership(address(mockDsce));

        ERC20Mock(weth).approve(address(mockDsce), AMOUNT_COLLATERAL);
        mockDsce.depositCollateral(weth, AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine_MintFailed.selector);
        mockDsce.mintDsc(amountToMint);
    }

    function testMintDsc() public depositedCollateral {
        uint256 dscAmountToMint = 4 ether;
        vm.prank(USER);
        dsce.mintDsc(dscAmountToMint);
    }

    /////////////////////////////////////
    // deposit collateral and mint //////
    /////////////////////////////////////
    function testDepositCollateralAndMintDsc() public {
        uint256 amountDscMinted = 4 ether;
        uint256 collateralDepositedBefore = dsce.getCollateral(USER, weth);
        uint256 DscMintedBefore = dsce.getDscMinted(USER);

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(
            weth,
            AMOUNT_COLLATERAL,
            amountDscMinted
        );

        uint256 collateralDepositedAfter = dsce.getCollateral(USER, weth);
        uint256 DscMintedAfter = dsce.getDscMinted(USER);

        assertEq(
            collateralDepositedAfter - collateralDepositedBefore,
            AMOUNT_COLLATERAL
        );
        assertEq(DscMintedAfter - DscMintedBefore, amountDscMinted);
    }

    ////////////////////////
    // redeem collateral ///
    ////////////////////////
    function testRedeemCollateralFailedTransfer() public {
        address owner = msg.sender;

        vm.prank(owner);
        MockFailedTransfer mockDsc = new MockFailedTransfer();

        tokenAddresses = [address(mockDsc)];
        priceFeedAddresses = [ethUsdPriceFeed];

        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(
            tokenAddresses,
            priceFeedAddresses,
            address(mockDsc)
        );

        mockDsc.mint(USER, AMOUNT_COLLATERAL);

        vm.prank(owner);
        mockDsc.transferOwnership(address(mockDsce));

        vm.startPrank(USER);
        ERC20Mock(address(mockDsc)).approve(
            address(mockDsce),
            AMOUNT_COLLATERAL
        );
        mockDsce.depositCollateral(address(mockDsc), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        mockDsce.redeemCollateral(address(mockDsc), AMOUNT_COLLATERAL);
    }

    function testRedeemCollateralRevertsIfHealthFactorBreaks()
        public
        collateralDepositedAndDscMinted
    {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__BreaksHealthFactor.selector);
        dsce.redeemCollateral(weth, AMOUNT_COLLATERAL);
    }

    function testRedeemCollateral() public collateralDepositedAndDscMinted {
        uint256 amountDscToRedeem = 1 ether;
        vm.prank(USER);
        dsce.redeemCollateral(weth, amountDscToRedeem);
    }

    //////////////////////
    ////// burn dsc //////
    //////////////////////
    function testRevertBurnZeroAmount() public collateralDepositedAndDscMinted {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedMoreThanZero.selector);
        dsce.burnDsc(0);
        vm.stopPrank();
    }

    function testRevertBurnMoreThanUserOwns()
        public
        collateralDepositedAndDscMinted
    {
        uint256 amountToBurn = AMOUNT_DSC + 1;
        vm.startPrank(USER);
        vm.expectRevert();
        dsce.burnDsc(amountToBurn);
        vm.stopPrank();
    }

    function testBurn() public collateralDepositedAndDscMinted {
        uint256 amountToBurn = 2 ether;
        uint256 dscBefore = dsce.getDscMinted(USER);
        vm.startPrank(USER);
        ERC20Mock(address(dsc)).approve(address(dsce), amountToBurn);
        dsce.burnDsc(amountToBurn);
        vm.stopPrank();
        uint256 dscAfter = dsce.getDscMinted(USER);
        assertEq(dscBefore - dscAfter, amountToBurn);
    }

    ////////////////////////////////
    // redeemCollateralForDsc //////
    ////////////////////////////////
    function testReedemCollateralForDsc()
        public
        collateralDepositedAndDscMinted
    {
        uint256 amountToBurn = 2 ether;
        uint256 collateraltoReedem = 3 ether;
        uint256 collateralBefore = dsce.getCollateral(USER, weth);
        uint256 dscBefore = dsce.getDscMinted(USER);

        vm.startPrank(USER);
        ERC20Mock(address(dsc)).approve(address(dsce), amountToBurn);
        dsce.redeemCollateralForDsc(weth, collateraltoReedem, amountToBurn);
        vm.stopPrank();

        uint256 collateralAfter = dsce.getCollateral(USER, weth);
        uint256 dscAfter = dsce.getDscMinted(USER);

        assertEq(collateralBefore - collateralAfter, collateraltoReedem);
        assertEq(dscBefore - dscAfter, amountToBurn);
    }

    ///////////////////
    // liquidate //////
    ///////////////////
    function testRevertLiquidateUserWithOkHealthFactor()
        public
        collateralDepositedAndDscMinted
    {
        vm.prank(LIQUIDATOR);
        vm.expectRevert(DSCEngine.DSCEngine__healthFactorOk.selector);
        dsce.liquidate(weth, USER, 4);
    }

    function testMustImproveTheHealthFactor() public liquidation {
        int256 ethUsdNewPrice = 1000e8;
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdNewPrice);
        vm.prank(LIQUIDATOR);
        vm.expectRevert(DSCEngine.DSCEngine__HealthfactorNotImproved.selector);
        dsce.liquidate(weth, USER, 5000 ether);
    }

    function testLiquidate() public liquidation {
        // hardcoded numbers
        uint256 userHFBefore = 75e16;
        uint256 liquidatorHFBefore = 1875e15;
        uint256 userHFAfter = 135e16;
        uint256 liquidatorHFAfter = 1875e15;
        uint256 userCollateralBalanceAfterLiquidation = 45e17;
        uint256 liquidatorCollateralBalanceAfterLiquidation = 555e17;
        uint256 userDscBalanceAfterLiquidation = 2500e18;
        uint256 liquidatorDscBalanceAfterLiquidation = 12500e18;

        int256 ethUsdNewPrice = 1500e8;
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdNewPrice);

        uint256 userHealthFactor = dsce.getHealthFactor(USER);
        uint256 liquidatorHealthFactor = dsce.getHealthFactor(LIQUIDATOR);
        assertEq(userHealthFactor, userHFBefore);
        assertEq(liquidatorHealthFactor, liquidatorHFBefore);

        vm.prank(LIQUIDATOR);
        dsce.liquidate(weth, USER, 7500 ether);

        userHealthFactor = dsce.getHealthFactor(USER);
        liquidatorHealthFactor = dsce.getHealthFactor(LIQUIDATOR);

        assertEq(userHealthFactor, userHFAfter);
        assertEq(liquidatorHealthFactor, liquidatorHFAfter);
        assertEq(
            ERC20Mock(address(dsc)).balanceOf(LIQUIDATOR),
            liquidatorDscBalanceAfterLiquidation
        );
        assertEq(
            ERC20Mock(weth).balanceOf(LIQUIDATOR) +
                dsce.getCollateral(LIQUIDATOR, weth),
            liquidatorCollateralBalanceAfterLiquidation
        );
        assertEq(
            dsce.getCollateral(USER, weth),
            userCollateralBalanceAfterLiquidation
        );
        assertEq(dsce.getDscMinted(USER), userDscBalanceAfterLiquidation);
    }

    //////////////////////
    // getHealthFactor ///
    //////////////////////
    function testGetHealthFactor() public collateralDepositedAndDscMinted {
        uint256 expectedHealthfactor = 173e16;
        uint256 actualHealthFactor = dsce.getHealthFactor(USER);
        assertEq(expectedHealthfactor, actualHealthFactor);
    }

    function testBadHealthFactor() public collateralDepositedAndDscMinted {
        int256 ethUsdNewPrice = 1500e8;
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdNewPrice);
        uint256 userHealthFactor = dsce.getHealthFactor(USER);
        assertEq(userHealthFactor, 75e16);
    }

    //////////////////////
    /////// getters //////
    //////////////////////
    function testGetCollateralDeposited() public depositedCollateral {
        uint256 actualCollateral = dsce.getCollateralDeposited(USER, weth);
        uint256 expectedCollateral = AMOUNT_COLLATERAL;
        assertEq(actualCollateral, expectedCollateral);
    }
}
